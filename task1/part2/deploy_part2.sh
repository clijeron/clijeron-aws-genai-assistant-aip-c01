#!/usr/bin/env bash
#
# Part 2 — Flexible Architecture for Dynamic Model Selection
# ==========================================================
# Deploys: IAM role -> model-abstraction Lambda -> AppConfig (app/env/profile/
# hosted config + deployment) -> API Gateway REST endpoint.
#
# Every resource is tagged auto-delete=true so it can be found + swept up later.
# Run teardown_part2.sh to remove everything this script creates.
#
# WHAT CHANGED vs. the assignment's raw CLI steps (see CHANGELOG.md, Part 2):
#   P2-A  Config profile type AWS.AppConfig.FeatureFlags -> AWS.Freeform
#         (the content is freeform strategy JSON, not a feature-flag document;
#          FeatureFlags enforces a schema and would reject it).
#   P2-B  Creates the IAM execution role the assignment references but never makes.
#   P2-C  Adds lambda:add-permission so API Gateway can invoke the Lambda
#         (omitted in the assignment -> endpoint would return 500).
#   P2-D  Chains IDs automatically instead of the assignment's YOUR_APP_ID
#         placeholders; writes them to part2_resources.env for teardown.
#   P2-E  Runtime python3.12 (assignment used the now-EOL python3.9).
#   P2-F  Uploads ../part1/model_selection_strategy.json (Part 1's output) as
#         the AppConfig content, chaining Part 1 -> Part 2.
#
set -euo pipefail

# ---- Config ----------------------------------------------------------------
REGION="us-west-2"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
TAG_KEY="auto-delete"
TAG_VAL="true"

APP_NAME="AIAssistantApp"
ENV_NAME="Production"
PROFILE_NAME="ModelSelectionStrategy"
FUNC_NAME="ai-assistant-model-abstraction"
API_NAME="AIAssistantAPI"
ROLE_NAME="ai-assistant-lambda-role"
STRATEGY_FILE="../part1/model_selection_strategy.json"   # Part 1 output (P2-F)

ENV_OUT="part2_resources.env"   # resource IDs saved here for teardown

# ---- Guard: correct account ------------------------------------------------
CALLER=$(aws sts get-caller-identity --query Account --output text)
if [ "$CALLER" != "$ACCOUNT" ]; then
  echo "ERROR: current account $CALLER != expected $ACCOUNT. Aborting."
  exit 1
fi
if [ ! -f "$STRATEGY_FILE" ]; then
  echo "ERROR: $STRATEGY_FILE not found. Run Part 1 (benchmark.py) first."
  exit 1
fi
echo "Account OK ($ACCOUNT), region $REGION. Deploying Part 2..."

# ---- 1. IAM execution role (P2-B) ------------------------------------------
cat > /tmp/trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON

ROLE_ARN=$(aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/trust.json \
  --tags Key=$TAG_KEY,Value=$TAG_VAL \
  --query 'Role.Arn' --output text 2>/dev/null \
  || aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

cat > /tmp/inline.json <<'JSON'
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["bedrock:InvokeModel"],"Resource":"*"},
  {"Effect":"Allow","Action":["appconfig:StartConfigurationSession","appconfig:GetLatestConfiguration"],"Resource":"*"}]}
JSON
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name bedrock-appconfig --policy-document file:///tmp/inline.json

echo "Role: $ROLE_ARN  (waiting 10s for propagation)"
sleep 10

# ---- 2. Lambda -------------------------------------------------------------
zip -j /tmp/function.zip lambda_function.py >/dev/null
aws lambda create-function --function-name "$FUNC_NAME" \
  --runtime python3.12 --role "$ROLE_ARN" \
  --handler lambda_function.lambda_handler \
  --zip-file fileb:///tmp/function.zip \
  --timeout 30 --memory-size 256 \
  --environment "Variables={APPCONFIG_APP=$APP_NAME,APPCONFIG_ENV=$ENV_NAME,APPCONFIG_PROFILE=$PROFILE_NAME}" \
  --tags $TAG_KEY=$TAG_VAL --region "$REGION" >/dev/null
LAMBDA_ARN=$(aws lambda get-function --function-name "$FUNC_NAME" \
  --query 'Configuration.FunctionArn' --output text --region "$REGION")
echo "Lambda: $LAMBDA_ARN"

# ---- 3. AppConfig (P2-A freeform) ------------------------------------------
APP_ID=$(aws appconfig create-application --name "$APP_NAME" \
  --tags $TAG_KEY=$TAG_VAL --region "$REGION" --query Id --output text)
ENV_ID=$(aws appconfig create-environment --application-id "$APP_ID" --name "$ENV_NAME" \
  --tags $TAG_KEY=$TAG_VAL --region "$REGION" --query Id --output text)
PROFILE_ID=$(aws appconfig create-configuration-profile --application-id "$APP_ID" \
  --name "$PROFILE_NAME" --location-uri hosted --type "AWS.Freeform" \
  --tags $TAG_KEY=$TAG_VAL --region "$REGION" --query Id --output text)
VERSION=$(aws appconfig create-hosted-configuration-version --application-id "$APP_ID" \
  --configuration-profile-id "$PROFILE_ID" --content-type "application/json" \
  --content fileb://"$STRATEGY_FILE" --region "$REGION" \
  --query VersionNumber --output text /tmp/hcv_content.out)
aws appconfig start-deployment --application-id "$APP_ID" --environment-id "$ENV_ID" \
  --configuration-profile-id "$PROFILE_ID" --configuration-version "$VERSION" \
  --deployment-strategy-id "AppConfig.AllAtOnce" --region "$REGION" >/dev/null
echo "AppConfig app=$APP_ID env=$ENV_ID profile=$PROFILE_ID version=$VERSION"

# ---- 4. API Gateway --------------------------------------------------------
API_ID=$(aws apigateway create-rest-api --name "$API_NAME" \
  --tags $TAG_KEY=$TAG_VAL --region "$REGION" --query id --output text)
ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" \
  --region "$REGION" --query 'items[0].id' --output text)
RES_ID=$(aws apigateway create-resource --rest-api-id "$API_ID" \
  --parent-id "$ROOT_ID" --path-part generate --region "$REGION" --query id --output text)
aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$RES_ID" \
  --http-method POST --authorization-type NONE --region "$REGION" >/dev/null
aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" \
  --http-method POST --type AWS_PROXY --integration-http-method POST \
  --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations" \
  --region "$REGION" >/dev/null

# P2-C: allow API Gateway to invoke the Lambda
aws lambda add-permission --function-name "$FUNC_NAME" \
  --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API_ID/*/POST/generate" \
  --region "$REGION" >/dev/null

aws apigateway create-deployment --rest-api-id "$API_ID" \
  --stage-name prod --region "$REGION" >/dev/null

ENDPOINT="https://$API_ID.execute-api.$REGION.amazonaws.com/prod/generate"

# ---- 5. Save IDs for teardown (P2-D) ---------------------------------------
cat > "$ENV_OUT" <<EOF
REGION=$REGION
ROLE_NAME=$ROLE_NAME
FUNC_NAME=$FUNC_NAME
APP_ID=$APP_ID
ENV_ID=$ENV_ID
PROFILE_ID=$PROFILE_ID
API_ID=$API_ID
ENDPOINT=$ENDPOINT
EOF

echo
echo "=== Part 2 deployed ==="
echo "Endpoint: $ENDPOINT"
echo "IDs saved to $ENV_OUT"
echo
echo "Test it:"
echo "  curl -s -X POST \"$ENDPOINT\" -H 'Content-Type: application/json' \\"
echo "    -d '{\"prompt\":\"What is a 401(k)?\",\"use_case\":\"general\"}' | jq ."
