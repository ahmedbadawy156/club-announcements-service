# Security tests: proposal map (Announcements service)

How the Phase 1 proposal's security tests (Section 6.5, T1 to T10) and
threats (Section 6.4) are covered for the Announcements and Club Activity
service. Every check runs against the Floci deployment; results are saved in
`evidence/test-results.txt` by `bash infra/collect-evidence.sh`.

| Proposal test | Threat | What is checked here | Script: check name |
|---|---|---|---|
| T1 Unauthenticated access | 4 | Feed, publish, edit and activities without a token or with a malformed header get 401 | `announcements.sh`: "T1 …"; `activities.sh`: "T1 …" |
| T2 Unauthorized role | 4 | A member token gets 403 on publish, edit, archive, the scheduled and archived views, and recording an activity; nothing changes; a `role` in the body is ignored | `announcements.sh`: "T2 …"; `activities.sh`: "T2 …" |
| T3 Invalid input | 5 | Empty, too long or object/array titles; missing or too long text; control characters; bad, past, too far or zone-less dates; expiry before publishing; unknown fields; JSON arrays; malformed JSON; bodies over 8 KB; bad ids, views, limits and cursors; future or impossible event dates: 400 or 413, nothing stored | `announcements.sh`: "T3 …"; `announcement-rules.sh`; `activities.sh`: "T3 …" |
| T4 Ownership | 4 | No per-member records here. Author and recorder ids come only from the verified token and are stored server-side (`authorId`, `updatedBy`, `recordedBy`), never taken from the body | `announcements.sh`: "author id stored from the token…"; `announcement-rules.sh`: "updatedBy recorded from the token" |
| T5 Secret exposure | 7, 8 | The function holds only Membership's public key; no private key in Git history, the function configuration or the S3 site; responses leave out internal fields; log lines have no query strings | `infra/collect-evidence.sh` (secret scan); `check.sh`: "no private key in the function configuration", "log lines never contain a query string" |
| T6 Token tampering | 2 | Expired, wrong-key, `alg: none`, HS256-with-public-key, edited payload (member to officer), wrong audience and wrong issuer tokens all get 401 | `announcements.sh`: "T6 …"; `activities.sh`: "T6 …" |
| T8 Injection / XSS | 5 | Script and HTML text in titles, bodies and summaries is stored and returned exactly, as JSON; objects (`{"$ne":null}`, `{"S":"x"}`) are refused with 400; the pages show text with `textContent` (browser test) | `announcements.sh`: "T8 …", "T3 title as an object"; `activities.sh`: "T8 …", "T3 event id as an object" |
| T9 CORS and route exposure | 10 | DELETE and unknown paths stopped by API Gateway (404, Lambda never runs); a foreign Origin gets no Access-Control-Allow-Origin; the site's preflight is allowed | `check.sh` |
| Threat 3 Stale role | 3 | Accepted risk: a demoted officer's token keeps its role here for up to 15 minutes (documented in the README) | n/a |
| Threat 9 IAM least privilege | 9 | With Floci IAM enforcement on, the role may read and write its two tables, and is refused deleting announcements, scanning, updating or deleting activities, Membership's tables and secret, the audit log and ListTables | `iam.sh` |
| Messaging (EventBridge, SQS) | 5, 6, 9 | Only the club bus rule may send to the inbox (queue policy); the worker accepts only `club.events` messages with valid ids, dates and text; bad messages go to the dead-letter queue after 3 tries and are logged by id only; duplicates and out-of-order messages never create extra posts; the worker's own role can read only its inbox and get/put/update announcements; the API role cannot touch the queues or the bus | `from-events.sh`; `iam.sh`: "worker role: …", "API role: … inbox" |
| Threat 11 Rebuild | 11 | `infra/deploy.sh` rebuilds tables, role, function and routes on a clean Floci and is safe to run again | `infra/deploy.sh`, `check.sh` |

T7 (brute force) and T10 (join-request limits) belong to the Membership
service.

## Business rules (not security tests, but tested the same way)

| Rule | Script |
|---|---|
| At most 3 pinned announcements, also when two officers pin at the same moment | `announcement-rules.sh` |
| Pinned first, then newest | `announcement-rules.sh` |
| Edits need the current version (optimistic locking); two simultaneous edits, one wins | `announcement-rules.sh` |
| Archive instead of delete; archived items cannot change; archiving frees the pin | `announcement-rules.sh` |
| Scheduled items appear by themselves when `publishAt` passes; expired items leave the feed | `announcements.sh` |
| Publish time can change only while scheduled; expiry always after publishing | `announcement-rules.sh` |
| One activity per finished event, also when four officers record it at once | `activities.sh` |
