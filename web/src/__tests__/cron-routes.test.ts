import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import type { SupabaseClient } from "@supabase/supabase-js";
import { POST as storageCleanup } from "@/app/api/cron/storage-cleanup/route";

const SECRET = "test-only-cron-secret-long-enough";
const saved = { ...process.env };
afterEach(() => {
  process.env = { ...saved };
});

function request(authorization?: string) {
  return new Request("https://app.example/api/cron/storage-cleanup", {
    method: "POST",
    headers: authorization ? { Authorization: authorization } : {},
  });
}

/** Worker client fake: records RPC names and serves one claimed cleanup job. */
function workerClient(calls: string[]) {
  return {
    rpc: async (name: string) => {
      calls.push(name);
      const data: Record<string, unknown> = {
        discover_expired_storage_cleanup: { captured_count: 0 },
        claim_storage_cleanup_jobs: [
          {
            storage_cleanup_id: "11111111-1111-4111-8111-111111111111",
            attempt_id: "22222222-2222-4222-8222-222222222222",
            fencing_token: "33333333-3333-4333-8333-333333333333",
          },
        ],
        authorize_storage_cleanup_attempt: {
          bucket_name: "candidate-quarantine",
          object_path: "session/file.pdf",
        },
        complete_storage_cleanup_attempt: { status_code: "DONE" },
      };
      return { data: { success: true, data: data[name] }, error: null };
    },
  } as unknown as SupabaseClient;
}

test("cron route rejects a missing, wrong or unset secret before any work", async () => {
  const calls: string[] = [];
  const deps = {
    workerClient: workerClient(calls),
    provider: {
      removeObject: async () => ({ status: "ABSENT" as const }),
    },
  };
  process.env.CRON_SECRET = SECRET;
  for (const header of [undefined, "Bearer wrong", SECRET, `Basic ${SECRET}`])
    assert.equal(
      (await storageCleanup(request(header), undefined, deps)).status,
      401,
    );
  process.env.CRON_SECRET = "short";
  assert.equal(
    (await storageCleanup(request("Bearer short"), undefined, deps)).status,
    401,
  );
  delete process.env.CRON_SECRET;
  assert.equal(
    (await storageCleanup(request("Bearer undefined"), undefined, deps)).status,
    401,
  );
  assert.deepEqual(calls, []);
});

test("storage cleanup route fails closed when worker credentials are not configured", async () => {
  process.env.CRON_SECRET = SECRET;
  delete process.env.STORAGE_CLEANUP_WORKER_TOKEN;
  const response = await storageCleanup(request(`Bearer ${SECRET}`));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "NOT_CONFIGURED" });
});

test("storage cleanup route discovers, then removes only the authorized object", async () => {
  process.env.CRON_SECRET = SECRET;
  const calls: string[] = [];
  const removed: string[] = [];
  const response = await storageCleanup(
    request(`Bearer ${SECRET}`),
    undefined,
    {
      workerClient: workerClient(calls),
      provider: {
        removeObject: async (bucket, path) => {
          removed.push(`${bucket}/${path}`);
          return { status: "REMOVED_OR_ABSENT" };
        },
      },
    },
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { claimed: 1, done: 1 });
  assert.deepEqual(calls, [
    "discover_expired_storage_cleanup",
    "claim_storage_cleanup_jobs",
    "authorize_storage_cleanup_attempt",
    "complete_storage_cleanup_attempt",
  ]);
  assert.deepEqual(removed, ["candidate-quarantine/session/file.pdf"]);
});
