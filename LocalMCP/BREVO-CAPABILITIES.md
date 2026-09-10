# MacBridge Brevo expansion — implementation and operating contract

Reviewed 2026-09-09. **Uninstalled candidate, not production/normal-Chat acceptance.**
See the release report for exact artifacts, test evidence and installation gates.

## Architecture and tool coverage

Ten grouped tools extend the existing two Brevo tools: twelve Brevo tools and
sixty-seven MB tools total. No separate connector, model, REST proxy, browser
fallback, dependency, listener, login item or tunnel was added.

BrevoToolCatalog defines typed action fields and runtime validation.
BrevoExtendedOperations maps them to fixed public API routes. BrevoSafety owns
gates, versions, pagination and receipts. BrevoAudience resolves bounded membership.
BrevoCampaignActions extends the existing campaign tool; BrevoOperations retains
the credential loader, fixed-origin transport and compatibility reads.

| Tool | Actions |
| --- | --- |
| brevo_read | account, campaigns, campaign, senders, lists |
| brevo_campaign | create, update, duplicate, archive, schedule, cancel_schedule, send_test, send_now, preflight |
| brevo_contacts | list, get, history, attributes, create, update, import, process, processes, create_attribute, update_attribute, delete_attribute, consent_groups, consent_group |
| brevo_lists | list, get, members, folders, folder, folder_lists, create, update, delete, add_members, remove_members, create_folder, update_folder |
| brevo_segments | list, members, capabilities |
| brevo_automations | capabilities, attribution |
| brevo_templates | list, get, create, update, duplicate, activate, deactivate, delete |
| brevo_events | list, track, track_batch |
| brevo_transactional | messages, events, content, scheduled |
| brevo_deliverability | senders, domains, domain, ips, sender_ips, blocked_contacts, blocked_domains, block_domain, unblock_domain, unblock_contact |
| brevo_webhooks | list, get, create, update, delete, capabilities |
| brevo_reports | daily, aggregate, attribution, attribution_detail, attribution_products, campaign_ab, account_activity |

Typed arguments are primary. Legacy campaign body_json is retained but validated
against a closed field allowlist; it is not an HTTP/body escape hatch. Remote
HTML/attachment URLs are not accepted: use inline HTML or an existing template.
Existing names are retained, but stronger gates require some callers to update.
Normal Chat must refresh the existing MacBridge Developer connection's metadata
after installation; a local catalog alone does not prove host discovery.

## Reads and truthful results

- Reads require no confirmation. Each live operation verifies the actual account
  against `BREVO_ACCOUNT_EMAIL` from the owner's private configuration, using the
  same key and immutable account binding for the complete operation.
- Preserve real IDs, timestamps, membership, blacklist and optional consent fields.
  Missing data is unknown, not healthy or consented. Shopify remains consent truth.
- Account output includes plans/credits/organization IDs/feature booleans when
  provided, never relay passwords or tracker keys. Plan period end is not a
  guaranteed credit-reset date; absent account limits remain unavailable.
- Pages have limit/offset/returned_count/count/has_more and next_offset when needed.
  MB caps pages at 100, or 50 where the endpoint requires it. Missing vendor totals
  give count=null. A full page without a total requires another page. Type errors,
  inconsistent totals and stalls are errors, not truncated success.
- Webhooks without a type query request marketing, transactional and inbound;
  partial failures produce complete=false, count=null and per-type errors.
- Templates/messages omit content by default; use include_content for an explicit
  content read. Campaigns retain include_html_content. Contact/history reads can
  include personal data; summarize only necessary metadata during acceptance.
- The domain-list API may report multiple pages but documents no page input;
  unseen pages are reported, not guessed or declared complete.

## Write gates

Every write defaults to offline dry-run: argument validation, endpoint/target,
changed fields, known count, communication risk and pending server checks.
No credentials or network are used for these previews. An unknown count/current
state/quota is pending, not validated.

Live writes require apply=true, confirm_write=true and verified_account_email
matching the locally configured account, then an actual account check.
Existing objects also need current expected_modified_at or expected_version.
Campaigns retain the stricter expected_modified_at contract.

| Consequence | Additional gate |
| --- | --- |
| Campaign send/test/schedule | confirm_send equals the campaign ID as a string; "new" for creation with scheduling. Never inferred from confirm_write. |
| Audience assignment/send/schedule | maximum_recipients, expected_recipient_count and expected_audience_version from preflight. Tests use explicit addresses and both count fields. |
| Contact/list membership/events that may trigger flows | confirm_activate and both count fields for explicit affected contacts, not a fabricated downstream email count. |
| Template activation/active template edit | confirm_activate; downstream consumers/count are not fully exposed by the API. |
| Webhook creation/change | confirm_activate; public HTTPS hostname, no URL credentials/query/fragment or caller-supplied secret headers. |
| Consent/email identity/blacklist | confirm_sensitive; membership never establishes consent. |
| Deletion/suppression removal | confirm_destructive; suppression removal also requires confirm_sensitive. |

Version hashes cover sanitized vendor objects. These are optimistic pre-read
checks, not vendor-side atomic compare-and-swap. Secret-only changes are not
represented by sanitized hashes. Current IDs are also checked where available.

- No force-merge, blind bulk overwrite, bulk unblacklist, remote import URL,
  notification callback URL, or contact deletion. Import accepts <=100 explicit
  emails and non-sensitive attributes with updateExistingContacts=false; process
  ID/status remain available. Existing contacts use individual versioned updates.
- List add/remove accepts <=100 explicit emails or IDs, never "all".
- Campaign duplication creates an unscheduled draft with no audience. Template
  duplication creates an inactive copy. Active templates cannot be deleted.
- Non-draft campaigns must be canceled/re-read before editing/sending.
- Transactional unblocking checks the contact revision, not an atomic suppression
  revision. Domain suppression affects future global delivery; no fake count.
- No transactional send action.
- Template activation can affect an unknown number of future sends. The candidate
  reports this limitation and requires specific activation approval; it does not
  promise recipient-bounded workflow activation.

## Audience preflight and <=300 safety

Use brevo_campaign action=preflight with campaign_id or proposed recipients.
Proposed recipients may override current recipients for a read-only preflight.

Actual paginated list/segment membership is enumerated, deduplicated by email,
then explicit exclusions and email blacklists are removed. The resulting members
and revisions are hashed. Missing blacklist/revision, duplicate sources,
overlapping/changing pages or unknown/inconsistent totals stop the operation.
Counts of overlapping lists are never summed.

Limits: 20 sources, 32 page requests, 3,200 returned membership rows, 20-second
budget for starting further audience reads. In-flight requests have independent
timeouts; this is not a hard 20-second wall-clock deadline.

Audience assignment and send reread the members, compare exact count/hash and
maximum, then reread campaign revision/state after the scan. 1,243 vs 300 is
rejected before mutation. recipient_count is an upper bound before other vendor
suppression. consent_verified stays false: no Shopify consent is read here.

**The vendor does not atomically freeze membership with sending/scheduling.**
Changes after preflight remain possible, especially before a future scheduled
delivery. maximum_recipients is an execution-time guard, not a guaranteed future
Brevo delivery cap. Control the destination cohort and do not claim an immutable
scheduled <=300 audience without vendor support.

## Transport, credentials, outcomes

Only https://api.brevo.com/v3/; ephemeral bounded sessions, no cookies/cache,
redirects or automatic retries. Bodies <=256 KiB, responses <=5 MiB. The existing
owner-only/no-follow credential loader binds one key to preflight and operation.
No key, credential path or HTTP transport is accepted in tool arguments.

Timeout/transport failure/5xx/malformed success/oversized write response means
outcome_unknown, write_occurred=null, no retry, reconcile by reading. 202/process
responses are accepted; partial/207 responses are partial, not completed/delivered.
4xx remains rejected. Rate-limit/error status is preserved in the bounded error.

Auth, tracker/relay secrets, webhook URL path/query, and signed export/import
report URLs are redacted. Process status remains readable; report URLs are not
downloaded. Destination validation is syntactic, not a DNS/receiver-security audit.

## Documented public API limits

The reviewed [official v3 index](https://developers.brevo.com/llms.txt) does not
document workflow inventory/status, active/paused controls, rules/step editing,
current contact position, execution logs or started/finished/suspended counts.
Known-workflow-ID attribution exists but does not establish these states.

Welcome/Abandoned Checkout operational inspection therefore remains unavailable.
Templates/events/SMTP history are supporting evidence only, not proof of current
workflow state or a specific remove-from-list step.

The [segment index](https://developers.brevo.com/reference/get-segments) supplies
ID/name/category/timestamp. [Contacts](https://developers.brevo.com/reference/get-contacts)
supports segment filtering for members/count. No documented segment rule CRUD or
refresh is claimed. [Custom events retrieval](https://developers.brevo.com/reference/get-events)
and ingestion exist; observed event names are not a complete event-type registry.
[Webhooks](https://developers.brevo.com/reference/get-webhooks) offer CRUD/batching
but no documented enabled toggle. Domain authentication fields are returned as
provided; absent SPF is unavailable, not healthy. Attribution depends on its
configuration; missing revenue is not zero. Scheduled SMTP lookup supports one
message ID, not an unbounded unpaginated batch.

These are reviewed documentation/candidate limits, not a claim that undocumented,
private or future APIs can never exist.

## Private owner configuration

The shared source and app contain no default production account or API key.
Live Brevo access is disabled until the owner supplies the two required fields
in `~/.config/macbridge/brevo.env`: `BREVO_API_KEY` and `BREVO_ACCOUNT_EMAIL`.
The file must be owned by that user, mode 0600, single-linked, regular, at most
16 KiB, and reached without symlinks. Duplicate or unknown fields are rejected.
Never include the file in a source archive, app, DMG, screenshot or support log.

Key and account are read together once per operation. Remote tool arguments
cannot select a credential file, change the configured account, install a
transport or override the Brevo origin. `verified_account_email` confirms the
existing local binding; it cannot choose another account. A missing binding or
account mismatch stops the operation. Dry runs and capability checks do not
read this configuration or contact Brevo.

An older deployment with a separately named connector file requires an explicit
local migration before installing this candidate. No legacy files are searched,
copied or modified automatically. The source migration does not alter a running
installation or its credential configuration.

## Post-install acceptance

1. Verify exact installed build/owner/catalog identity and perform a read-only
   normal-Chat capability check. A local catalog does not prove host enablement.
2. With separately authorized account access, verify the configured account and
   bounded metadata reads. Do not print credentials or unnecessary contact data.
3. Test dry runs first. Any live write test needs separate authorization, a new
   isolated disposable target, exact version checks, readback and recovery.
4. Keep account-specific strategy, list IDs, campaign IDs, consent evidence and
   schedules in private operating records, never the shared source or defaults.
5. No send, test-send, schedule, customer import or production pilot is implied
   by release acceptance. Missing workflow/consent evidence remains unknown.
