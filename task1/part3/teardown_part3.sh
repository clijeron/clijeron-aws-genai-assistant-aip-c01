#!/usr/bin/env bash
#
# Part 3 — Teardown (core)
# ========================
# Deletes the state machine, the two Part 3 Lambdas, and the SFN role,
# using IDs saved in part3_resources.env. Does NOT touch Part 2 resources
# (the primary Lambda + its role remain — Part 2 owns them).
#
set -uo pipefail

[ -f part3_resources.env ] || { echo "part3_resources.env not found (run from part3/)."; exit 1; }
# shellcheck disable=SC1091
source part3_resources.env

echo "Tearing down Part 3 core in $REGION ..."

aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN" --region "$REGION" \
  && echo "deleted state machine" || echo "state machine already gone"

aws lambda delete-function --function-name "$FALLBACK_FUNC" --region "$REGION" \
  && echo "deleted $FALLBACK_FUNC" || echo "$FALLBACK_FUNC already gone"
aws lambda delete-function --function-name "$DEGRADE_FUNC" --region "$REGION" \
  && echo "deleted $DEGRADE_FUNC" || echo "$DEGRADE_FUNC already gone"

aws iam delete-role-policy --role-name "$SFN_ROLE" --policy-name invoke-lambdas || true
aws iam delete-role --role-name "$SFN_ROLE" \
  && echo "deleted role $SFN_ROLE" || echo "role already gone"

echo "Part 3 core teardown complete."
echo "NOTE: Part 2 resources (primary Lambda, its role, API Gateway, AppConfig) are intentionally left intact."
