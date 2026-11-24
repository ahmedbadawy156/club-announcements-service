#!/usr/bin/env bash
# Announcements: access control, token checks, input validation and the feed.
# Proposal tests T1, T2, T3, T6 and T8 for this service.
#   bash tests/announcements.sh        (after bash infra/deploy.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
source infra/out/api.env
source tests/lib.sh

echo "== Announcements: access, tokens, validation, feed ($API_URL)"
cleanup_test_data >/dev/null

OFFICER=$(helper token "$OFFICER_ID" officer)
MEMBER=$(helper token "$MEMBER_ID" member)
UNKNOWN_ID=00000000-0000-4000-8000-000000000000
count_test_items() { helper get "$1" | jget 'j ? 1 : 0'; }

# --- T1: no token ---------------------------------------------------------
check "T1 GET feed without a token" 401 "$(call GET /api/announcements -)"
check "T1 error code" sign_in_required "$(body | jget j.error)"
check "T1 POST without a token" 401 "$(call POST /api/announcements - '{"title":"No token","body":"x"}')"
check "T1 PATCH without a token" 401 "$(call PATCH /api/announcements/$UNKNOWN_ID - '{"version":1,"pinned":true}')"
check "T1 malformed Authorization header" 401 \
  "$(curl -s -o /dev/null -w '%{http_code}' -m 60 -H 'Authorization: Basic abc' "$API_URL/api/announcements")"

# --- T6: tampered tokens ----------------------------------------------------
for v in expired wrongkey none hs256 tampered wrongaud wrongiss; do
  T=$(helper token "$MEMBER_ID" member "$v")
  check "T6 $v token on the feed" 401 "$(call GET /api/announcements "$T")"
done
T=$(helper token "$OFFICER_ID" officer none)
check "T6 alg:none 'officer' token cannot publish" 401 "$(call POST /api/announcements "$T" '{"title":"Forged","body":"x"}')"
T=$(helper token "$MEMBER_ID" member tampered)
check "T6 member token edited to say officer cannot publish" 401 "$(call POST /api/announcements "$T" '{"title":"Forged","body":"x"}')"
check "T6 error code" invalid_token "$(body | jget j.error)"

# --- Officer publishes; member reads ---------------------------------------
check "officer publishes an announcement" 201 \
  "$(call POST /api/announcements "$OFFICER" '{"title":"Welcome back","body":"First meeting on Monday.\nBring a friend."}')"
A1=$(body | jget j.id)
check "new announcement is current, version 1" "current 1" "$(body | jget '`${j.state} ${j.version}`')"
check "author name comes from the token" "Test Officer" "$(body | jget j.authorName)"
check "internal fields are not returned" "" "$(body | jget 'j.authorId ?? j.updatedBy ?? j.status')"
check "author id stored from the token, not the body" "$OFFICER_ID" "$(helper get "$A1" | jget j.authorId)"

check "member reads the feed" 200 "$(call GET /api/announcements "$MEMBER")"
check "member sees the announcement" yes "$(body | jget "j.announcements.some(a => a.id === '$A1') ? 'yes' : 'no'")"
check "body newlines kept as text" "First meeting on Monday.|Bring a friend." "$(body | jget "j.announcements.find(a => a.id === '$A1').body.replace('\n','|')")"
check "members do not get the edit version" "" "$(body | jget "j.announcements.find(a => a.id === '$A1').version")"

# --- T2: member on officer routes ------------------------------------------
check "T2 member cannot publish" 403 "$(call POST /api/announcements "$MEMBER" '{"title":"Member post","body":"Should fail"}')"
check "T2 error code" officer_only "$(body | jget j.error)"
check "T2 member cannot edit" 403 "$(call PATCH /api/announcements/$A1 "$MEMBER" '{"version":1,"title":"Hacked title"}')"
check "T2 member cannot archive" 403 "$(call PATCH /api/announcements/$A1 "$MEMBER" '{"version":1,"status":"archived"}')"
check "T2 member cannot see scheduled items" 403 "$(call GET '/api/announcements?view=scheduled' "$MEMBER")"
check "T2 member cannot see archived items" 403 "$(call GET '/api/announcements?view=archived' "$MEMBER")"
check "T2 announcement unchanged after member attempts" "Welcome back 1" "$(helper get "$A1" | jget '`${j.title} ${j.version}`')"
check "T2 a role in the body is ignored" 403 \
  "$(call POST /api/announcements "$MEMBER" '{"title":"Sneaky","body":"x","role":"officer"}')"

# --- T3: invalid input --------------------------------------------------------
v400() { # NAME JSON [EXPECTED_FIELD]
  local code; code=$(call POST /api/announcements "$OFFICER" "$2")
  check "T3 $1" "400${3:+ $3}" "$code${3:+ $(body | jget 'j.fields && j.fields.join(",")')}"
}
v400 "empty title" '{"title":"","body":"x"}' title
v400 "title only spaces" '{"title":"   ","body":"x"}' title
v400 "title too long (121)" "{\"title\":\"$(printf 'a%.0s' {1..121})\",\"body\":\"x\"}" title
v400 "title as an object" '{"title":{"$ne":null},"body":"x"}' title
v400 "title as an array" '{"title":["a","b","c"],"body":"x"}' title
v400 "missing body" '{"title":"No body"}' body
v400 "body too long (2001)" "{\"title\":\"Long\",\"body\":\"$(printf 'b%.0s' {1..2001})\"}" body
v400 "control character in title" '{"title":"Bad\u0007bell","body":"x"}' title
v400 "pinned not a boolean" '{"title":"Pin","body":"x","pinned":"yes"}' pinned
v400 "publishAt not a date" '{"title":"Date","body":"x","publishAt":"next monday"}' publishAt
v400 "publishAt without a time zone" '{"title":"Date","body":"x","publishAt":"2030-01-01T10:00:00"}' publishAt
v400 "publishAt in the past" "{\"title\":\"Past\",\"body\":\"x\",\"publishAt\":\"$(iso -86400)\"}" publishAt
v400 "publishAt more than a year ahead" "{\"title\":\"Far\",\"body\":\"x\",\"publishAt\":\"$(iso 40000000)\"}" publishAt
v400 "expiresAt before publishAt" "{\"title\":\"Exp\",\"body\":\"x\",\"publishAt\":\"$(iso 7200)\",\"expiresAt\":\"$(iso 3600)\"}" expiresAt
v400 "expiresAt already passed" "{\"title\":\"Exp\",\"body\":\"x\",\"expiresAt\":\"$(iso -60)\"}" expiresAt
v400 "unknown field" '{"title":"Extra","body":"x","authorId":"someone"}' authorId
check "T3 body is a JSON array" 400 "$(call POST /api/announcements "$OFFICER" '[1,2]')"
check "T3 malformed JSON" 400 "$(call POST /api/announcements "$OFFICER" '{"title": "broken"')"
check "T3 malformed JSON error code" invalid_json "$(body | jget j.error)"
check "T3 body over 8 KB" 413 "$(call POST /api/announcements "$OFFICER" "{\"title\":\"Big\",\"body\":\"$(printf 'c%.0s' {1..9000})\"}")"
check "T3 invalid id in the path" 400 "$(call PATCH /api/announcements/not-a-uuid "$OFFICER" '{"version":1,"title":"x y z"}')"
check "T3 invalid view" 400 "$(call GET '/api/announcements?view=everything' "$OFFICER")"
check "T3 invalid limit" 400 "$(call GET '/api/announcements?limit=0' "$OFFICER")"
check "T3 nothing stored by the invalid requests" 1 \
  "$(call GET '/api/announcements?view=current&limit=100' "$OFFICER" >/dev/null; body | jget "j.announcements.filter(a => a.authorName === 'Test Officer').length")"

# --- T8: script text is stored and returned as plain text --------------------
XSS='<script>alert(1)</script><img src=x onerror=alert(2)>'
check "T8 script-like title accepted as text" 201 \
  "$(call POST /api/announcements "$OFFICER" "{\"title\":\"$XSS\",\"body\":\"<b>bold?</b> & \\\"quotes\\\"\"}")"
A_XSS=$(body | jget j.id)
check "T8 title stored exactly as typed" "$XSS" "$(helper get "$A_XSS" | jget j.title)"
check "T8 title returned exactly (no HTML decoding or encoding)" "$XSS" \
  "$(call GET /api/announcements "$MEMBER" >/dev/null; body | jget "j.announcements.find(a => a.id === '$A_XSS').title")"
check "T8 response is JSON, not HTML" "application/json" \
  "$(curl -s -D - -o /dev/null -m 60 -H "Authorization: Bearer $MEMBER" "$API_URL/api/announcements" | tr -d '\r' | grep -i '^content-type:' | cut -d' ' -f2 | cut -d';' -f1)"

# --- Scheduling and the views ----------------------------------------------
check "officer schedules an announcement for tomorrow" 201 \
  "$(call POST /api/announcements "$OFFICER" "{\"title\":\"Coming soon\",\"body\":\"Big news tomorrow\",\"publishAt\":\"$(iso 86400)\"}")"
A_SCHED=$(body | jget j.id)
check "it is scheduled" scheduled "$(body | jget j.state)"
check "member feed does not show scheduled items" no \
  "$(call GET /api/announcements "$MEMBER" >/dev/null; body | jget "j.announcements.some(a => a.id === '$A_SCHED') ? 'yes' : 'no'")"
check "officer sees it in the scheduled view" yes \
  "$(call GET '/api/announcements?view=scheduled' "$OFFICER" >/dev/null; body | jget "j.announcements.some(a => a.id === '$A_SCHED') ? 'yes' : 'no'")"
helper set "$A_SCHED" publishAt "\"$(iso -5)\""
check "once publishAt passes, members see it (no scheduler needed)" yes \
  "$(call GET /api/announcements "$MEMBER" >/dev/null; body | jget "j.announcements.some(a => a.id === '$A_SCHED') ? 'yes' : 'no'")"

check "officer publishes one that expires" 201 \
  "$(call POST /api/announcements "$OFFICER" "{\"title\":\"Short notice\",\"body\":\"Today only\",\"expiresAt\":\"$(iso 3600)\"}")"
A_EXP=$(body | jget j.id)
helper set "$A_EXP" expiresAt "\"$(iso -5)\""
check "expired announcement leaves the member feed" no \
  "$(call GET /api/announcements "$MEMBER" >/dev/null; body | jget "j.announcements.some(a => a.id === '$A_EXP') ? 'yes' : 'no'")"
check "officer sees it in the expired view" expired \
  "$(call GET '/api/announcements?view=expired' "$OFFICER" >/dev/null; body | jget "j.announcements.find(a => a.id === '$A_EXP')?.state")"

cleanup_test_data >/dev/null
finish
