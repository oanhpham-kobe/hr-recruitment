#!/usr/bin/env node
// Mints a PostgREST JWT for one narrow worker role, signed with the Supabase
// project's JWT secret. Same claim shape the storage-cleanup integration test
// proves against PostgREST. The token is printed once; store it as a secret.
//
//   SUPABASE_JWT_SECRET=... node scripts/mint-worker-token.mjs <role> [days=365]
import { createHmac } from "node:crypto";

// Only the narrow worker roles: this must never mint service_role.
const ROLES = [
  "drive_storage_worker",
  "document_scan_worker",
  "storage_cleanup_worker",
  "email_worker",
];
const [role, days = "365"] = process.argv.slice(2);
const secret = process.env.SUPABASE_JWT_SECRET ?? "";
const lifetime = Math.round(Number(days) * 86400);

if (!ROLES.includes(role) || secret.length < 32 || !(lifetime > 0)) {
  console.error(
    `Usage: SUPABASE_JWT_SECRET=<project JWT secret> node scripts/mint-worker-token.mjs <role> [days]\nRoles: ${ROLES.join(", ")}`,
  );
  process.exit(1);
}

const encode = (value) =>
  Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ iss: "supabase", role, iat: now, exp: now + lifetime })}`;
console.log(
  `${body}.${createHmac("sha256", secret).update(body).digest("base64url")}`,
);
