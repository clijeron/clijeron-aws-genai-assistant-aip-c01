#!/usr/bin/env bash
#
# Part 3 / Failover — Step 1: add GET /health (MOCK 200) to the us-west-2 API
# ===========================================================================
# Route 53 health checks need a cheap, body-less endpoint that returns 200.
# We add GET /health as a MOCK integration (no Lambda) to the Part 2 us-west-2
# REST API and redeploy the prod stage.
#
# us-east-1 gets /health from the updated template.yaml — re-run
# deploy_crossregion.sh (the template now includes a HealthMethod + a bumped
# deployment logical id so the stage actually refreshes).
#
set -euo pipefail

REGION="us-west-2"
API_ID="mtipvxmr4k"          # Part 2 us-west-2 REST API id
STAGE="prod"

ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
  --query "items[?path=='/'].id" --output text)
[ -n "$ROOT_ID" ] && [ "$ROOT_ID" != "None" ] || { echo "ERROR: root resource not found for API $API_ID"; exit 1; }

# Idempotency: reuse /health if it already exists.
HEALTH_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --region "$REGION" \
  --query "items[?path=='/health'].id" --output text)
if [ -z "$HEALTH_ID" ] || [ "$HEALTH_ID" = "None" ]; then
  HEALTH_ID=$(aws apigateway create-resource --rest-api-id "$API_ID" \
    --parent-id "$ROOT_ID" --path-part health --region "$REGION" --query id --output text)
  echo "created /health resource: $HEALTH_ID"
else
  echo "/health already exists: $HEALTH_ID"
fi

aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$HEALTH_ID" \
  --http-method GET --authorization-type NONE --region "$REGION" >/dev/null 2>&1 || true
aws apigateway put-method-response --rest-api-id "$API_ID" --resource-id "$HEALTH_ID" \
  --http-method GET --status-code 200 --region "$REGION" >/dev/null 2>&1 || true
aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$HEALTH_ID" \
  --http-method GET --type MOCK \
  --request-templates '{"application/json":"{\"statusCode\": 200}"}' \
  --region "$REGION" >/dev/null
aws apigateway put-integration-response --rest-api-id "$API_ID" --resource-id "$HEALTH_ID" \
  --http-method GET --status-code 200 \
  --response-templates '{"application/json":"{\"status\":\"ok\"}"}' \
  --region "$REGION" >/dev/null

aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE" \
  --region "$REGION" >/dev/null
echo "Redeployed $STAGE. Test:"
echo "  curl -s https://$API_ID.execute-api.$REGION.amazonaws.com/$STAGE/health"
echo
echo "NOW re-run ../deploy_crossregion.sh to add /health to us-east-1 (template updated)."
