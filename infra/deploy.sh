#!/usr/bin/env bash
# Deploy the Announcements service to Floci. Safe to run again: it creates
# what is missing and updates what exists.
#   bash infra/deploy.sh
# Needs the Membership service deployed on the same Floci first, because
# this service verifies Membership's tokens with its PUBLIC key.
# Steps: tables -> token public key -> IAM role + policy -> zip -> Lambda ->
# API Gateway (routes, stage, permission) -> saves the address to infra/out/api.env
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.sh

step() { echo "== $*"; }

"$AWS" sts get-caller-identity --query Account --output text >/dev/null 2>&1 || {
  echo "Floci is not reachable. Start it: docker compose -f infra/floci/docker-compose.yml up -d" >&2
  exit 1
}
mkdir -p infra/out

step "1/6 DynamoDB tables"
for def in infra/dynamodb/*.json; do
  table=$(basename "$def" .json)
  if ! "$AWS" dynamodb describe-table --table-name "$table" >/dev/null 2>&1; then
    "$AWS" dynamodb create-table --cli-input-json "file://$def" >/dev/null
    "$AWS" dynamodb wait table-exists --table-name "$table"
    echo "   + table $table"
  fi
done

step "2/6 Membership's token public key"
# The public key is not a secret. It is fetched from Membership's public
# endpoint at deploy time and given to the function as an environment
# variable, because a Lambda function on Floci cannot reach
# *.localhost.floci.io at run time. The Host header form works offline.
MEMBERSHIP_ENV="$MEMBERSHIP_DIR/infra/out/api.env"
[ -f "$MEMBERSHIP_ENV" ] || {
  echo "Not found: $MEMBERSHIP_ENV. Deploy club-membership-service first (bash infra/deploy.sh there)." >&2
  exit 1
}
MEMBERSHIP_API_ID=$(grep '^API_ID=' "$MEMBERSHIP_ENV" | cut -d= -f2 | tr -d '\r')
curl -s -m 60 -H "Host: $MEMBERSHIP_API_ID.execute-api.localhost.floci.io:4566" \
  http://localhost:4566/api/auth/public-key > infra/out/public-key.json
node -e '
const fs = require("fs");
const j = JSON.parse(fs.readFileSync("infra/out/public-key.json", "utf8"));
if (j.algorithm !== "RS256" || !/^-----BEGIN PUBLIC KEY-----/.test(j.publicKey || "")) {
  console.error("Membership did not return an RS256 public key."); process.exit(1);
}
if (/PRIVATE/.test(JSON.stringify(j))) { console.error("Refusing: response contains a private key."); process.exit(1); }
fs.writeFileSync("infra/out/public-key.b64", Buffer.from(j.publicKey).toString("base64"));
const fp = require("crypto").createHash("sha256").update(j.publicKey).digest("hex").slice(0, 16);
console.log("   public key fingerprint (sha256, first 16): " + fp);'

step "3/6 IAM role $ROLE and its policy"
if ! "$AWS" iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  "$AWS" iam create-role --role-name "$ROLE" \
    --assume-role-policy-document file://infra/iam/trust-policy.json >/dev/null
fi
"$AWS" iam put-role-policy --role-name "$ROLE" --policy-name "$ROLE_POLICY" \
  --policy-document file://infra/iam/announcements-policy.json

step "4/6 Install and zip the backend"
(cd backend && npm install --omit=dev --no-audit --no-fund --loglevel=error && npm run zip --silent)

step "5/6 Lambda function $FUNCTION"
# Environment as a JSON file: the base64 key contains "=" and "/", which the
# CLI shorthand syntax cannot carry.
CORS_ORIGINS="$CORS_ORIGINS" node -e '
const fs = require("fs");
fs.writeFileSync("infra/out/lambda-env.json", JSON.stringify({ Variables: {
  NODE_ENV: "production",
  CORS_ORIGINS: process.env.CORS_ORIGINS,
  ANNOUNCEMENTS_TABLE: "Announcements",
  ACTIVITIES_TABLE: "Activities",
  JWT_PUBLIC_KEY_B64: fs.readFileSync("infra/out/public-key.b64", "utf8").trim(),
} }));'
if "$AWS" lambda get-function --function-name "$FUNCTION" >/dev/null 2>&1; then
  "$AWS" lambda update-function-code --function-name "$FUNCTION" \
    --zip-file fileb://backend/lambda.zip >/dev/null
  "$AWS" lambda wait function-updated-v2 --function-name "$FUNCTION"
  "$AWS" lambda update-function-configuration --function-name "$FUNCTION" \
    --timeout 15 --memory-size 256 --environment file://infra/out/lambda-env.json >/dev/null
  "$AWS" lambda wait function-updated-v2 --function-name "$FUNCTION"
else
  "$AWS" lambda create-function --function-name "$FUNCTION" \
    --runtime nodejs24.x --handler lambda.handler \
    --role "arn:aws:iam::$ACCOUNT:role/$ROLE" \
    --zip-file fileb://backend/lambda.zip --timeout 15 --memory-size 256 \
    --environment file://infra/out/lambda-env.json >/dev/null
  "$AWS" lambda wait function-active-v2 --function-name "$FUNCTION"
fi

step "6/6 API Gateway $API_NAME"
API_ID=$("$AWS" apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  API_ID=$("$AWS" apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP --query ApiId --output text)
fi
FUNCTION_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:$FUNCTION"
INTEGRATION_ID=$("$AWS" apigatewayv2 get-integrations --api-id "$API_ID" \
  --query "Items[?IntegrationUri=='$FUNCTION_ARN'].IntegrationId | [0]" --output text)
if [ -z "$INTEGRATION_ID" ] || [ "$INTEGRATION_ID" = "None" ]; then
  INTEGRATION_ID=$("$AWS" apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type AWS_PROXY --payload-format-version 2.0 \
    --integration-uri "$FUNCTION_ARN" --query IntegrationId --output text)
fi

# Routes: make the gateway match infra/routes.txt exactly.
WANTED=$(grep -v '^\s*#' infra/routes.txt | sed 's/\r$//' | grep -v '^\s*$' || true)
EXISTING=$("$AWS" apigatewayv2 get-routes --api-id "$API_ID" \
  --query 'Items[].[RouteKey,RouteId]' --output text | sed 's/\r$//')
while IFS= read -r key; do
  [ -z "$key" ] && continue
  if ! printf '%s\n' "$EXISTING" | cut -f1 | grep -qxF "$key"; then
    "$AWS" apigatewayv2 create-route --api-id "$API_ID" --route-key "$key" \
      --target "integrations/$INTEGRATION_ID" >/dev/null
    echo "   + route $key"
  fi
done <<< "$WANTED"
while IFS=$'\t' read -r key id; do
  [ -z "$key" ] && continue
  if ! printf '%s\n' "$WANTED" | grep -qxF "$key"; then
    "$AWS" apigatewayv2 delete-route --api-id "$API_ID" --route-id "$id"
    echo "   - route $key (no longer listed)"
  fi
done <<< "$EXISTING"

if [ "$("$AWS" apigatewayv2 get-stages --api-id "$API_ID" --query "Items[?StageName=='\$default'] | length(@)" --output text)" = "0" ]; then
  "$AWS" apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy >/dev/null
fi

# Allow only this API to invoke the function.
"$AWS" lambda add-permission --function-name "$FUNCTION" --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API_ID/*" >/dev/null 2>&1 || true

API_URL=$(api_url "$API_ID")
printf 'API_ID=%s\nAPI_URL=%s\n' "$API_ID" "$API_URL" > infra/out/api.env
echo
echo "Deployed. API: $API_URL"
echo "Try:      curl $API_URL/api/health"
