import assert from "node:assert/strict";
import test from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { AppSession } from "@/lib/auth/session";
import { searchApplicationOptions } from "@/lib/interview/server";

type QueryResult = { data: unknown; error: null };
type Call = {
  table: string;
  operation: string;
  args: unknown[];
};

class MockBuilder implements PromiseLike<QueryResult> {
  constructor(
    private readonly table: string,
    private readonly result: QueryResult,
    private readonly calls: Call[],
  ) {}

  private record(operation: string, ...args: unknown[]) {
    this.calls.push({ table: this.table, operation, args });
    return this;
  }

  select(columns: string) {
    return this.record("select", columns);
  }

  eq(column: string, value: unknown) {
    return this.record("eq", column, value);
  }

  order(column: string, options?: unknown) {
    return this.record("order", column, options);
  }

  limit(value: number) {
    return this.record("limit", value);
  }

  or(filters: string, options?: unknown) {
    return this.record("or", filters, options);
  }

  in(column: string, values: unknown[]) {
    return this.record("in", column, values);
  }

  // biome-ignore lint/suspicious/noThenProperty: Supabase query builders are intentionally awaitable in this test double.
  then<TResult1 = QueryResult, TResult2 = never>(
    onfulfilled?:
      | ((value: QueryResult) => TResult1 | PromiseLike<TResult1>)
      | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve(this.result).then(onfulfilled, onrejected);
  }
}

const session: AppSession = {
  isAuthenticated: true,
  user: {
    authUserId: "10000000-0000-4000-8000-000000000001",
    appUserId: "20000000-0000-4000-8000-000000000001",
    email: "reviewer@eiu.edu.vn",
    isInternal: true,
    isCandidate: false,
    roles: ["HR"],
    permissions: ["interviews.view"],
  },
};

const applicationId = "30000000-0000-4000-8000-000000000001";
const submissionId = "40000000-0000-4000-8000-000000000001";
const unitId = "50000000-0000-4000-8000-000000000001";
const positionId = "60000000-0000-4000-8000-000000000001";
const interviewId = "70000000-0000-4000-8000-000000000001";

test("Copy-target PII search filters Applications through the Submission relation without a capped pre-query", async () => {
  const calls: Call[] = [];
  const results: Record<string, QueryResult> = {
    applications: {
      data: [
        {
          application_id: applicationId,
          submission_id: submissionId,
          version_no: 4,
          unit_id: unitId,
          department_team_id: null,
          position_id: positionId,
        },
      ],
      error: null,
    },
    submissions: {
      data: [
        {
          submission_id: submissionId,
          full_name: "Nguyễn Văn An",
          email_snapshot: "an@example.com",
        },
      ],
      error: null,
    },
    interviews: {
      data: [
        {
          interview_id: interviewId,
          application_id: applicationId,
          round_no: 2,
          version_no: 7,
        },
      ],
      error: null,
    },
    organizational_units: {
      data: [{ unit_id: unitId, name_vi: "Khoa Kỹ thuật" }],
      error: null,
    },
    department_teams: { data: [], error: null },
    positions: {
      data: [{ position_id: positionId, name_vi: "Giảng viên" }],
      error: null,
    },
  };

  const client = {
    from(table: string) {
      calls.push({ table, operation: "from", args: [] });
      const result = results[table];
      if (!result) throw new Error(`Unexpected table: ${table}`);
      return new MockBuilder(table, result, calls);
    },
  } as unknown as SupabaseClient;

  const options = await searchApplicationOptions("an@example.com", {
    client,
    resolveSession: async () => session,
  });

  assert.equal(options.length, 1);
  assert.equal(options[0]?.applicationId, applicationId);

  const fromCalls = calls.filter((call) => call.operation === "from");
  assert.equal(
    fromCalls[0]?.table,
    "applications",
    "PII matching must begin from Applications, not a capped Submission pre-query",
  );

  const applicationSelect = calls.find(
    (call) => call.table === "applications" && call.operation === "select",
  );
  assert.match(
    String(applicationSelect?.args[0] ?? ""),
    /filtered_submission:submissions!inner\(submission_id,full_name,email_snapshot,phone\)/,
  );

  const applicationOr = calls.find(
    (call) => call.table === "applications" && call.operation === "or",
  );
  assert.deepEqual(applicationOr?.args[1], {
    referencedTable: "filtered_submission",
  });
  assert.match(String(applicationOr?.args[0] ?? ""), /email_snapshot\.ilike/);

  assert.equal(
    calls.some(
      (call) =>
        call.table === "applications" &&
        call.operation === "in" &&
        call.args[0] === "submission_id",
    ),
    false,
    "Application query must not depend on a pre-truncated Submission ID list",
  );
  assert.equal(
    calls.some((call) => call.operation === "limit" && call.args[0] === 250),
    false,
    "The rejected 250-row PII pre-match cap must not return",
  );
});
