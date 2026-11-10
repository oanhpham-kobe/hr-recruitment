import "server-only";

import {
  type AuthorizedEmail,
  type EmailProvider,
  EmailProviderError,
} from "./delivery-runner";

// Deliberately narrow: no whitespace, separators or quoting, so an address
// can never break out of its header line.
const ADDRESS =
  /^[^\s@<>,;:"()[\]\\]+@[^\s@<>,;:"()[\]\\]+\.[^\s@<>,;:"()[\]\\]+$/;

function addressHeader(name: string, addresses: string[]): string {
  const lines = [`${name}:`];
  addresses.forEach((address, index) => {
    const piece = ` ${address}${index < addresses.length - 1 ? "," : ""}`;
    const last = lines.length - 1;
    if (lines[last] !== `${name}:` && lines[last].length + piece.length > 78)
      lines.push(piece);
    else lines[last] += piece;
  });
  return lines.join("\r\n");
}

/** RFC 2047 encoded-words, split on character boundaries. */
function encodedSubject(subject: string): string {
  const words: string[] = [];
  let chunk = "";
  for (const char of subject) {
    if (Buffer.byteLength(chunk + char) > 39) {
      words.push(chunk);
      chunk = "";
    }
    chunk += char;
  }
  words.push(chunk);
  return words
    .map((word) => `=?UTF-8?B?${Buffer.from(word).toString("base64")}?=`)
    .join("\r\n ");
}

/**
 * Text-only message: To/Cc, Subject and Body. Phase 1 system email has no
 * attachments (spec 43). Gmail supplies From, Date and Message-ID.
 */
export function buildMimeMessage(email: AuthorizedEmail): string {
  const to = email.recipients.to ?? [];
  const cc = email.recipients.cc ?? [];
  if (to.length < 1 || [...to, ...cc].some((value) => !ADDRESS.test(value)))
    throw new EmailProviderError("PROVIDER_REJECTED", false);
  const body = Buffer.from(email.body_text).toString("base64");
  return [
    addressHeader("To", to),
    ...(cc.length ? [addressHeader("Cc", cc)] : []),
    `Subject: ${encodedSubject(email.subject)}`,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    (body.match(/.{1,76}/g) ?? []).join("\r\n"),
  ].join("\r\n");
}

export type GmailConfig = {
  clientId: string;
  clientSecret: string;
  refreshToken: string;
};

export function createGmailProvider(
  config: GmailConfig,
  fetchFn: typeof fetch = fetch,
): EmailProvider {
  async function request(url: string, init: RequestInit): Promise<Response> {
    try {
      return await fetchFn(url, {
        ...init,
        cache: "no-store",
        signal: AbortSignal.timeout(15_000),
      });
    } catch {
      throw new EmailProviderError("NETWORK_ERROR", true);
    }
  }

  // One token per batch; a failed refresh is not cached.
  let token: Promise<string> | undefined;
  function accessToken(): Promise<string> {
    token ??= (async () => {
      const response = await request("https://oauth2.googleapis.com/token", {
        method: "POST",
        body: new URLSearchParams({
          grant_type: "refresh_token",
          client_id: config.clientId,
          client_secret: config.clientSecret,
          refresh_token: config.refreshToken,
        }),
      });
      const result = (await response.json().catch(() => null)) as {
        access_token?: unknown;
      } | null;
      if (!response.ok || typeof result?.access_token !== "string")
        throw new EmailProviderError("PROVIDER_TEMPORARY", true);
      return result.access_token;
    })().catch((error) => {
      token = undefined;
      throw error;
    });
    return token;
  }

  return {
    async send(email) {
      const raw = Buffer.from(buildMimeMessage(email)).toString("base64url");
      const response = await request(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${await accessToken()}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ raw }),
        },
      );
      if (response.status === 429 || response.status === 403)
        throw new EmailProviderError("RATE_LIMITED", true);
      if (response.status === 401 || response.status >= 500)
        throw new EmailProviderError("PROVIDER_TEMPORARY", true);
      if (!response.ok)
        throw new EmailProviderError("PROVIDER_REJECTED", false);
      const result = (await response.json().catch(() => null)) as {
        id?: unknown;
      } | null;
      // Same shape the database accepts as provider_message_id.
      if (
        typeof result?.id !== "string" ||
        !/^[A-Za-z0-9_.:@/+=-]{1,200}$/.test(result.id)
      )
        throw new EmailProviderError("PROVIDER_TEMPORARY", true);
      return { messageId: result.id };
    },
  };
}
