import assert from "node:assert/strict";
import test from "node:test";

import { createCommandRunner } from "@/lib/commands/runner";
import {
  CommandErrorCode,
  type TrustedCommandDefinition,
  type VerifiedActor,
} from "@/lib/commands/types";

type RawInput = { id: string; valid: boolean };
type ValidatedInput = { id: string };

const activeActor: VerifiedActor = {
  authUserId: "user-1",
  email: "user@example.test",
  isActive: true,
  roles: [],
  permissions: [],
};

function createCommand(
  stages: string[],
  options: {
    authorized?: boolean;
    throws?: boolean;
  } = {},
): TrustedCommandDefinition<RawInput, string, ValidatedInput, string> {
  return {
    name: "test-command",
    extractTarget(rawInput) {
      stages.push("extract");
      return rawInput.id;
    },
    authorize() {
      stages.push("authorize");
      return options.authorized === false
        ? { authorized: false, reason: "Insufficient permissions" }
        : { authorized: true };
    },
    validate(rawInput) {
      stages.push("validate");

      return rawInput.valid
        ? { success: true, data: { id: rawInput.id } }
        : { success: false, error: "Invalid payload" };
    },
    async execute() {
      stages.push("execute");

      if (options.throws) {
        throw new Error("Bearer secret-token");
      }

      return "executed";
    },
  };
}

function createRunner(actor: VerifiedActor | null, stages: string[]) {
  return createCommandRunner({
    async resolveActor() {
      stages.push("authenticate");
      return actor;
    },
  });
}

test("rejects unauthenticated requests before authorization or validation", async () => {
  const stages: string[] = [];
  const result = await createRunner(null, stages)(createCommand(stages), {
    id: "target-1",
    valid: true,
  });

  assert.deepEqual(result, {
    success: false,
    error: {
      code: CommandErrorCode.UNAUTHENTICATED,
      message: "Authentication required",
    },
  });
  assert.deepEqual(stages, ["authenticate"]);
});

test("rejects inactive actors before authorization or validation", async () => {
  const stages: string[] = [];
  const result = await createRunner(
    { ...activeActor, isActive: false },
    stages,
  )(createCommand(stages), { id: "target-1", valid: true });

  assert.equal(result.success, false);
  assert.equal(result.error.code, CommandErrorCode.USER_INACTIVE);
  assert.deepEqual(stages, ["authenticate"]);
});

test("returns FORBIDDEN for unauthorized invalid input without validating it", async () => {
  const stages: string[] = [];
  const result = await createRunner(activeActor, stages)(
    createCommand(stages, { authorized: false }),
    { id: "target-1", valid: false },
  );

  assert.equal(result.success, false);
  assert.equal(result.error.code, CommandErrorCode.FORBIDDEN);
  assert.deepEqual(stages, ["authenticate", "extract", "authorize"]);
});

test("validates authorized input only after authentication and authorization", async () => {
  const stages: string[] = [];
  const result = await createRunner(activeActor, stages)(
    createCommand(stages),
    {
      id: "target-1",
      valid: false,
    },
  );

  assert.equal(result.success, false);
  assert.equal(result.error.code, CommandErrorCode.VALIDATION_ERROR);
  assert.deepEqual(stages, [
    "authenticate",
    "extract",
    "authorize",
    "validate",
  ]);
});

test("executes only after a valid authorized command", async () => {
  const stages: string[] = [];
  const result = await createRunner(activeActor, stages)(
    createCommand(stages),
    {
      id: "target-1",
      valid: true,
    },
  );

  assert.deepEqual(result, { success: true, data: "executed" });
  assert.deepEqual(stages, [
    "authenticate",
    "extract",
    "authorize",
    "validate",
    "execute",
  ]);
});

test("redacts unexpected handler failures behind INTERNAL_ERROR", async () => {
  const stages: string[] = [];
  const originalError = console.error;
  console.error = () => {};

  try {
    const result = await createRunner(activeActor, stages)(
      createCommand(stages, { throws: true }),
      { id: "target-1", valid: true },
    );

    assert.equal(result.success, false);
    assert.equal(result.error.code, CommandErrorCode.INTERNAL_ERROR);
  } finally {
    console.error = originalError;
  }
});
