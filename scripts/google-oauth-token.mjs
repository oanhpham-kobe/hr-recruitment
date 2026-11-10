#!/usr/bin/env node
// One-time helper: gets a Google OAuth refresh token on this machine for the
// account you sign in with, using a "Desktop app" OAuth client.
//
//   GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... node scripts/google-oauth-token.mjs drive
//   GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... node scripts/google-oauth-token.mjs gmail
//
// drive: scope drive.file (the app sees only files it creates) and also
//        creates the private folder the gateway stores documents in.
// gmail: scope gmail.send (send only; cannot read the mailbox).
// Secrets are printed to this terminal only. Do not paste them into chat.
import { randomBytes } from "node:crypto";
import { createServer } from "node:http";

const SCOPES = {
  drive: "https://www.googleapis.com/auth/drive.file",
  gmail: "https://www.googleapis.com/auth/gmail.send",
};
const kind = process.argv[2];
const clientId = process.env.GOOGLE_CLIENT_ID ?? "";
const clientSecret = process.env.GOOGLE_CLIENT_SECRET ?? "";
if (!SCOPES[kind] || !clientId || !clientSecret) {
  console.error(
    "Usage: GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... node scripts/google-oauth-token.mjs drive|gmail",
  );
  process.exit(1);
}

const state = randomBytes(16).toString("hex");
const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");
  const code = url.searchParams.get("code");
  if (!code || url.searchParams.get("state") !== state) {
    response.writeHead(400).end("Invalid OAuth response.");
    return;
  }
  response.end("Done. You can close this tab and return to the terminal.");
  server.close();
  try {
    const token = await post("https://oauth2.googleapis.com/token", {
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri(),
      }),
    });
    if (!token.refresh_token) throw new Error("Google returned no refresh token");
    console.log(`\n${kind === "drive" ? "GOOGLE_REFRESH_TOKEN" : "GMAIL_REFRESH_TOKEN"}=${token.refresh_token}`);
    if (kind === "drive") {
      const folder = await post("https://www.googleapis.com/drive/v3/files", {
        headers: {
          Authorization: `Bearer ${token.access_token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          name: "EIU Recruitment documents (private)",
          mimeType: "application/vnd.google-apps.folder",
        }),
      });
      console.log(`GOOGLE_PRIVATE_FOLDER_ID=${folder.id}`);
    }
  } catch (error) {
    console.error(`Failed: ${error.message}`);
    process.exitCode = 1;
  }
});

function redirectUri() {
  return `http://127.0.0.1:${server.address().port}`;
}

async function post(url, init) {
  const response = await fetch(url, { method: "POST", ...init });
  const data = await response.json();
  if (!response.ok)
    throw new Error(data.error_description ?? data.error?.message ?? response.statusText);
  return data;
}

server.listen(0, "127.0.0.1", () => {
  const authUrl = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  authUrl.search = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri(),
    response_type: "code",
    scope: SCOPES[kind],
    access_type: "offline",
    prompt: "consent",
    state,
  }).toString();
  console.log(`Open this URL and sign in with the ${kind === "drive" ? "account that will own the documents" : "mailbox that will send email"}:\n\n${authUrl}\n`);
});
