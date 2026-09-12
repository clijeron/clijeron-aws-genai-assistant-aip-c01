#!/usr/bin/env bash
#
# Part 3 — Cross-region deploy (secondary region: us-east-1)
# ==========================================================
# Deploys the self-contained CloudFormation stack (Lambda + API Gateway) to
# us-east-1, giving a SECOND regional /generate endpoint for Route 53 failover.
# us-west-2 already has the PRIMARY endpoint from Part 2 (CLI-deployed), so we
# deploy CFN only to us-east-1 to avoid name collisions.
#
# Stack-level tag auto-delete=true propagates to all taggable resources.
# Teardown: teardown_crossregion.sh (one delete-stack).
#
set -euo pipefail

SECONDARY_REGION="us-east-1"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
STACK="ai-assistant-crossregion"
MODEL="us.amazon.nova-lite-v1:0"
ENV_OUT="crossregion_resources.env"

CALLER=$(aws sts get-caller-identity --query Account --output text)
[ "$CALLER" = "$ACCOUNT" ] || { echo "ERROR: account $CALLER != $ACCOUNT"; exit 1; }

echo "NOTE: Bedrock model access for $MODEL must be granted in $SECONDARY_REGION too"
echo "      (model-access grants are per-region). If the smoke test returns"
echo "      AccessDenied, enable it in the Bedrock console for $SECONDARY_REGION."
echo

aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name "$STACK" \
  --parameter-overrides PrimaryModel="$MODEL" StageName=prod \
  --region "$SECONDARY_REGION" \
  --capabilities CAPABILITY_IAM \
  --tags auto-delete=true

ENDPOINT=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --region "$SECONDARY_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text)
LAMBDA_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --region "$SECONDARY_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LambdaArn'].OutputValue" --output text)

cat > "$ENV_OUT" <<EOF
SECONDARY_REGION=$SECONDARY_REGION
STACK=$STACK
SECONDARY_ENDPOINT=$ENDPOINT
SECONDARY_LAMBDA_ARN=$LAMBDA_ARN
EOF

echo
echo "=== Cross-region (secondary) deployed to $SECONDARY_REGION ==="
echo "Secondary endpoint: $ENDPOINT"
echo "IDs saved to $ENV_OUT"
echo
echo "Smoke test the secondary region:"
echo "  curl -s -X POST \"$ENDPOINT\" -H 'Content-Type: application/json' \\"
echo "    -d '{\"prompt\":\"What is a 401(k)?\",\"use_case\":\"general\"}' | jq ."
echo
echo "Primary (us-west-2, from Part 2):"
echo "  https://mtipvxmr4k.execute-api.us-west-2.amazonaws.com/prod/generate"
