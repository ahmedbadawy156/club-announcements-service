#!/usr/bin/env bash
# Automatic announcements from the Events service:
#   EventBridge bus -> rule -> SQS queue (+ DLQ) -> worker Lambda -> Announcements
#   bash tests/from-events.sh        (after bash infra/deploy.sh)
# Messages are put on the bus with the local admin keys, exactly as the
# Events service sends them. The last part goes through the real Events API
# when ../club-events-service is deployed. About 2 minutes (the DLQ part
# waits for 3 failed tries).
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
source infra/out/api.env
source tests/lib.sh

echo "== Automatic announcements from Events ($API_URL)"
cleanup_test_data >/dev/null

QUEUE_URL=$("$AWS" sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text)
DLQ_URL=$("$AWS" sqs get-queue-url --queue-name "$DLQ" --query QueueUrl --output text)
QUEUE_ARN="arn:aws:sqs:$REGION:$ACCOUNT:$QUEUE"
attr() { "$AWS" sqs get-queue-attributes --queue-url "$1" --attribute-names All --output json | jget "j.Attributes.$2"; }

# --- the wiring ------------------------------------------------------------------
check "rule listens for EventPublished and EventCancelled from club.events" \
  '{"source":["club.events"],"detail-type":["EventPublished","EventCancelled"]}' \
  "$("$AWS" events describe-rule --name "$RULE" --event-bus-name "$BUS" --query EventPattern --output text | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(JSON.parse(s))))')"
check "rule target is the inbox queue" "$QUEUE_ARN" \
  "$("$AWS" events list-targets-by-rule --rule "$RULE" --event-bus-name "$BUS" --query 'Targets[0].Arn' --output text)"
check "inbox: failed 3 times -> dead-letter queue" "arn:aws:sqs:$REGION:$ACCOUNT:$DLQ|3" \
  "$(attr "$QUEUE_URL" RedrivePolicy | jget 'j.deadLetterTargetArn+"|"+j.maxReceiveCount')"
check "inbox: visibility timeout longer than the worker's timeout" yes \
  "$([ "$(attr "$QUEUE_URL" VisibilityTimeout)" -gt "$("$AWS" lambda get-function-configuration --function-name "$WORKER" --query Timeout --output text)" ] && echo yes || echo no)"
check "inbox policy: only the club bus rule may send" \
  "events.amazonaws.com|sqs:SendMessage|arn:aws:events:$REGION:$ACCOUNT:rule/$BUS/$RULE" \
  "$(attr "$QUEUE_URL" Policy | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const p=JSON.parse(s).Statement[0];process.stdout.write(p.Principal.Service+"|"+p.Action+"|"+p.Condition.ArnEquals["aws:SourceArn"])})')"
check "DLQ keeps messages 14 days" 1209600 "$(attr "$DLQ_URL" MessageRetentionPeriod)"
MAP=$("$AWS" lambda list-event-source-mappings --function-name "$WORKER" --event-source-arn "$QUEUE_ARN" --output json)
check "queue -> worker mapping enabled, batches of 10, failures reported one by one" "Enabled|10|ReportBatchItemFailures" \
  "$(printf '%s' "$MAP" | jget '(m=>m.State+"|"+m.BatchSize+"|"+(m.FunctionResponseTypes||[]).join())(j.EventSourceMappings[0])')"
check "worker runs under its own role, not the API's" "arn:aws:iam::$ACCOUNT:role/$WORKER_ROLE" \
  "$("$AWS" lambda get-function-configuration --function-name "$WORKER" --query Role --output text)"

# --- helpers -----------------------------------------------------------------------
MEMBER=$(helper token "$MEMBER_ID" member)
OFFICER=$(helper token "$OFFICER_ID" officer)
uuid() { node -e 'process.stdout.write(require("crypto").randomUUID())'; }
# bus KIND EVENTID TITLE STARTS_IN_SECONDS [SOURCE]: put a message on the bus as Events would
bus() {
  node -e '
const [kind, eventId, title, secs, source, by] = process.argv.slice(1);
const detail = { eventId, title, startsAt: new Date(Date.now() + Number(secs) * 1000).toISOString(), location: "Hall A", by };
if (kind === "EventCancelled") detail.memberIds = [];
require("fs").writeFileSync("infra/out/tmp/bus-entry.json", JSON.stringify([{
  EventBusName: "campus-club-bus", Source: source, DetailType: kind, Detail: JSON.stringify(detail) }]));' \
    -- "$1" "$2" "$3" "$4" "${5:-club.events}" "$OFFICER_ID"
  "$AWS" events put-events --entries file://infra/out/tmp/bus-entry.json --query FailedEntryCount --output text
}
# Announcements of an event, as "title/status" sorted, read straight from the table.
posts_of() { "$AWS" dynamodb scan --table-name Announcements --output json | \
  jget "j.Items.filter(a=>a.eventId?.S==='$1').map(a=>a.title.S+'/'+a.status.S).sort().join(';')"; }
# wait_for EVENTID EXPECTED [SECONDS]: poll until posts_of matches (or time is up)
wait_for() {
  local i got
  for i in $(seq 1 "${3:-15}"); do got=$(posts_of "$1"); [ "$got" = "$2" ] && break; sleep 1; done
  printf '%s' "$got"
}
settle() { sleep "${1:-6}"; } # give the worker time to (not) act

# --- EventPublished -> "New event" -------------------------------------------------
E1=$(uuid)
check "put EventPublished on the bus" 0 "$(bus EventPublished "$E1" "Robotics night" 172800)"
check "worker posts 'New event'" "New event: Robotics night/published" "$(wait_for "$E1" "New event: Robotics night/published")"
call GET /api/announcements "$MEMBER" >/dev/null
POST=$(body | jget "JSON.stringify(j.announcements.find(a=>a.eventId==='$E1')||null)")
check "  members see it in the feed" yes "$([ "$POST" != "null" ] && echo yes || echo no)"
check "  marked as automatic, linked to the event" "events|$E1|Club Events (automatic)" \
  "$(printf '%s' "$POST" | jget 'j.origin+"|"+j.eventId+"|"+j.authorName')"
check "  expires when the event starts" yes \
  "$(printf '%s' "$POST" | jget 'Math.abs(Date.parse(j.expiresAt)-(Date.now()+172800e3))<120e3?"yes":"no"')"
check "  body gives time and place" yes "$(printf '%s' "$POST" | jget '/UTC at Hall A\./.test(j.body)?"yes":"no"')"
check "  not pinned" false "$(printf '%s' "$POST" | jget j.pinned)"
check "  the author is the officer who published" "$OFFICER_ID" \
  "$("$AWS" dynamodb scan --table-name Announcements --output json | jget "j.Items.find(a=>a.eventId?.S==='$E1').authorId.S")"

# SQS can deliver a message twice: same message again -> still one post.
bus EventPublished "$E1" "Robotics night" 172800 >/dev/null
bus EventPublished "$E1" "Robotics night" 172800 >/dev/null
settle
check "the same message twice more: still exactly one post" "New event: Robotics night/published" "$(posts_of "$E1")"

# --- EventCancelled -> "Cancelled", and the "New event" post is archived -------------
PINS_BEFORE=$(helper pins)
call GET /api/announcements "$OFFICER" >/dev/null # officers see the version
ID1=$(body | jget "j.announcements.find(a=>a.eventId==='$E1').id")
V1=$(body | jget "j.announcements.find(a=>a.eventId==='$E1').version")
check "an officer pins the automatic post" 200 "$(call PATCH "/api/announcements/$ID1" "$OFFICER" "{\"version\":$V1,\"pinned\":true}")"
check "put EventCancelled on the bus" 0 "$(bus EventCancelled "$E1" "Robotics night" 172800)"
check "worker posts 'Cancelled' and archives 'New event'" "Cancelled: Robotics night/published;New event: Robotics night/archived" \
  "$(wait_for "$E1" "Cancelled: Robotics night/published;New event: Robotics night/archived")"
check "  the pin counter is given back" "$PINS_BEFORE" "$(helper pins)"
call GET /api/announcements "$MEMBER" >/dev/null
check "  the feed shows only the cancellation" "Cancelled: Robotics night" \
  "$(body | jget "j.announcements.filter(a=>a.eventId==='$E1').map(a=>a.title).join(';')")"
bus EventCancelled "$E1" "Robotics night" 172800 >/dev/null
settle
check "  a repeated cancellation changes nothing" "Cancelled: Robotics night/published;New event: Robotics night/archived" "$(posts_of "$E1")"

# --- out of order: the cancellation arrives before the publication --------------------
E2=$(uuid)
bus EventCancelled "$E2" "Chess club" 86400 >/dev/null
check "cancellation first: 'Cancelled' posted" "Cancelled: Chess club/published" "$(wait_for "$E2" "Cancelled: Chess club/published")"
bus EventPublished "$E2" "Chess club" 86400 >/dev/null
settle
check "the late 'published' message posts nothing" "Cancelled: Chess club/published" "$(posts_of "$E2")"

# --- messages that must not become posts -----------------------------------------------
E3=$(uuid); bus EventPublished "$E3" "Already started" -60 >/dev/null
E4=$(uuid); bus SeatPromoted "$E4" "Seat message" 86400 >/dev/null
E5=$(uuid); bus EventPublished "$E5" "Fake source" 86400 club.fake >/dev/null
settle
check "an event that already started: no post" "" "$(posts_of "$E3")"
check "SeatPromoted is not for Announcements (the rule filters it)" "" "$(posts_of "$E4")"
check "the right kind from another source: rule does not match" "" "$(posts_of "$E5")"

# --- bad messages end in the dead-letter queue ------------------------------------------
# Sent straight to the inbox with the admin keys (only the rule could in real
# life): wrong source, invalid detail, not JSON.
"$AWS" sqs purge-queue --queue-url "$DLQ_URL" >/dev/null 2>&1; sleep 1
E6=$(uuid)
send_raw() { "$AWS" sqs send-message --queue-url "$QUEUE_URL" --message-body "$1" --query MessageId --output text; }
B1=$(send_raw "{\"source\":\"club.evil\",\"detail-type\":\"EventPublished\",\"detail\":{\"eventId\":\"$E6\",\"title\":\"Evil\",\"location\":\"x\",\"startsAt\":\"$(iso 86400)\",\"by\":\"$OFFICER_ID\"}}")
B2=$(send_raw "{\"source\":\"club.events\",\"detail-type\":\"EventPublished\",\"detail\":{\"eventId\":\"not-a-uuid\",\"title\":\"\"}}")
B3=$(send_raw "this is not json")
dlq_count() { attr "$DLQ_URL" ApproximateNumberOfMessages; }
for i in $(seq 1 45); do [ "$(dlq_count)" = "3" ] && break; sleep 3; done
check "3 bad messages -> dead-letter queue after 3 tries each" 3 "$(dlq_count)"
check "  and they left the inbox" 0 "$(attr "$QUEUE_URL" ApproximateNumberOfMessages)"
check "  nothing was posted for them" "" "$(posts_of "$E6")"
sleep 2
FAILS=$("$AWS" logs tail "$WORKER_LOG_GROUP" --since 10m --format short 2>/dev/null)
check "  worker logged each failure with its message id" yes \
  "$(for b in "$B1" "$B2" "$B3"; do printf '%s' "$FAILS" | grep -q "\"messageId\":\"$b\"" || { echo no; exit; }; done; echo yes)"
check "  worker logs never contain message bodies" 0 "$(printf '%s' "$FAILS" | grep -c 'this is not json\|club.evil\|Robotics night' || true)"
"$AWS" sqs purge-queue --queue-url "$DLQ_URL" >/dev/null 2>&1

# --- end to end through the real Events API -----------------------------------------------
EVENTS_ENV=../club-events-service/infra/out/api.env
if [ -f "$EVENTS_ENV" ]; then
  EVENTS_URL=$(grep '^API_URL=' "$EVENTS_ENV" | cut -d= -f2 | tr -d '\r')
  ev() { curl -s -m 60 -X "$1" "$EVENTS_URL$2" -H "Authorization: Bearer $OFFICER" -H 'Content-Type: application/json' --data-binary "$3"; }
  E7=$(ev POST /api/events "{\"title\":\"End to end night\",\"startsAt\":\"$(iso 259200)\",\"location\":\"Main hall\",\"capacity\":10}" | jget j.id)
  ev PATCH "/api/events/$E7" '{"status":"published"}' >/dev/null
  check "Events API publish -> 'New event' post" "New event: End to end night/published" "$(wait_for "$E7" "New event: End to end night/published")"
  ev PATCH "/api/events/$E7" '{"status":"cancelled"}' >/dev/null
  check "Events API cancel -> 'Cancelled' post, 'New event' archived" "Cancelled: End to end night/published;New event: End to end night/archived" \
    "$(wait_for "$E7" "Cancelled: End to end night/published;New event: End to end night/archived")"
  "$AWS" dynamodb delete-item --table-name ClubEvents --key "{\"eventId\":{\"S\":\"$E7\"}}" >/dev/null
else
  echo "SKIP  end to end through Events (deploy ../club-events-service first)"
fi

cleanup_test_data >/dev/null
rm -f infra/out/tmp/bus-entry.json
finish
