import assert from "node:assert/strict";
import test from "node:test";
import { resolveInternalNavItems } from "@/components/shell/navigation";

function hrefs(roles: string[], permissions: string[]): string[] {
  return resolveInternalNavItems({ roles, permissions }).map(
    (item) => item.href,
  );
}

test("Interviewer navigation exposes the contextual report and feedback modules", () => {
  assert.deepEqual(hrefs([], []), ["/reports", "/interview-feedback"]);
});

test("limited HR navigation follows granted view permissions", () => {
  assert.deepEqual(hrefs(["HR"], ["submissions.view"]), [
    "/",
    "/reports",
    "/interview-feedback",
  ]);
  assert.deepEqual(hrefs(["HR"], ["interviews.view"]), [
    "/interviews",
    "/reports",
    "/interview-feedback",
  ]);
  assert.deepEqual(
    hrefs(["HR"], ["submissions.view", "interviews.view", "reports.view"]),
    ["/", "/interviews", "/reports", "/interview-feedback"],
  );
  assert.deepEqual(hrefs(["HR"], ["master_data.manage"]), [
    "/reports",
    "/interview-feedback",
    "/master-data",
  ]);
  assert.deepEqual(hrefs(["HR"], ["submissions.view", "master_data.manage"]), [
    "/",
    "/reports",
    "/interview-feedback",
    "/master-data",
  ]);
  assert.deepEqual(hrefs(["HR"], ["users.directory_read"]), [
    "/reports",
    "/interview-feedback",
    "/users",
  ]);
  assert.deepEqual(hrefs(["HR"], ["users.directory_manage"]), [
    "/reports",
    "/interview-feedback",
    "/users",
  ]);
});

test("Root Admin sees all implemented internal modules", () => {
  assert.deepEqual(hrefs(["ROOT_ADMIN"], []), [
    "/",
    "/interviews",
    "/reports",
    "/interview-feedback",
    "/master-data",
    "/users",
  ]);
});

test("missing identity fails closed", () => {
  assert.deepEqual(resolveInternalNavItems(null), []);
});
