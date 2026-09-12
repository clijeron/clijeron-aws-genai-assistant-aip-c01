#!/usr/bin/env bash
#
# Part 3 — Resilient System Design (core: Step Functions + fallback + degradation)
# ================================================================================
# Deploys, in us-west-2, all tagged auto-delete=true:
#   - fallback Lambda            (ai-assistant-fallback)
#   - graceful-degradation Lambda(ai-assistant-degradation)
#   - Step Functions role        (ai-assistant-sfn-role)
#   - state machine              (ai-assistant-resilient) wiring:
#         primary (Part 2 Lambda) -> fallback -> graceful degradation
#
# Assumes Part 2 already deployed the primary abstraction Lambda
# (ai-assistant-model-abstraction). Reads its ARN automatically.
#
# WHAT CHANGED vs. the assignment (see CHANGELOG Part 3):
#   P3-1 fallback model titan-text-express-v1 -> us.amazon.nova-lite-v1:0 (retired)
#   P3-7 creates the Step Functions execution role the assignment never defines
#   P3-8 substitutes real Lambda ARNs into the ASL (assignment left ${...} tokens)
#   P3-9 python3.12 runtime (assignment used EOL 3.9)
#   P3-E writes part3_resources.env for clean teardown
#
set -euo pipefail

REGION="us-west-2"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
TAG_KEY="auto-delete"; TAG_VAL="true"

PRIMARY_FUNC="ai-assistant-model-abstraction"     # from Part 2
FALLBACK_FUNC="ai-assistant-fallback"
DEGRADE_FUNC="ai-assistant-degradation"
SFN_ROLE="ai-assistant-sfn-role"
LAMBDA_ROLE="ai-assistant-lambda-role"            # reuse Part 2's role for the new Lambdas
SM_NAME="ai-assistant-resilient"
ENV_OUT="part3_resources.env"

# ---- Guards ----------------------------------------------------------------
CALLER=$(aws sts get-caller-identity --query Account --output text)
[ "$CALLER" = "$ACCOUNT" ] || { echo "ERROR: account $CALLER != $ACCOUNT"; exit 1; }

PRIMARY_ARN=$(aws lambda get-function --function-name "$PRIMARY_FUNC" \
  --region "$REGION" --query 'Configuration.FunctionArn' --output text 2>/dev/null) \
  || { echo "ERROR: Part 2 Lambda $PRIMARY_FUNC not found. Deploy Part 2 first."; exit 1; }
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE" --query 'Role.Arn' --output text)
echo "Primary Lambda: $PRIMARY_ARN"

# ---- 1. Package + create the two new Lambdas -------------------------------
zip -j /tmp/fallback.zip fallback_lambda.py >/dev/null
zip -j /tmp/degrade.zip degradation_lambda.py >/dev/null

aws lambda create-function --function-name "$FALLBACK_FUNC" \
  --runtime python3.12 --role "$LAMBDA_ROLE_ARN" \
  --handler fallback_lambda.lambda_handler \
  --zip-file fileb:///tmp/fallback.zip --timeout 30 --memory-size 256 \
  --tags $TAG_KEY=$TAG_VAL --region "$REGION" >/dev/null
FALLBACK_ARN=$(aws lambda get-function --function-name "$FALLBACK_FUNC" \
  --region "$REGION" --query 'Configuration.FunctionArn' --output text)
echo "Fallback Lambda: $FALLBACK_ARN"

aws lambda create-function --function-name "$DEGRADE_FUNC" \
  --runtime python3.12 --role "$LAMBDA_ROLE_ARN" \
  --handler degradation_lambda.lambda_handler \
  --zip-file fileb:///tmp/degrade.zip --timeout 15 --memory-size 128 \
  --tags $TAG_KEY=$TAG_VAL --region "$REGION" >/dev/null
DEGRADE_ARN=$(aws lambda get-function --function-name "$DEGRADE_FUNC" \
  --region "$REGION" --query 'Configuration.FunctionArn' --output text)
echo "Degradation Lambda: $DEGRADE_ARN"

# ---- 2. Step Functions execution role (P3-7) -------------------------------
cat > /tmp/sfn-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
SFN_ROLE_ARN=$(aws iam create-role --role-name "$SFN_ROLE" \
  --assume-role-policy-document file:///tmp/sfn-trust.json \
  --tags Key=$TAG_KEY,Value=$TAG_VAL --query 'Role.Arn' --output text 2>/dev/null \
  || aws iam get-role --role-name "$SFN_ROLE" --query 'Role.Arn' --output text)

cat > /tmp/sfn-inline.json <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["lambda:InvokeFunction"],
   "Resource":["$PRIMARY_ARN","$FALLBACK_ARN","$DEGRADE_ARN","${PRIMARY_ARN}:*","${FALLBACK_ARN}:*","${DEGRADE_ARN}:*"]}]}
JSON
aws iam put-role-policy --role-name "$SFN_ROLE" \
  --policy-name invoke-lambdas --policy-document file:///tmp/sfn-inline.json
echo "SFN role: $SFN_ROLE_ARN  (waiting 10s for propagation)"
sleep 10

# ---- 3. Render ASL with real ARNs (P3-8) -----------------------------------
sed -e "s|\${PrimaryModelLambdaArn}|$PRIMARY_ARN|g" \
    -e "s|\${FallbackModelLambdaArn}|$FALLBACK_ARN|g" \
    -e "s|\${DegradationLambdaArn}|$DEGRADE_ARN|g" \
    state_machine.json > /tmp/state_machine_rendered.json

# ---- 4. Create the state machine -------------------------------------------
SM_ARN=$(aws stepfunctions create-state-machine --name "$SM_NAME" \
  --definition file:///tmp/state_machine_rendered.json \
  --role-arn "$SFN_ROLE_ARN" \
  --tags key=$TAG_KEY,value=$TAG_VAL --region "$REGION" \
  --query stateMachineArn --output text)
echo "State machine: $SM_ARN"

# ---- 5. Save IDs for teardown (P3-E) ---------------------------------------
cat > "$ENV_OUT" <<EOF
REGION=$REGION
FALLBACK_FUNC=$FALLBACK_FUNC
DEGRADE_FUNC=$DEGRADE_FUNC
SFN_ROLE=$SFN_ROLE
SM_ARN=$SM_ARN
EOF

echo
echo "=== Part 3 core deployed ==="
echo "State machine ARN: $SM_ARN"
echo "IDs saved to $ENV_OUT"
echo
echo "Test — happy path (primary succeeds):"
echo "  aws stepfunctions start-execution --state-machine-arn $SM_ARN \\"
echo "    --input '{\"prompt\":\"What is a 401(k)?\",\"use_case\":\"general\"}' --region $REGION"
echo
echo "Then check the result:"
echo "  aws stepfunctions describe-execution --execution-arn <executionArn> \\"
echo "    --region $REGION --query 'output' --output text"
