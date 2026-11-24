#!/usr/bin/env bash
# Checks the deployed Announcements service on Floci (evidence for the report).
#   bash infra/check.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh
[ -f infra/out/api.env ] || { echo "Run bash infra/deploy.sh first." >&2; exit 2; }
source infra/out/api.env
source tests/lib.sh

status() { curl -s -o /dev/null -w '%{http_code}' -m 60 "$@"; }
header() { curl -s -D - -o /dev/null -m 60 "${@:2}" | tr -d '\r' | grep -i "^$1:" | cut -d' ' -f2; }

echo "== Announcements service on Floci: $API_URL"

check "function state" "Active" \
  "$("$AWS" lambda get-function --function-name "$FUNCTION" --query Configuration.State --output text 2>&1)"
check "function runtime" "nodejs24.x" \
  "$("$AWS" lambda get-function --function-name "$FUNCTION" --query Configuration.Runtime --output text 2>&1)"
check "function role" "arn:aws:iam::$ACCOUNT:role/$ROLE" \
  "$("$AWS" lambda get-function --function-name "$FUNCTION" --query Configuration.Role --output text 2>&1)"

BODY=$(curl -s -m 60 "$API_URL/api/health")
check "GET /api/health through API Gateway" '{"service":"announcements","status":"ok","runtime":"lambda","tokenKey":"set"}' "$BODY"

check "unlisted method refused by the gateway" 404 "$(status -X DELETE "$API_URL/api/announcements")"
check "unknown path refused by the gateway" 404 "$(status "$API_URL/api/nothing-here")"
check "gateway refusal body" '{"message":"Not Found"}' "$(curl -s -m 60 "$API_URL/api/nothing-here")"

ALLOWED="${CORS_ORIGINS%%,*}"
check "CORS: allowed origin gets its own origin back" "$ALLOWED" \
  "$(header access-control-allow-origin -H "Origin: $ALLOWED" "$API_URL/api/health")"
check "CORS: other origin gets no header" "" \
  "$(header access-control-allow-origin -H "Origin: https://evil.example" "$API_URL/api/health")"
METHODS=$(header access-control-allow-methods -X OPTIONS -H "Origin: $ALLOWED" -H 'Access-Control-Request-Method: PATCH' \
  -H 'Access-Control-Request-Headers: authorization,content-type' "$API_URL/api/announcements/00000000-0000-4000-8000-000000000000")
check "CORS preflight from the site allows PATCH" "yes" "$(case "$METHODS" in *PATCH*) echo yes ;; *) echo no ;; esac)"

check "no private key in the function configuration" 0 \
  "$("$AWS" lambda get-function-configuration --function-name "$FUNCTION" --output json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s).Environment.Variables;const k=Buffer.from(v.JWT_PUBLIC_KEY_B64,"base64").toString();console.log((JSON.stringify(v)+k).match(/PRIVATE/g)?.length||0)})')"

sleep 2
LOGLINE=$("$AWS" logs tail "$LOG_GROUP" --since 10m --format short 2>/dev/null | grep -c "GET /api/health 200" || true)
check "CloudWatch Logs has request lines" yes "$([ "${LOGLINE:-0}" -gt 0 ] && echo yes || echo no)"
check "log lines never contain a query string" 0 \
  "$("$AWS" logs tail "$LOG_GROUP" --since 10m --format short 2>/dev/null | grep -c '/api/[^ ]*?' || true)"

finish
