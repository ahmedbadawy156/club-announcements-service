#!/usr/bin/env bash
# Announcement business rules: pin limit, pinned-first order, optimistic
# locking, archive, reschedule and expiry rules, including races between two
# officers acting at the same moment.
#   bash tests/announcement-rules.sh        (after bash infra/deploy.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
source infra/out/api.env
source tests/lib.sh

echo "== Announcement rules ($API_URL)"
cleanup_test_data >/dev/null

OFFICER=$(helper token "$OFFICER_ID" officer)
OFFICER2=$(helper token "$OFFICER2_ID" officer)
MEMBER=$(helper token "$MEMBER_ID" member)

new() { # TITLE [EXTRA_JSON]  -> prints the new id
  call POST /api/announcements "$OFFICER" "{\"title\":\"$1\",\"body\":\"Rule test\"${2:+,$2}}" >/dev/null
  body | jget j.id
}
version_of() { helper get "$1" | jget j.version; }
# Two PATCH requests at the same moment; prints the two status codes sorted.
race_patch() { # ID JSON_A TOKEN_A JSON_B TOKEN_B
  curl -s -o infra/out/tmp/race-a.json -w '%{http_code}\n' -m 60 -X PATCH -H "Authorization: Bearer $3" \
    -H 'Content-Type: application/json' --data-binary "$2" "$API_URL/api/announcements/$1" > infra/out/tmp/race-a.code &
  curl -s -o infra/out/tmp/race-b.json -w '%{http_code}\n' -m 60 -X PATCH -H "Authorization: Bearer $5" \
    -H 'Content-Type: application/json' --data-binary "$4" "$API_URL/api/announcements/$1" > infra/out/tmp/race-b.code &
  wait
  cat infra/out/tmp/race-a.code infra/out/tmp/race-b.code | codes
}

# --- Pin limit: at most 3 ---------------------------------------------------
START=$(helper pins)
check "pin counter starts at 0 (no other pinned items)" 0 "$START"
P1=$(new "Pinned one" '"pinned":true')
P2=$(new "Pinned two" '"pinned":true')
P3=$(new "Pinned three" '"pinned":true')
check "three pinned announcements accepted" 3 "$(helper pins)"
check "a fourth pinned announcement is refused" 409 \
  "$(call POST /api/announcements "$OFFICER" '{"title":"Pinned four","body":"x","pinned":true}')"
check "error code" pin_limit_reached "$(body | jget j.error)"
check "nothing stored for the refused pin" 3 \
  "$(call GET '/api/announcements?limit=100' "$OFFICER" >/dev/null; body | jget 'j.announcements.filter(a=>a.pinned).length')"
U1=$(new "Unpinned one")
check "pinning an existing one at the limit is refused" 409 \
  "$(call PATCH /api/announcements/$U1 "$OFFICER" "{\"version\":1,\"pinned\":true}")"
check "and it stays unpinned, version 1" "false 1" "$(helper get "$U1" | jget '`${j.pinned} ${j.version}`')"

# --- Pinned first ------------------------------------------------------------
sleep 1; LATEST=$(new "Newest unpinned")
call GET /api/announcements "$MEMBER" >/dev/null
check "member feed: pinned first, then newest" "true,true,true,false" \
  "$(body | jget 'j.announcements.slice(0,4).map(a=>a.pinned).join(",")')"
check "newest unpinned comes right after the pinned ones" "$LATEST" "$(body | jget 'j.announcements[3].id')"

# --- Unpin and archive free a slot -------------------------------------------
check "officer unpins one" 200 "$(call PATCH /api/announcements/$P1 "$OFFICER" "{\"version\":$(version_of "$P1"),\"pinned\":false}")"
check "counter goes down to 2" 2 "$(helper pins)"
check "the freed slot can be used" 200 "$(call PATCH /api/announcements/$U1 "$OFFICER" '{"version":1,"pinned":true}')"
check "archiving a pinned one frees its slot" 200 \
  "$(call PATCH /api/announcements/$P2 "$OFFICER" "{\"version\":$(version_of "$P2"),\"status\":\"archived\"}")"
check "archived: state and unpinned" "archived false" "$(body | jget '`${j.state} ${j.pinned}`')"
check "counter is 2 after archive" 2 "$(helper pins)"
check "archived item gone from the member feed" no \
  "$(call GET /api/announcements "$MEMBER" >/dev/null; body | jget "j.announcements.some(a=>a.id==='$P2')?'yes':'no'")"
check "officer sees it in the archived view" yes \
  "$(call GET '/api/announcements?view=archived' "$OFFICER" >/dev/null; body | jget "j.announcements.some(a=>a.id==='$P2')?'yes':'no'")"
check "archived announcement cannot be edited" 409 \
  "$(call PATCH /api/announcements/$P2 "$OFFICER" "{\"version\":$(version_of "$P2"),\"title\":\"Back again\"}")"
check "error code" announcement_archived "$(body | jget j.error)"
check "the archived record is kept, not deleted" "archived" "$(helper get "$P2" | jget j.status)"
check "archive cannot be combined with other changes" 400 \
  "$(call PATCH /api/announcements/$P3 "$OFFICER" "{\"version\":$(version_of "$P3"),\"status\":\"archived\",\"title\":\"x y z\"}")"
check "status other than archived is refused" 400 \
  "$(call PATCH /api/announcements/$P3 "$OFFICER" "{\"version\":$(version_of "$P3"),\"status\":\"published\"}")"

# --- Race: two officers take the last pin slot at the same moment -------------
R1=$(new "Race pin A"); R2=$(new "Race pin B")
check "one pin slot left before the race" 2 "$(helper pins)"
OUT=$(curl -s -o /dev/null -w '%{http_code}\n' -m 60 -X PATCH -H "Authorization: Bearer $OFFICER" -H 'Content-Type: application/json' \
        --data-binary '{"version":1,"pinned":true}' "$API_URL/api/announcements/$R1" &
      curl -s -o /dev/null -w '%{http_code}\n' -m 60 -X PATCH -H "Authorization: Bearer $OFFICER2" -H 'Content-Type: application/json' \
        --data-binary '{"version":1,"pinned":true}' "$API_URL/api/announcements/$R2" &
      wait)
check "race for the last slot: one 200, one 409" "200 409" "$(echo "$OUT" | codes)"
check "counter never passes 3" 3 "$(helper pins)"
check "exactly 3 pinned in the feed" 3 \
  "$(call GET '/api/announcements?limit=100' "$OFFICER" >/dev/null; body | jget 'j.announcements.filter(a=>a.pinned).length')"

# --- Optimistic locking ---------------------------------------------------------
E=$(new "Edit me")
check "edit with the current version" 200 "$(call PATCH /api/announcements/$E "$OFFICER" '{"version":1,"title":"Edited once"}')"
check "version goes up to 2" 2 "$(body | jget j.version)"
check "edit with a stale version is refused" 409 "$(call PATCH /api/announcements/$E "$OFFICER2" '{"version":1,"title":"Stale edit"}')"
check "error code" version_conflict "$(body | jget j.error)"
check "the newer edit was kept" "Edited once" "$(helper get "$E" | jget j.title)"
check "updatedBy recorded from the token" "$OFFICER_ID" "$(helper get "$E" | jget j.updatedBy)"
check "two officers edit the same version at once: one wins" "200 409" \
  "$(race_patch "$E" '{"version":2,"title":"Officer A wins"}' "$OFFICER" '{"version":2,"title":"Officer B wins"}' "$OFFICER2")"
check "version is 3 after the race (only one write)" 3 "$(version_of "$E")"
check "PATCH with no changes" 400 "$(call PATCH /api/announcements/$E "$OFFICER" '{"version":3}')"
check "PATCH without a version" 400 "$(call PATCH /api/announcements/$E "$OFFICER" '{"title":"No version"}')"
check "unknown announcement" 404 "$(call PATCH /api/announcements/00000000-0000-4000-8000-000000000000 "$OFFICER" '{"version":1,"title":"Ghost"}')"

# --- Reschedule and expiry rules -------------------------------------------------
S=$(new "Scheduled" "\"publishAt\":\"$(iso 7200)\"")
check "a scheduled one can be moved" 200 "$(call PATCH /api/announcements/$S "$OFFICER" "{\"version\":1,\"publishAt\":\"$(iso 10800)\"}")"
check "cannot move it into the past" 400 "$(call PATCH /api/announcements/$S "$OFFICER" "{\"version\":2,\"publishAt\":\"$(iso -3600)\"}")"
check "cannot expire before it is published" 400 "$(call PATCH /api/announcements/$S "$OFFICER" "{\"version\":2,\"expiresAt\":\"$(iso 3600)\"}")"
check "can set an expiry after publishAt" 200 "$(call PATCH /api/announcements/$S "$OFFICER" "{\"version\":2,\"expiresAt\":\"$(iso 20000)\"}")"
check "can clear the expiry with null" 200 "$(call PATCH /api/announcements/$S "$OFFICER" '{"version":3,"expiresAt":null}')"
check "expiry removed" "null" "$(body | jget 'String(j.expiresAt)')"
check "a published one cannot be rescheduled" 409 "$(call PATCH /api/announcements/$E "$OFFICER" "{\"version\":3,\"publishAt\":\"$(iso 3600)\"}")"
check "error code" already_published "$(body | jget j.error)"
X=$(new "Will expire" "\"expiresAt\":\"$(iso 3600)\"")
helper set "$X" expiresAt "\"$(iso -5)\""
check "an expired announcement cannot be pinned" 409 "$(call PATCH /api/announcements/$X "$OFFICER" '{"version":1,"pinned":true}')"
check "error code" announcement_expired "$(body | jget j.error)"
check "an expired one can get a new expiry (brought back)" 200 "$(call PATCH /api/announcements/$X "$OFFICER" "{\"version\":1,\"expiresAt\":\"$(iso 3600)\"}")"
check "and is current again" current "$(body | jget j.state)"

cleanup_test_data >/dev/null
check "cleanup recounts the pins" 0 "$(helper pins)"
finish
