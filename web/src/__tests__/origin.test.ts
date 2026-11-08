import assert from "node:assert/strict";
import test from "node:test";

import { validateSameOrigin } from "@/lib/security/origin";

test("validateSameOrigin accepts a matching Origin and Host", () => {
  const request = new Request("https://recruitment.example.test/command", {
    headers: {
      host: "recruitment.example.test",
      origin: "https://recruitment.example.test",
    },
    method: "POST",
  });

  assert.equal(validateSameOrigin(request), true);
});

test("validateSameOrigin accepts a matching Referer through a trusted proxy", () => {
  const request = new Request("http://internal/command", {
    headers: {
      "x-forwarded-host": "recruitment.example.test",
      "x-forwarded-proto": "https",
      referer: "https://recruitment.example.test/settings",
    },
    method: "POST",
  });

  assert.equal(validateSameOrigin(request), true);
});

test("validateSameOrigin rejects missing, mismatched, and spoofed origins", () => {
  const mismatchedOrigin = new Request(
    "https://recruitment.example.test/command",
    {
      headers: {
        host: "recruitment.example.test",
        origin: "https://attacker.example.test",
      },
      method: "POST",
    },
  );
  const spoofedOrigin = new Request(
    "https://recruitment.example.test/command",
    {
      headers: {
        host: "recruitment.example.test",
        origin: "https://recruitment.example.test.attacker.test",
      },
      method: "POST",
    },
  );
  const missingOrigin = new Request(
    "https://recruitment.example.test/command",
    {
      headers: { host: "recruitment.example.test" },
      method: "POST",
    },
  );

  assert.equal(validateSameOrigin(mismatchedOrigin), false);
  assert.equal(validateSameOrigin(spoofedOrigin), false);
  assert.equal(validateSameOrigin(missingOrigin), false);
});
