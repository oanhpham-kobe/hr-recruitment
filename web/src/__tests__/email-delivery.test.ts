import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { POST as emailDelivery } from "@/app/api/cron/email-delivery/route";
import {
  type AuthorizedEmail,
  type EmailDeliveryDbPort,
  EmailProviderError,
  runEmailDeliveryBatch,
} from "@/lib/email/delivery-runner";
import { buildMimeMessage, createGmailProvider } from "@/lib/email/gmail";

const message: AuthorizedEmail = {
  email_outbox_id: "11111111-1111-4111-8111-111111111111",
  attempt_id: "22222222-2222-4222-8222-222222222222",
  environment_code: "TEST",
  recipients: { to: ["sink@eiu.edu.vn"], cc: [] },
  subject: "Thư mời phỏng vấn",
  body_text: "Kính gửi Anh/Chị,\nTrân trọng.",
  template_version: "test-1",
};

function dbPort(
  authorize: EmailDeliveryDbPort["authorize"] = async () => ({
    success: true,
    data: message,
  }),
) {
  const completions: Array<Record<string, unknown>> = [];
  const db: EmailDeliveryDbPort = {
    claim: async () => [
      {
        email_outbox_id: message.email_outbox_id,
        attempt_id: message.attempt_id,
      },
    ],
    authorize,
    complete: async (input) => {
      completions.push(input);
    },
  };
  return { db, completions };
}

test("runner sends the authorized snapshot and records SENT with the provider id", async () => {
  const { db, completions } = dbPort();
  const sent: AuthorizedEmail[] = [];
  const result = await runEmailDeliveryBatch({
    workerId: "web:test",
    db,
    provider: {
      send: async (email) => {
        sent.push(email);
        return { messageId: "18c0ffee" };
      },
    },
  });
  assert.deepEqual(sent, [message]);
  assert.deepEqual(completions, [
    {
      emailOutboxId: message.email_outbox_id,
      attemptId: message.attempt_id,
      workerId: "web:test",
      outcome: "SENT",
      providerMessageId: "18c0ffee",
      errorCode: null,
    },
  ]);
  assert.deepEqual(result, { claimed: 1, sent: 1, failed: 0, withheld: 0 });
});

test("runner sends nothing when the database withholds authorization", async () => {
  for (const error_code of ["STALE_PREVIEW", "DELIVERY_PAUSED"]) {
    const { db, completions } = dbPort(async () => ({
      success: false,
      error_code,
    }));
    let sends = 0;
    const result = await runEmailDeliveryBatch({
      workerId: "web:test",
      db,
      provider: {
        send: async () => {
          sends++;
          return { messageId: "x" };
        },
      },
    });
    assert.equal(sends, 0);
    assert.deepEqual(completions, []);
    assert.deepEqual(result, { claimed: 1, sent: 0, failed: 0, withheld: 1 });
  }
});

test("runner records retryable and permanent provider failures with accepted codes", async () => {
  for (const [error, outcome, code] of [
    [
      new EmailProviderError("RATE_LIMITED", true),
      "RETRYABLE_FAILURE",
      "RATE_LIMITED",
    ],
    [
      new EmailProviderError("PROVIDER_REJECTED", false),
      "PERMANENT_FAILURE",
      "PROVIDER_REJECTED",
    ],
    [new Error("socket hang up"), "RETRYABLE_FAILURE", "NETWORK_ERROR"],
  ] as const) {
    const { db, completions } = dbPort();
    const result = await runEmailDeliveryBatch({
      workerId: "web:test",
      db,
      provider: {
        send: async () => {
          throw error;
        },
      },
    });
    assert.equal(completions[0].outcome, outcome);
    assert.equal(completions[0].errorCode, code);
    assert.equal(completions[0].providerMessageId, null);
    assert.equal(result.failed, 1);
  }
});

test("MIME message is text-only UTF-8 with encoded subject and no attachment part", () => {
  const mime = buildMimeMessage({
    ...message,
    recipients: { to: ["a@eiu.edu.vn", "b@eiu.edu.vn"], cc: ["c@eiu.edu.vn"] },
  });
  const [head, body] = mime.split("\r\n\r\n");
  assert.match(head, /^To: a@eiu\.edu\.vn, b@eiu\.edu\.vn$/m);
  assert.match(head, /^Cc: c@eiu\.edu\.vn$/m);
  assert.match(head, /^Content-Type: text\/plain; charset="UTF-8"$/m);
  assert.doesNotMatch(mime, /multipart|Content-Disposition/i);
  const subject = /^Subject: (.+(?:\r\n .+)*)$/m.exec(head)?.[1] ?? "";
  const decoded = subject
    .split(/\r\n /)
    .map((word) =>
      Buffer.from(
        /^=\?UTF-8\?B\?(.+)\?=$/.exec(word)?.[1] ?? "",
        "base64",
      ).toString("utf8"),
    )
    .join("");
  assert.equal(decoded, message.subject);
  assert.equal(
    Buffer.from(body.replaceAll("\r\n", ""), "base64").toString("utf8"),
    message.body_text,
  );
  for (const line of mime.split("\r\n")) assert.ok(line.length <= 78);
});

test("MIME builder refuses addresses or subjects that could inject headers", () => {
  for (const bad of ["a@eiu.edu.vn\r\nBcc: x@evil.test", "a@b", "a b@c.d", ""])
    assert.throws(
      () => buildMimeMessage({ ...message, recipients: { to: [bad], cc: [] } }),
      (error) =>
        error instanceof EmailProviderError &&
        error.code === "PROVIDER_REJECTED" &&
        !error.retryable,
    );
  assert.throws(() =>
    buildMimeMessage({ ...message, recipients: { to: [], cc: [] } }),
  );
});

function gmail(send: () => Response | Promise<Response>) {
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  const provider = createGmailProvider(
    { clientId: "id", clientSecret: "secret", refreshToken: "refresh" },
    async (input, init) => {
      const url = String(input);
      calls.push({ url, init });
      if (url.includes("oauth2")) return Response.json({ access_token: "at" });
      return send();
    },
  );
  return { provider, calls };
}

test("Gmail provider sends base64url raw MIME with the access token", async () => {
  const { provider, calls } = gmail(() => Response.json({ id: "18c0ffee" }));
  assert.deepEqual(await provider.send(message), { messageId: "18c0ffee" });
  const send = calls[1];
  assert.equal(
    send.url,
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
  );
  assert.equal(
    new Headers(send.init?.headers).get("Authorization"),
    "Bearer at",
  );
  const raw = JSON.parse(String(send.init?.body)).raw as string;
  assert.match(raw, /^[A-Za-z0-9_-]+$/);
  assert.equal(
    Buffer.from(raw, "base64url").toString("utf8"),
    buildMimeMessage(message),
  );
});

test("Gmail provider maps provider responses to the accepted error codes", async () => {
  for (const [response, code, retryable] of [
    [new Response(null, { status: 429 }), "RATE_LIMITED", true],
    [new Response(null, { status: 503 }), "PROVIDER_TEMPORARY", true],
    [new Response(null, { status: 401 }), "PROVIDER_TEMPORARY", true],
    [new Response(null, { status: 400 }), "PROVIDER_REJECTED", false],
    [Response.json({}), "PROVIDER_TEMPORARY", true],
  ] as const) {
    const { provider } = gmail(() => response);
    await assert.rejects(
      provider.send(message),
      (error) =>
        error instanceof EmailProviderError &&
        error.code === code &&
        error.retryable === retryable,
    );
  }
  const { provider } = gmail(() => {
    throw new TypeError("network down");
  });
  await assert.rejects(
    provider.send(message),
    (error) =>
      error instanceof EmailProviderError && error.code === "NETWORK_ERROR",
  );
});

const saved = { ...process.env };
afterEach(() => {
  process.env = { ...saved };
});

test("email delivery route requires the cron secret and full configuration", async () => {
  const secret = "test-only-cron-secret-long-enough";
  const request = (authorization?: string) =>
    new Request("https://app.example/api/cron/email-delivery", {
      method: "POST",
      headers: authorization ? { Authorization: authorization } : {},
    });
  process.env.CRON_SECRET = secret;
  assert.equal((await emailDelivery(request())).status, 401);
  assert.equal((await emailDelivery(request("Bearer wrong"))).status, 401);
  delete process.env.EMAIL_WORKER_TOKEN;
  const response = await emailDelivery(request(`Bearer ${secret}`));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "NOT_CONFIGURED" });
});
