# Media transfer candidate — not installed or live-qualified

This opt-in bridge stages one explicitly selected local creative in a private
Cloudflare R2 bucket and returns a short-lived GET URL for the existing Meta Ads
connector. It does not call Meta, create creatives/ads, activate campaigns,
borrow another connector's credentials, or automate a file/permission picker.
R2 is a proposed storage backend for this candidate, not an approved live account.

## Research and scope (2026-09-11)

The host-exposed Meta Ads ads_creative_upload_media schema has two routes:
LOCAL_FILE opens an interactive picker and has no filesystem-path parameter;
URL accepts media_type IMAGE/VIDEO and a direct media_url. Its returned image
hash or video ID must be verified with Meta's existing read tools; videos must
be ready before use. These are inspected schema contracts, not upload evidence.

The installed MB transport is stdio behind an outbound MCP adapter. There is no
documented arbitrary public-file route in the reviewed MB source. This candidate
does not alter that transport or open an Internet/LAN listener.

R2 ground truth:

- HTTPS S3 endpoint: ACCOUNT_ID.r2.cloudflarestorage.com (including documented
  eu/us/fedramp jurisdiction variants); region auto, service s3.
- PUT /bucket/generated-key uploads bytes, HEAD checks the same object, DELETE
  revokes that object. Only these owner-bound paths are used by the transport.
- Signed GET URLs use AWS Signature V4, fixed object and expiration. Possession
  of the URL grants read access until expiration; it is not Meta-identity-bound.
- API credentials are an Access Key ID and Secret Access Key from R2 Object
  Storage → Account Details → API Tokens → Manage. Object Read & Write must be
  restricted to one dedicated bucket, not account-wide administrator access.
- The owner must keep public bucket access off. Set a one-day bucket lifecycle
  for macbridge-transfers/ as a cleanup backstop before live qualification.
  URL expiration does not itself delete the stored object. No daemon or promise
  of cleanup while the Mac is off is introduced.
- GET signing does not authorize HEAD on that same URL. Whether Meta's URL
  ingestion accepts this route for both images and videos needs a real,
  separately approved upload test. Do not disable URL security to pass it.

Sources actually read:

- https://developers.cloudflare.com/r2/api/s3/presigned-urls/
- https://developers.cloudflare.com/r2/api/s3/api/
- https://developers.cloudflare.com/r2/api/tokens/
- https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html
- https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
- Current host Meta Ads upload schema, inspected without invoking the tool.

## Intended workflow

1. media_inspect prepare hashes one allowed workspace file locally. No network.
2. After approval of that exact file/recipient, media_share publish uses the
   expected SHA-256 and a stable caller-generated request_id. The owner must have
   configured one narrow media root and the dedicated R2 binding first.
3. ChatGPT passes the returned media_url to its existing Meta Ads URL upload.
   MB never claims that staging in R2 proves delivery to Meta.
4. Reconcile Meta's actual image hash/video ID, then media_share revoke removes
   only the staged object. Do not replay Meta create/upload calls blindly.

Network/permission errors remain errors. No switch of providers, picker bypass,
new cloud resource, or installation is authorized by the tool or its response.

## Deployment gate

This native MB feature uses system frameworks only, not a separately installed
Codex skill/helper. Owner configuration remains under .config/macbridge, outside
the writable workspace and denied to MB file/shell tools. It is never bundled.
It must not be installed, enabled, or tested with real media until the owner
approves the exact artifact, storage account/bucket, and first test file.

The source/tests do not certify public URL reachability, real Meta ingestion,
bucket permissions/lifecycle, or normal-Chat host discovery. Keep the current
installed core/tunnel unchanged while those gates are pending.

## Owner configuration contract (not a deployment instruction)

After artifact and storage approval, the owner-authored file is
`~/.config/macbridge/media-share.json`, mode `0600`; the containing directory
must be mode `0700`, owner-owned, and contain no symlink components. No MCP tool
can write this protected configuration or provide credentials in its arguments.
Do not paste credentials into a conversation, command line, repository or log.

Fields, all required except where noted:

| Field | Binding |
| --- | --- |
| `version` | Integer `1` |
| `endpoint` | Exact account R2 S3 HTTPS origin, no custom URL/path/port |
| `bucket` | Dedicated private bucket, lower-case letters/digits/hyphens |
| `access_key_id` | R2 S3 Access Key ID, not a general Cloudflare bearer token |
| `secret_access_key` | R2 S3 Secret Access Key; never returned by tools |
| `workspace_id` | One already registered MB workspace UUID |
| `media_root` | Exact canonical absolute path of one narrow local media folder within that workspace; no symlinks |

Public bucket access must stay disabled. Confirm bucket-scoped Object Read &
Write credentials and a one-day `macbridge-transfers/` lifecycle in the owner's
Cloudflare settings before use. The code cannot infer either from a key string.
R2 billing/activation is not authorized or performed by this candidate.

The adjacent `media-shares.json` receipt journal is owner-only and bound to the
endpoint, bucket, workspace and root. Changing that binding fails closed while
old receipts remain; do not discard them to force retries. A companion lock
admits one operation across processes. Neither file is shipped with a release.

## Call sequence

1. `media_inspect` with `action=capabilities` reads neither credentials nor files
   nor network. It describes the contract; it is not proof storage is configured.
2. `media_inspect` with `action=prepare`, `workspace_id`, `path` returns exact
   `sha256`, `byte_count`, `mime_type` and `media_type`. Only bytes are inspected;
   this is not malware scanning, ad review or full media-decoder validation.
3. With sharing approval, `media_share` with `action=publish`, `workspace_id`,
   `path`, `expected_sha256`, a stable UUID `request_id`,
   `confirm_public_link=true` and optionally `expires_in_seconds` (default 900).
   The acknowledgement field does not create user authorization.
4. Only `share_state=ready` plus `link_available=true` supplies `media_url`.
   `status=staged_not_uploaded_to_meta` deliberately does not claim Meta receipt.
   Pass the exact link and media type to the existing Meta Ads upload schema with
   `upload_source=URL`; respect that connector's own approval requirements.
5. Reconcile uncertain calls using `media_inspect` with `action=status`, the
   original `workspace_id` and `request_id`. Do not allocate a new request UUID
   merely because a write response was lost. Publishing the same UUID never
   performs another PUT or extends its original expiry.
6. After actual Meta receipt/readiness, call `media_share` with `action=revoke`,
   `workspace_id` and `request_id`. Successful revocation means the exact staged
   object was absent on verification. It does not remove copies Meta or someone
   holding the link already downloaded.

Any pending/outcome-unknown publication without a confirmed HEAD remains
uncertain even after a 404; a write may still be completing. It is not reported
as successfully revoked. No application-level transport retries, redirects,
automatic bucket cleanup or implicit link renewal are performed.

## Bounded resource and privacy behavior

- One media operation admitted; extra calls are rejected, not queued. Upload and
  file hashing run outside the shared protocol lock, so other tool metadata and
  activity can still respond. Workspace reload waits for this operation to end.
- 256 MiB/file; at most 1 GiB of outstanding recorded objects; 1,024 durable
  receipts and 1 MiB journal maximum. At either journal bound, stop without
  evicting receipts. An owner-reviewed archive/migration is needed to continue;
  there is no automatic forgetting of past request IDs.
- Snapshot/hash uses 64 KiB chunks and a cooperative 30-second file-read budget.
  The source is not modified. The private temporary snapshot is removed on normal
  completion/error; an abrupt process kill can leave it for OS/owner cleanup.
- Each network operation has 30-second request and 120-second resource limits.
  No public/LAN listener, shell command, daemon, startup item or idle polling.
- The GET bearer link lasts 60–3,600 seconds from initial publication intent, not
  from every status read. Anyone holding it may reuse it until expiry/revocation.
  It is not recipient-bound or one-time. GET does not authorize HEAD on that URL.
- No signed URL, key, provider response body or cookies are kept in MB Activity.
  The link necessarily passes through the authorized caller/host and Meta upload
  tool; MB cannot promise that those services never retain their own transcripts.
- Storage deletion and link expiration are distinct. An expired link does not
  certify deletion, and normal-Chat host loading is not certified by tool count.

## Required live qualification, still pending

Use one approved non-sensitive image, then one approved short video. Record the
exact file SHA-256, real R2 PUT/HEAD, GET reachability, Meta upload response and
video-ready status where applicable. Verify revoke and expired-link behavior.
Test original and repeated request IDs across a separate test-owner restart;
do not restart a live owner with active work/held undo for this test.

If Meta attempts HEAD first or otherwise rejects a presigned GET, record the
exact redacted rejection. Do not remove access controls, make the bucket public,
borrow Meta credentials, switch connectors, or claim this route is accepted.
Choose and approve a different restricted media-delivery mechanism first.
