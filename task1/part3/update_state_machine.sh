#!/usr/bin/env bash
#
# Part 3 — Update the deployed state machine definition (deterministic)
# =====================================================================
# Re-renders state_machine.json with the REAL deployed Lambda ARNs and pushes
# it to the existing state machine. Use this after editing state_machine.json.
#
# Why this script exists: doing the render + update by hand relies on shell
# variables being set in the same session. If they're empty, sed substitutes
# the ${...} tokens with EMPTY strings, producing "FunctionName": "" and the
# runtime error: Lambda.SdkClientException "FunctionName cannot be empty".
# This script resolves the ARNs itself and HARD-FAILS if any is empty, so a
# broken definition can never be deployed.
#
set -euo pipefail

REGION="us-west-2"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
SM_ARN="arn:aws:states:us-west-2:${ACCOUNT}:stateMachine:ai-assistant-resilient"
PRIMARY_FUNC="ai-assistant-model-abstraction"
FALLBACK_FUNC="ai-assistant-fallback"
DEGRADE_FUNC="ai-assistant-degradation"
SRC="state_machine.json"

[ -f "$SRC" ] || { echo "ERROR: $SRC not found (run from part3/)."; exit 1; }

get_arn() {
  aws lambda get-function --function-name "$1" --region "$REGION" \
    --query 'Configuration.FunctionArn' --output text 2>/dev/null
}

PRIMARY_ARN=$(get_arn "$PRIMARY_FUNC")
FALLBACK_ARN=$(get_arn "$FALLBACK_FUNC")
DEGRADE_ARN=$(get_arn "$DEGRADE_FUNC")

# Hard-fail if any ARN is missing/empty — never deploy an empty FunctionName.
for pair in "PRIMARY:$PRIMARY_ARN" "FALLBACK:$FALLBACK_ARN" "DEGRADE:$DEGRADE_ARN"; do
  name="${pair%%:*}"; val="${pair#*:}"
  if [ -z "$val" ] || [ "$val" = "None" ]; then
    echo "ERROR: $name Lambda ARN resolved empty. Is the function deployed in $REGION? Aborting."
    exit 1
  fi
done

echo "Resolved ARNs:"
echo "  primary : $PRIMARY_ARN"
echo "  fallback: $FALLBACK_ARN"
echo "  degrade : $DEGRADE_ARN"

RENDERED="/tmp/sm_rendered.json"
sed -e "s|\${PrimaryModelLambdaArn}|$PRIMARY_ARN|g" \
    -e "s|\${FallbackModelLambdaArn}|$FALLBACK_ARN|g" \
    -e "s|\${DegradationLambdaArn}|$DEGRADE_ARN|g" \
    "$SRC" > "$RENDERED"

# Safety net: confirm no un-substituted tokens and no empty FunctionName remain.
if grep -q '\${' "$RENDERED"; then
  echo "ERROR: un-substituted \${...} token remains in rendered ASL. Aborting."
  grep -n '\${' "$RENDERED"; exit 1
fi
if grep -Eq '"FunctionName"[[:space:]]*:[[:space:]]*""' "$RENDERED"; then
  echo "ERROR: empty FunctionName in rendered ASL. Aborting."; exit 1
fi

aws stepfunctions update-state-machine \
  --state-machine-arn "$SM_ARN" \
  --definition "file://$RENDERED" \
  --region "$REGION" >/dev/null

echo "State machine updated. Waiting 12s for propagation to new executions ..."
sleep 12
echo "Done. Safe to run: bash test_resilience.sh"
