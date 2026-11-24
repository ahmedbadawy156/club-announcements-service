# club-announcements-service

Campus Club Management (Team 10): **Announcements and Club Activity** service.
Owner: Mazen Mohammed Abdelfattah.

A Node.js + Express API on AWS Lambda behind API Gateway, with data in
DynamoDB, deployed to **Floci** (a local AWS emulator) with IAM enforcement
on. It follows the Lab 7 pattern and the same structure as
`club-membership-service`. The same Express app also runs on a PC with
`npm run dev`.

## What the service does

- **Officers** publish announcements now or at a chosen time, pin up to 3,
  edit them, set or clear an expiry, and archive them (never hard-deleted).
- **Members** see the current announcements, pinned first. Scheduled ones
  appear by themselves when their time comes; expired and archived ones
  disappear. No scheduler service is needed: the dates are checked when the
  feed is read.
- **Officers** record what happened at a finished event (one record per
  event). **Members** browse past activities, newest event first.

Sign-in is done by `club-membership-service`, which issues the login token.
This service only **verifies** that token with Membership's public key and
enforces the roles itself.

## Architecture

```
Browser (S3 site club-web)
   |  fetch + "Authorization: Bearer <token from Membership>"
   v
API Gateway  club-announcements-http-api   only the routes in infra/routes.txt
   v
Lambda       club-announcements-api        Express app (serverless-http)
   |-- DynamoDB  Announcements (StatusIndex), Activities (FeedIndex)
   |-- CloudWatch Logs  /aws/lambda/club-announcements-api
   '-- IAM role club-announcements-role    least privilege, enforced by Floci
```

## AWS services used (5)

| Service | Use | Evidence |
|---|---|---|
| Lambda | Runs the Express app | `aws lambda get-function`, `evidence/floci-resources.txt` |
| API Gateway (HTTP API) | Route allow-list and entry point | `aws apigatewayv2 get-routes`; unlisted DELETE refused (`check.sh`) |
| DynamoDB | Two tables, transactions and conditional writes | `infra/dynamodb/`, test results |
| IAM | Role limited to the two tables and its own log group; no deletes | `infra/iam/announcements-policy.json`, `tests/iam.sh` |
| CloudWatch Logs | One line per request; denied requests counted | `evidence/floci-resources.txt` |

No Secrets Manager: this service has no secret. It holds only Membership's
**public** key, set by `deploy.sh` as the `JWT_PUBLIC_KEY_B64` environment
variable.

## Endpoints

| Method | Path | Who | What |
|---|---|---|---|
| GET | `/api/health` | Public | Service status |
| GET | `/api/announcements?view=current&limit=` | Member, Officer | Current feed, pinned first |
| GET | `/api/announcements?view=scheduled\|expired\|archived` | Officer | Other views (members get 403) |
| POST | `/api/announcements` | Officer | `{ title, body, pinned?, publishAt?, expiresAt? }` |
| PATCH | `/api/announcements/{id}` | Officer | `{ version, title?, body?, pinned?, publishAt?, expiresAt? }` or `{ version, status: "archived" }` |
| GET | `/api/activities?limit=&before=` | Member, Officer | Past activities, newest event first |
| POST | `/api/activities` | Officer | `{ eventId, eventTitle, eventDate: "YYYY-MM-DD", summary }` |

Dates are ISO 8601 with a time zone (for example `2026-12-01T18:00:00Z`).

### Error codes

| Status | `error` | When |
|---|---|---|
| 400 | `validation_failed` (+ `fields`), `invalid_json` | Bad input |
| 401 | `sign_in_required`, `invalid_token` | No token, or expired, forged or tampered token |
| 403 | `officer_only` | Member on an officer route or view |
| 404 | `announcement_not_found`, `not_found` | Unknown announcement or path |
| 409 | `pin_limit_reached` | Already 3 pinned |
| 409 | `version_conflict` | Someone else edited it first |
| 409 | `announcement_archived` | Archived items cannot change |
| 409 | `already_published` | Publish time can change only while scheduled |
| 409 | `announcement_expired` | Expired items cannot be pinned |
| 409 | `activity_exists` | The event already has an activity |
| 413 | `body_too_large` | Body over 8 KB |

## Business rules and how they hold under concurrency

| Rule | How |
|---|---|
| At most 3 pinned | A counter item `META#pins` is changed in the **same DynamoDB transaction** as the pin, only while it is below 3. Two officers taking the last slot at once: one 200, one 409 (tested). |
| No lost edits | Every edit sends the `version` it read; the update is conditional on that version (optimistic locking). Two simultaneous edits: one wins, the other gets 409 (tested). |
| Archive, not delete | Archived items are kept and can no longer change; archiving unpins and frees the slot. The IAM role has no `DeleteItem` at all. |
| Scheduling without a scheduler | `StatusIndex` (`status`, `publishAt`) splits scheduled (`publishAt > now`) from published; expiry is checked when reading. |
| Date rules | `publishAt` not in the past and at most a year ahead; it can change only while scheduled; `expiresAt` always after `publishAt`. |
| One activity per event | A claim item `EVENT#<eventId>` is written in the same transaction, only if absent. Four officers recording the same event at once: one 201, three 409 (tested). |
| Finished events only | `eventDate` must be today or earlier (and within 10 years). |

## Security controls

| Control | How |
|---|---|
| Token verification | RS256 only, issuer `club-membership`, audience `campus-club`, not expired; `alg:none`, HS256, wrong key and edited tokens get 401 |
| Roles in the backend | `requireOfficer` on every write; the role and user id come only from the verified token |
| No private key here | Only the public key, fetched from Membership's public endpoint at deploy time; `check.sh` confirms no private key in the function configuration |
| Input validation | Types, lengths, control characters, real dates, unknown fields refused; DynamoDB values always passed as placeholders |
| XSS | Text is stored as typed and returned as JSON; the frontend shows it with `textContent` |
| Least privilege | IAM role: Announcements Get/Put/Update/Query, Activities Get/Put/Query (append-only), own log group; tested with real AccessDenied |
| Route exposure and CORS | API Gateway allow-list; CORS only for `http://localhost:4566` |
| Logs | Method, path, status and time only: no bodies, query strings or tokens |

## Run it

Needs Docker Desktop, Node.js, Git Bash, AWS CLI v2 with the `floci` profile
(see the team guide), and **club-membership-service deployed on the same
Floci first** (this service needs its public key).

```
docker compose -f infra/floci/docker-compose.yml up -d   # same Floci as Membership
bash infra/deploy.sh                                      # tables, role, Lambda, API
bash tests/run-all.sh                                     # every test suite
bash infra/collect-evidence.sh                            # saves evidence/
```

Run the scripts in Git Bash from the repository root. The frontend reads this
service's address from `infra/out/api.env` (`npm run deploy` in
`club-frontend`).

To run the API on your PC instead: copy `backend/.env.example` to
`backend/.env`, paste the value of `infra/out/public-key.b64` into
`JWT_PUBLIC_KEY_B64`, then `cd backend && npm install && npm run dev`
(http://127.0.0.1:3001).

## Tests

| Suite | Checks |
|---|---|
| `infra/check.sh` | Deployment, gateway refusals, CORS, no private key, CloudWatch Logs |
| `tests/announcements.sh` | T1, T2, T3, T6, T8, scheduling and expiry |
| `tests/announcement-rules.sh` | Pin limit and race, order, optimistic locking and race, archive, date rules |
| `tests/activities.sh` | Roles, validation, one per event and race, paging, T8 |
| `tests/iam.sh` | Least privilege with a probe function using the same role |

`docs/security-tests.md` maps every check to the proposal's T1 to T10.
Test tokens are signed by `tests/helpers.js` with Membership's key read from
the **local** Floci only; test data uses ids starting with
`aaaaaaaa-0000-4000-8000-` and is removed after each suite.

## Repository layout

```
backend/   app.js, server.js, lambda.js, routes/, controllers/, services/,
           middleware/, lib/, scripts/zip-lambda.js
infra/     floci/docker-compose.yml, config.sh, deploy.sh, check.sh,
           collect-evidence.sh, dynamodb/, iam/, routes.txt
tests/     lib.sh, helpers.js, *.sh suites, iam-probe/, run-all.sh
docs/      security-tests.md
evidence/  test results, Floci resource listing, secret scan
```

## Known gaps and accepted risks

- A demoted officer's token keeps the officer role here for up to 15 minutes
  (no revocation; Membership itself re-checks its table).
- The event id of an activity is not checked against the Events service,
  because services do not call each other (proposal Section 5.3).
- The feed reads all current items (up to 1000) and sorts them in the
  function; fine for one club, not for very large data.
- Floci only; IAM evaluation is an emulation and may differ from AWS in details.
