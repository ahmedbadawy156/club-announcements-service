#!/usr/bin/env bash
# Past club activities: roles, validation, one activity per finished event
# (also under a race), paging and plain-text storage.
#   bash tests/activities.sh        (after bash infra/deploy.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
source infra/out/api.env
source tests/lib.sh

echo "== Activities ($API_URL)"
cleanup_test_data >/dev/null

OFFICER=$(helper token "$OFFICER_ID" officer)
OFFICER2=$(helper token "$OFFICER2_ID" officer)
MEMBER=$(helper token "$MEMBER_ID" member)
uuid() { node -e 'process.stdout.write(require("crypto").randomUUID())'; }
activity() { # EVENT_ID DATE [TITLE] [SUMMARY]
  printf '{"eventId":"%s","eventTitle":"%s","eventDate":"%s","summary":"%s"}' "$1" "${3:-Club hike}" "$2" "${4:-Twelve members walked the coastal trail.}"
}

# --- Access -----------------------------------------------------------------
check "T1 list without a token" 401 "$(call GET /api/activities -)"
check "T1 record without a token" 401 "$(call POST /api/activities - "$(activity "$(uuid)" "$(day -1)")")"
T=$(helper token "$OFFICER_ID" officer expired)
check "T6 expired officer token cannot record" 401 "$(call POST /api/activities "$T" "$(activity "$(uuid)" "$(day -1)")")"
T=$(helper token "$MEMBER_ID" member tampered)
check "T6 member token edited to officer cannot record" 401 "$(call POST /api/activities "$T" "$(activity "$(uuid)" "$(day -1)")")"
check "T2 member cannot record an activity" 403 "$(call POST /api/activities "$MEMBER" "$(activity "$(uuid)" "$(day -1)")")"
check "T2 nothing stored by the member" 0 "$(call GET /api/activities "$OFFICER" >/dev/null; body | jget 'j.activities.length')"

# --- Record and read ----------------------------------------------------------
E1=$(uuid)
check "officer records an activity for yesterday's event" 201 "$(call POST /api/activities "$OFFICER" "$(activity "$E1" "$(day -1)")")"
ACT1=$(body | jget j.id)
check "recorded by the name in the token" "Test Officer" "$(body | jget j.recordedByName)"
check "internal fields are not returned" "" "$(body | jget 'j.recordedBy ?? j.feed ?? j.sortKey')"
check "member can browse activities" 200 "$(call GET /api/activities "$MEMBER")"
check "member sees it" "$E1" "$(body | jget "j.activities.find(a=>a.id==='$ACT1')?.eventId")"
check "an activity for today's event is allowed" 201 "$(call POST /api/activities "$OFFICER" "$(activity "$(uuid)" "$(day 0)")")"

# --- One activity per event -----------------------------------------------------
check "a second activity for the same event is refused" 409 \
  "$(call POST /api/activities "$OFFICER2" "$(activity "$E1" "$(day -1)" "Same hike again")")"
check "error code" activity_exists "$(body | jget j.error)"
UPPER=$(echo "$E1" | tr 'a-f' 'A-F')
check "same event id in capitals is the same event" 409 "$(call POST /api/activities "$OFFICER" "$(activity "$UPPER" "$(day -1)")")"
E2=$(uuid)
OUT=$(for t in "$OFFICER" "$OFFICER2" "$OFFICER" "$OFFICER2"; do
  curl -s -o /dev/null -w '%{http_code}\n' -m 60 -X POST -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
    --data-binary "$(activity "$E2" "$(day -2)")" "$API_URL/api/activities" &
done; wait)
check "4 officers record the same event at once: one 201" "201 409 409 409" "$(echo "$OUT" | codes)"
check "only one activity stored for that event" 1 \
  "$(call GET '/api/activities?limit=100' "$MEMBER" >/dev/null; body | jget "j.activities.filter(a=>a.eventId==='$E2').length")"

# --- T3: invalid input -------------------------------------------------------------
v400() { # NAME JSON FIELD
  local code; code=$(call POST /api/activities "$OFFICER" "$2")
  check "T3 $1" "400 $3" "$code $(body | jget 'j.fields && j.fields.join(",")')"
}
v400 "event in the future (not finished)" "$(activity "$(uuid)" "$(day 3)")" eventDate
v400 "date that does not exist" "$(activity "$(uuid)" "2026-02-30")" eventDate
v400 "date in the wrong format" "$(activity "$(uuid)" "24/11/2026")" eventDate
v400 "event more than 10 years ago" "$(activity "$(uuid)" "2001-01-01")" eventDate
v400 "event id not a UUID" "$(activity "event-1" "$(day -1)")" eventId
v400 "event title too short" "$(activity "$(uuid)" "$(day -1)" "ab")" eventTitle
v400 "summary too short" "$(activity "$(uuid)" "$(day -1)" "Club hike" "Fun")" summary
v400 "event id as an object" "{\"eventId\":{\"S\":\"x\"},\"eventTitle\":\"Hike\",\"eventDate\":\"$(day -1)\",\"summary\":\"Twelve members came along.\"}" eventId
v400 "unknown field" "{\"eventId\":\"$(uuid)\",\"eventTitle\":\"Hike\",\"eventDate\":\"$(day -1)\",\"summary\":\"Twelve members came along.\",\"recordedBy\":\"x\"}" recordedBy
check "T3 malformed JSON" 400 "$(call POST /api/activities "$OFFICER" '{"eventId":')"
check "T3 invalid limit" 400 "$(call GET '/api/activities?limit=500' "$MEMBER")"
check "T3 invalid cursor" 400 "$(call GET '/api/activities?before=nope' "$MEMBER")"
check "T3 unknown cursor id" 400 "$(call GET "/api/activities?before=$(uuid)" "$MEMBER")"

# --- T8: script text stays text ----------------------------------------------------
XSS='<img src=x onerror=alert(1)> great night'
check "T8 script-like summary accepted as text" 201 "$(call POST /api/activities "$OFFICER" "$(activity "$(uuid)" "$(day -4)" "Quiz night" "$XSS")")"
check "T8 summary returned exactly as typed" "$XSS" "$(body | jget j.summary)"

# --- Paging: newest event first -------------------------------------------------------
for d in -30 -20 -10; do call POST /api/activities "$OFFICER" "$(activity "$(uuid)" "$(day $d)" "Paging $d")" >/dev/null; done
call GET '/api/activities?limit=2' "$MEMBER" >/dev/null
P1=$(body)
check "page 1 has 2 items" 2 "$(echo "$P1" | jget 'j.activities.length')"
check "newest event first" yes "$(echo "$P1" | jget 'j.activities[0].eventDate >= j.activities[1].eventDate ? "yes" : "no"')"
NEXT=$(echo "$P1" | jget j.nextBefore)
check "page 1 gives a cursor" yes "$([ -n "$NEXT" ] && echo yes || echo no)"
ALL=$(call GET '/api/activities?limit=100' "$MEMBER" >/dev/null; body | jget 'j.activities.length')
SEEN=2; CUR=$NEXT
while [ -n "$CUR" ]; do
  call GET "/api/activities?limit=2&before=$CUR" "$MEMBER" >/dev/null
  SEEN=$((SEEN + $(body | jget 'j.activities.length'))); CUR=$(body | jget j.nextBefore)
done
check "following the cursors visits every activity once" "$ALL" "$SEEN"
check "list is sorted by event date, newest first" yes \
  "$(call GET '/api/activities?limit=100' "$MEMBER" >/dev/null; body | jget 'j.activities.every((a,i,l)=>i===0||l[i-1].eventDate>=a.eventDate)?"yes":"no"')"
check "the one-per-event claim items never show in the list" 0 \
  "$(body | jget 'j.activities.filter(a=>!a.eventId).length')"

cleanup_test_data >/dev/null
finish
