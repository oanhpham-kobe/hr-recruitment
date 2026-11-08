import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

test("HR participant report adapter uses the accepted save_interviewer_report argument names", () => {
  const source = readFileSync(
    new URL("../lib/reports/hr-server.ts", import.meta.url),
    "utf8",
  );
  const call = source.match(
    /client\.rpc\("save_interviewer_report",\s*\{([\s\S]*?)\}\);/,
  );

  assert.ok(call, "save_interviewer_report RPC call must exist");
  const args = call[1];
  assert.match(args, /p_interview_participant_id:/);
  assert.match(args, /p_field_patches:/);
  assert.match(args, /p_expected_version_no:/);
  assert.match(args, /p_base_values:/);
  assert.doesNotMatch(args, /p_expected_version:/);
});
