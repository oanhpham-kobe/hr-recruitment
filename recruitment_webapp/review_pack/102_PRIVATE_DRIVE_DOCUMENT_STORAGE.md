# 102. Private Drive document storage

## Controlled source change

CR-DRIVE-FILES-HOSTED-20261105. Owner authorized file capability and a hosted
development deployment using Oanh's account on 05/11/2026. Vercel runs the existing
Next application; Cloudflare runs the byte gateway and scheduled workers;
Supabase retains Auth, domain data, authorization, reservations and jobs; private
Google Drive stores document bytes. This authorization is separate from earlier
local-only work. It does not accept Package 009, authorize main integration or
declare production readiness. Unrelated historical holds remain in force.

## Immutable identities and unchanged policy

`temp_bucket/temp_path` and document `storage_bucket/storage_path` are immutable
logical identities. Existing quarantine names and path shapes remain unchanged.
A private provider-location binding may resolve an identity to one immutable
Drive file ID. No Drive ID, folder ID, public sharing link, OAuth token or provider upload
capability is exposed through browser-readable document metadata. Original
filename is metadata only. Keep PDF, DOC/DOCX, PPT/PPTX, PNG/JPG/JPEG; 5 MB/file;
5 current files/parent; mandatory real malware CLEAN before finalization/access.

Application gateway grants are returned only by authenticated control-plane
actions, expire within 60 seconds, and bind actor, exact context, audience and
purpose. They are never persisted in document metadata or sent in query strings.
Browser byte requests carry the grant and current Supabase access token in
separate headers. The gateway verifies the user with Supabase Auth, compares
the actor and rechecks current database authority before bytes are accessed.
The browser fetches directly from the gateway and uses short-lived local Blob
URLs inside the hardened application viewer; Vercel never relays these bytes.
Every read, scan and recovery bounds the full object to 5 MB and verifies its
SHA-256 and size against immutable sealed evidence before returning bytes or
a range. This detects external edits by the Drive owner; provider metadata
checks followed by unchecked streaming are insufficient. Deployment acceptance
must measure worst-case inspection CPU on the selected Cloudflare plan.

SUPABASE remains the runtime default until the complete Drive gateway is
configured and verified. The first additive binding command accepts candidate
form reservations only; interview binding requires its own contextual command.
Existing interview uploads and every existing lifecycle remain unchanged.
Executable definitions live in the additive forward migration
`20261105160739_private_drive_object_locations.sql`; existing lifecycle migrations
remain authoritative for Save/Submit, scan and cleanup commands.

## Binding, upload and inspection

The gateway authenticates the caller and passes the verified actor identity to
the narrow `drive_storage_worker` capability. Database commands recheck the
candidate/session/editable parent and reservation after ordered locks. Lock order
is form session, editable Submission, reservation, storage identity, location.
Provider I/O never runs inside database transactions.

Bind a Drive-generated stable file ID before bytes are sent. Reject an alias
that has ever received a Supabase signed-upload window or already has a Storage
object. Binding is permanent, including after cancellation/reservation deletion.
Supabase object writes for bound aliases are prohibited even through privileged
Storage requests. Browser roles cannot read or mutate provider locations.

Upload attempts have a worker, random fencing token and bounded lease. A gateway
may only CREATE the bound Drive ID, never replace/update its content. On lost
responses it reconciles the exact ID and bytes before resuming inspection; it
must not manufacture another ID. A superseded worker cannot seal evidence.
Drive writes must be stopped within their registered bounded write horizon;
resumable sessions that can outlive that horizon are not enabled in this release.
Do not persist OAuth secrets or resumable bearer URLs in database rows/audit.

Trusted seal verifies size/MIME/signature/hash for the exact bound object and
atomically records the existing UPLOADED/PENDING inspection evidence. It never
reports CLEAN. Existing scan request/attempt/fencing and staged Save/Submit
remain authoritative. Sealed byte identity cannot be overwritten. Folder
organization is optional and cannot gate database Save or alter access.
Seal retries replay only while the same lease and candidate context remain
valid. After expiry, the gateway resolves the permanent SEALED evidence for
reconciliation; it does not reclaim an upload or replay a mutation using an
expired fence. Expiry still blocks Save/Submit and cannot be renewed by sealing.

## Read and cleanup

Provider resolution is a narrow internal operation, not user authorization.
`resolve_drive_object_location` returns null only for an unbound legacy alias.
A bound location must never fall back to Supabase on provider errors; user reads
require SEALED bytes and the existing accepted CLEAN document-version reference.
`resolve_drive_scan_attempt` is restricted to `document_scan_worker`; it verifies
the exact live request/attempt/worker/fence and sealed fingerprint before exposing
the Drive scan target. `authorize_drive_document_read` is restricted to
`drive_storage_worker`; its verified actor UUID is resolved explicitly (not from
the worker JWT subject). Existing internal-user serialization, active binding,
Root or `submissions.view`, exact Submission/logical/version, CLEAN and immutable
sealed evidence are checked before attributed DOCUMENT_ACCESS audit and routing.
Purpose is exactly preview/download; only PDF/PNG/JPEG may preview. No Interview
read expansion or candidate read authority is added by this internal-user seam.
PostgREST authenticator may select the narrow Drive and scanner worker roles
only through separately provisioned verified worker credentials. Browser and
service roles receive neither role membership nor the new command grants.
The application must retain contextual read checks and mandatory document access
audit before issuing a short-lived purpose/audience/actor-bound gateway grant.
The browser fetches Cloudflare bytes with its Supabase Authorization header and
a separate grant header. The gateway verifies the actual caller with Supabase
`/auth/v1/user`, compares that ID with the grant actor and revalidates current
document authorization before redeeming the grant. A transferable grant alone
is insufficient. Neither JWT nor grant appears in a URL/query string.
The browser consumes a bounded 5 MB Blob URL inside the existing hardened
same-origin PDF/image viewer or download flow and revokes that URL on cleanup.
Only PDF/PNG/JPEG may preview. All allowed formats download with normalized
Content-Disposition, no-store and nosniff. File bytes never relay through Vercel.

Cleanup retains the existing claim, authorization, tombstone, signed-write
deadline and fenced-completion protocol. Resolve a Drive target only from an
authorized exact cleanup attempt. Keep binding/provenance after deletion;
retained historical versions continue blocking cleanup. Generic Drive 404 is
not proof of absence: reconcile access and exact identity before success.
No Supabase-to-Drive copy/switch/replica cleanup protocol is introduced.

## Runtime gates and acceptance

Connected plugin credentials are not application runtime credentials. OAuth
client/refresh credentials, private folder, gateway keys, narrow worker tokens,
real scanner and schedules must be configured separately. Until then runtime
fails closed and no real scan, Drive upload or hosted end-to-end PASS is claimed.

- AC-DRIVE-01: actual browser/service roles cannot bind, lease, seal or read raw locations.
- AC-DRIVE-02: duplicate binding is stable; conflicting Drive IDs/payloads fail;
  aliases with prior Supabase upload rights fail; bound aliases reject Storage writes.
- AC-DRIVE-03: lease fencing rejects stale seal, sealed writes cannot restart,
  and trusted inspection leaves malware PENDING, never CLEAN.
- AC-DRIVE-04: synchronized competing bind/cancel/expiry cannot bypass lifecycle
  checks; bindings survive reservation removal and retained versions block deletion.
- AC-DRIVE-05: configured runtime proves private exact-byte preview/download,
  contextual revocation, real scan and provider response-loss/cleanup recovery.
  This acceptance remains pending until the gateway and credentials exist.

## Provider-specific worker claims

CR-DRIVE-FILES-HOSTED-20261105 additionally requires provider selection inside
the database claim transaction, before SKIP LOCKED and LIMIT. Immutable private
location binding means Drive; absence means legacy Supabase. Existing
`claim_document_scan_requests` and `claim_storage_cleanup_jobs` retain their
three-argument signatures/results and now claim only Supabase work.
`claim_drive_document_scan_requests` and `claim_drive_storage_cleanup_jobs`
claim only Drive work with the same signatures/results and respective narrow
scanner/cleanup roles. Browser/service grants are not broadened.

Both normal cleanup claims and exhausted-attempt selection are partitioned.
No runner may claim then discard another provider's jobs: its status, attempts,
lease and fencing token must remain untouched. Scan attempt limits and existing
candidate-owned exhausted-scan continuation remain unchanged. Claims preserve
the existing eligibility, lock, audit and fencing protocols. A binding cannot
be newly created after a reservation becomes UPLOADED or terminal; binding
survives reservation removal. Existing trusted producers publish scan work only
after inspection and cleanup work only after cancellation/expiry/detachment or
document retirement, so provider classification is stable for claimable work.

- AC-DRIVE-06: actual-role mixed queues prove provider isolation, no starvation
  at LIMIT 1, partitioned exhaustion and unchanged other-provider attempts/fences.
  Concurrent claims of one provider retain a single owner and fresh retry fence.
