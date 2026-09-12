#!/usr/bin/env bash
#
# Part 4 — Teardown
# =================
# Removes Part 4 resources. Training jobs are ephemeral (they stop on their own
# and only bill while running), but this cleans up the persistent bits:
#   - any SageMaker model / endpoint / endpoint-config created in Step 2-3
#   - the SageMaker execution role
#   - (optionally) the S3 training artifacts
#
# ⚠️ SageMaker ENDPOINTS bill per hour while they exist — deleting them is the
# single most important cost action in this whole module.
#
set -uo pipefail

REGION="us-west-2"
ROLE_NAME="ai-assistant-sagemaker-role"
ENDPOINT="${1:-ai-assistant-finetuned-endpoint}"   # pass endpoint name if different

echo "== Deleting SageMaker inference endpoint (if any): $ENDPOINT =="
aws sagemaker delete-endpoint --endpoint-name "$ENDPOINT" --region "$REGION" \
  && echo "  endpoint deleted" || echo "  no endpoint named $ENDPOINT"
aws sagemaker delete-endpoint-config --endpoint-config-name "$ENDPOINT" --region "$REGION" \
  >/dev/null 2>&1 && echo "  endpoint-config deleted" || true

echo "== Deleting registered model(s) with our base name (if any) =="
for M in $(aws sagemaker list-models --region "$REGION" \
    --name-contains ai-assistant-finetuned --query 'Models[].ModelName' --output text 2>/dev/null); do
  aws sagemaker delete-model --model-name "$M" --region "$REGION" && echo "  deleted model $M" || true
done

echo "== Detaching + deleting execution role: $ROLE_NAME =="
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null \
  && echo "  role deleted" || echo "  role busy/gone"

echo
echo "Part 4 teardown complete."
echo "NOTE: training-job records and S3 model.tar.gz artifacts are retained (harmless,"
echo "near-zero cost). Empty the SageMaker default bucket manually if you want them gone."
