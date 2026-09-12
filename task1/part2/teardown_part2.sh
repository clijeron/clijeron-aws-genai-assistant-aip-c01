#!/usr/bin/env bash
#
# Part 2 — Teardown
# =================
# Deletes everything deploy_part2.sh created, using the IDs saved in
# part2_resources.env. Safe to re-run; missing resources are ignored.
#
set -uo pipefail

if [ ! -f part2_resources.env ]; then
  echo "part2_resources.env not found — nothing to tear down (or run from part2/)."
  exit 1
fi
# shellcheck disable=SC1091
source part2_resources.env

echo "Tearing down Part 2 in $REGION ..."

# API Gateway
aws apigateway delete-rest-api --rest-api-id "$API_ID" --region "$REGION" \
  && echo "deleted API $API_ID" || echo "API already gone"

# Lambda
aws lambda delete-function --function-name "$FUNC_NAME" --region "$REGION" \
  && echo "deleted Lambda $FUNC_NAME" || echo "Lambda already gone"

# AppConfig: profile hosted versions -> profile -> environment -> application
for V in $(aws appconfig list-hosted-configuration-versions --application-id "$APP_ID" \
    --configuration-profile-id "$PROFILE_ID" --region "$REGION" \
    --query 'Items[].VersionNumber' --output text 2>/dev/null); do
  aws appconfig delete-hosted-configuration-version --application-id "$APP_ID" \
    --configuration-profile-id "$PROFILE_ID" --version-number "$V" --region "$REGION" || true
done
aws appconfig delete-configuration-profile --application-id "$APP_ID" \
  --configuration-profile-id "$PROFILE_ID" --region "$REGION" || true
aws appconfig delete-environment --application-id "$APP_ID" \
  --environment-id "$ENV_ID" --region "$REGION" || true
aws appconfig delete-application --application-id "$APP_ID" --region "$REGION" \
  && echo "deleted AppConfig app $APP_ID" || echo "AppConfig app already gone"

# IAM role: detach managed, delete inline, delete role
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole || true
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name bedrock-appconfig || true
aws iam delete-role --role-name "$ROLE_NAME" \
  && echo "deleted role $ROLE_NAME" || echo "role already gone"

echo "Part 2 teardown complete."
