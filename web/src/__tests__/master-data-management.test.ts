import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { resolveInternalNavItems } from "@/components/shell/navigation";
import {
  createCreateMasterItemCommand,
  createDeleteOrInactivateMasterItemCommand,
  createUpdateMasterItemCommand,
  type MasterDataType,
  VALID_MASTER_TYPES,
} from "@/lib/commands/master-data";
import { CommandErrorCode } from "@/lib/commands/types";

test("VALID_MASTER_TYPES contains exactly the 11 business catalogs", () => {
  assert.equal(VALID_MASTER_TYPES.length, 11);
  assert.ok(VALID_MASTER_TYPES.includes("organizational_units"));
  assert.ok(VALID_MASTER_TYPES.includes("department_teams"));
  assert.ok(VALID_MASTER_TYPES.includes("positions"));
  assert.ok(VALID_MASTER_TYPES.includes("position_groups"));
  assert.ok(VALID_MASTER_TYPES.includes("rooms"));
  assert.ok(VALID_MASTER_TYPES.includes("interview_formats"));
  assert.ok(VALID_MASTER_TYPES.includes("qualification_levels"));
  assert.ok(VALID_MASTER_TYPES.includes("recruitment_sources"));
  assert.ok(VALID_MASTER_TYPES.includes("document_types"));
  assert.ok(VALID_MASTER_TYPES.includes("cancellation_reasons"));
  assert.ok(VALID_MASTER_TYPES.includes("rejection_reasons"));
});

test("createMasterItem command authorizes only ROOT_ADMIN or master_data.manage", async () => {
  const mockSupabase = {} as SupabaseClient;
  const cmd = createCreateMasterItemCommand(mockSupabase);

  // Unauthorized actor (interviewer or limited HR without master_data.manage)
  const deniedActor = {
    authUserId: "user-1",
    email: "hr@eiu.edu.vn",
    isActive: true,
    roles: ["HR"],
    permissions: ["submissions.view", "interviews.view"],
  };
  const authDenied = await cmd.authorize(deniedActor);
  assert.equal(authDenied.authorized, false);
  if (!authDenied.authorized) {
    assert.equal(authDenied.code, CommandErrorCode.FORBIDDEN);
  }

  // Authorized HR with master_data.manage
  const authorizedHr = {
    authUserId: "user-2",
    email: "hr-lead@eiu.edu.vn",
    isActive: true,
    roles: ["HR"],
    permissions: ["master_data.manage"],
  };
  const authHr = await cmd.authorize(authorizedHr);
  assert.equal(authHr.authorized, true);

  // Authorized ROOT_ADMIN
  const rootAdmin = {
    authUserId: "user-root",
    email: "root@eiu.edu.vn",
    isActive: true,
    roles: ["ROOT_ADMIN"],
    permissions: [],
  };
  const authRoot = await cmd.authorize(rootAdmin);
  assert.equal(authRoot.authorized, true);
});

test("createMasterItem command validates input parameters", () => {
  const mockSupabase = {} as SupabaseClient;
  const cmd = createCreateMasterItemCommand(mockSupabase);

  // Invalid master type
  const badType = cmd.validate({
    masterType: "unknown_table" as unknown as MasterDataType,
    payload: { code: "TEST", name_vi: "Test" },
  });
  assert.equal(badType.success, false);

  // Invalid payload (not an object)
  const badPayload = cmd.validate({
    masterType: "rooms",
    payload: "invalid" as unknown as Record<string, unknown>,
  });
  assert.equal(badPayload.success, false);

  // Valid input
  const valid = cmd.validate({
    masterType: "rooms",
    payload: { code: "R101", display_name: "Room 101" },
  });
  assert.equal(valid.success, true);
});

test("updateMasterItem command authorizes only master_data.manage or ROOT_ADMIN and validates version", async () => {
  const mockSupabase = {} as SupabaseClient;
  const cmd = createUpdateMasterItemCommand(mockSupabase);

  // Denied
  const deniedAuth = await cmd.authorize({
    authUserId: "u1",
    email: "staff@eiu.edu.vn",
    isActive: true,
    roles: ["STAFF"],
    permissions: ["interviews.view"],
  });
  assert.equal(deniedAuth.authorized, false);

  // Authorized
  const okAuth = await cmd.authorize({
    authUserId: "u2",
    email: "admin@eiu.edu.vn",
    isActive: true,
    roles: ["ROOT_ADMIN"],
    permissions: [],
  });
  assert.equal(okAuth.authorized, true);
  // Invalid UUID
  assert.equal(
    cmd.validate({
      masterType: "rooms",
      masterId: "not-a-uuid",
      expectedVersionNo: 1,
      payload: { display_name: "Room A" },
    }).success,
    false,
  );

  // Invalid expectedVersionNo
  assert.equal(
    cmd.validate({
      masterType: "rooms",
      masterId: "00000000-0000-0000-0000-000000000001",
      expectedVersionNo: 0,
      payload: { display_name: "Room A" },
    }).success,
    false,
  );

  // Valid
  assert.equal(
    cmd.validate({
      masterType: "rooms",
      masterId: "00000000-0000-0000-0000-000000000001",
      expectedVersionNo: 2,
      payload: { display_name: "Room A" },
    }).success,
    true,
  );
});

test("deleteOrInactivateMasterItem command authorizes and validates expectedVersionNo", async () => {
  const mockSupabase = {} as SupabaseClient;
  const cmd = createDeleteOrInactivateMasterItemCommand(mockSupabase);

  // Authorized with master_data.manage
  const auth = await cmd.authorize({
    authUserId: "u1",
    email: "hr@eiu.edu.vn",
    isActive: true,
    roles: ["HR"],
    permissions: ["master_data.manage"],
  });
  assert.equal(auth.authorized, true);
  // Valid input
  assert.equal(
    cmd.validate({
      masterType: "qualification_levels",
      masterId: "00000000-0000-0000-0000-000000000001",
      expectedVersionNo: 1,
    }).success,
    true,
  );
});

test("resolveInternalNavItems exposes Master Data only to ROOT_ADMIN or master_data.manage", () => {
  // Interviewer only -> no master-data
  const interviewerHrefs = resolveInternalNavItems({
    roles: ["INTERVIEWER"],
    permissions: [],
  }).map((i) => i.href);
  assert.ok(!interviewerHrefs.includes("/master-data"));

  // HR with submissions.view only -> no master-data
  const hrHrefs = resolveInternalNavItems({
    roles: ["HR"],
    permissions: ["submissions.view"],
  }).map((i) => i.href);
  assert.ok(!hrHrefs.includes("/master-data"));

  // HR with master_data.manage -> has /master-data
  const hrManagerHrefs = resolveInternalNavItems({
    roles: ["HR"],
    permissions: ["master_data.manage"],
  }).map((i) => i.href);
  assert.ok(hrManagerHrefs.includes("/master-data"));

  // ROOT_ADMIN -> has /master-data
  const rootHrefs = resolveInternalNavItems({
    roles: ["ROOT_ADMIN"],
    permissions: [],
  }).map((i) => i.href);
  assert.ok(rootHrefs.includes("/master-data"));
});
