#!/usr/bin/env bash
#
# Part 3 — Cross-region teardown (secondary region: us-east-1)
# ============================================================
# Deletes the CloudFormation stack (Lambda + role + API Gateway) in one call.
# Because everything was created by the stack, delete-stack removes it all in
# dependency order.
#
set -uo pipefail

SECONDARY_REGION="us-east-1"
STACK="ai-assistant-crossregion"

echo "Deleting stack $STACK in $SECONDARY_REGION ..."
aws cloudformation delete-stack --stack-name "$STACK" --region "$SECONDARY_REGION"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$SECONDARY_REGION" \
  && echo "Stack deleted." || echo "Delete initiated (wait timed out or already gone)."
