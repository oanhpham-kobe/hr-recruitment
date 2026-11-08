import assert from "node:assert/strict";
import test from "node:test";

import { redactSensitiveData, redactString } from "@/lib/logging/logger";

test("redacts sensitive values regardless of their runtime type", () => {
  const redacted = redactSensitiveData({
    otp: 123456,
    password: "not-safe",
    nested: { authorization: ["not-safe"] },
  }) as Record<string, unknown>;

  assert.equal(redacted.otp, "[REDACTED]");
  assert.equal(redacted.password, "[REDACTED]");
  assert.deepEqual(redacted.nested, { authorization: "[REDACTED]" });
});

test("redacts Bearer, JWT, signed URL, credential, and OTP string patterns", () => {
  const rawJwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature";
  const value = redactString(
    `Bearer ${rawJwt} url=https://user:password@example.test/path?token=abc&signature=def otp: 123456`,
  );

  assert.doesNotMatch(value, /password|abc|signature=def|123456|eyJhbGci/i);
  assert.match(value, /Bearer \[REDACTED\]/);
  assert.match(value, /token=\[REDACTED\]&signature=\[REDACTED\]/);
  assert.match(value, /user:\[REDACTED\]@/);
});

test("redacts cyclic structures without recursing forever", () => {
  const cyclic: { label: string; self?: unknown } = { label: "safe" };
  cyclic.self = cyclic;

  assert.deepEqual(redactSensitiveData(cyclic), {
    label: "safe",
    self: "[CIRCULAR]",
  });
});

test("sanitizes Error instances without preserving raw stack traces", () => {
  const error = new Error("Bearer secret-token otp: 123456");
  const redacted = redactSensitiveData(error);
  const serialized = JSON.stringify(redacted);

  assert.deepEqual(redacted, {
    name: "Error",
    message: "Bearer [REDACTED] otp: [REDACTED]",
  });
  assert.doesNotMatch(serialized, /secret-token|123456|stack/i);
});
