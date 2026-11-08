import assert from "node:assert/strict";
import test from "node:test";
import { safeInternalPath } from "@/lib/auth/safe-internal-path";

test("safeInternalPath rejects external and browser-normalized redirect destinations", () => {
  const rejected = [
    null,
    undefined,
    "",
    "https://evil.example.test",
    "javascript:alert(1)",
    "//evil.example.test",
    "\\evil.example.test",
    "/\\evil.example.test",
    "/path\\evil",
    "relative/path",
    " /valid",
    ...Array.from(
      { length: 32 },
      (_, n) => `/${String.fromCharCode(n)}/evil.example.test`,
    ),
    `/path${String.fromCharCode(127)}`,
  ];
  for (const value of rejected)
    assert.equal(safeInternalPath(value), "/", JSON.stringify(value));
});
test("safeInternalPath preserves legitimate internal invitation paths, queries and fragments", () => {
  for (const value of [
    "/",
    "/candidate",
    "/interview-feedback/10100000-0000-4000-8000-000000000001",
    "/interview-feedback/10100000-0000-4000-8000-000000000001?mode=review&name=Nguy%E1%BB%85n#answer",
    "/reports?returnTo=https%3A%2F%2Fexample.test",
  ]) {
    assert.equal(safeInternalPath(value), value);
    assert.equal(
      new URL(safeInternalPath(value), "https://app.example.test").origin,
      "https://app.example.test",
    );
  }
});
