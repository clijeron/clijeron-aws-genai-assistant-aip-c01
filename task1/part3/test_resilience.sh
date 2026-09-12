#!/usr/bin/env bash
#
# Part 3 — Resilience Test Harness (v2, with failure diagnostics)
# ===============================================================
# Proves the Step Functions chain routes correctly through all three states:
#   primary (healthy)             -> handled by PRIMARY
#   primary throttled             -> handled by FALLBACK
#   primary + fallback throttled  -> handled by GRACEFUL DEGRADATION
#
# FAILURE-INJECTION: set a Lambda's RESERVED CONCURRENCY to 0 -> every
# invocation is throttled (Lambda.TooManyRequestsException). Reversible via
# delete-function-concurrency. No code changes.
#
# v2 CHANGE: a FAILED Step Functions execution stores its reason in
# `error`/`cause`, NOT in `output` (which is null). v1 only read `output`, so
# failures showed as "raw: None / UNKNOWN". v2 reads status first, then reads
# output on success OR error+cause (+ last history events) on failure.
#
# Safe: always restores normal concurrency at the end (and on Ctrl-C).
#
set -uo pipefail

REGION="us-west-2"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
SM_ARN="arn:aws:states:us-west-2:${ACCOUNT}:stateMachine:ai-assistant-resilient"
PRIMARY="ai-assistant-model-abstraction"
FALLBACK="ai-assistant-fallback"
INPUT='{"prompt":"What is a 401(k)?","use_case":"general"}'

break_fn() {
  aws lambda put-function-concurrency --function-name "$1" \
    --reserved-concurrent-executions 0 --region "$REGION" >/dev/null
  echo "  [inject] $1 reserved-concurrency=0 (throttled)"
}
fix_fn() {
  aws lambda delete-function-concurrency --function-name "$1" \
    --region "$REGION" >/dev/null 2>&1 || true
}
restore_all() {
  echo "Restoring normal concurrency on both functions ..."
  fix_fn "$PRIMARY"; fix_fn "$FALLBACK"
  echo "Restored."
}
trap restore_all EXIT

classify() {
  local out="$1"
  if   echo "$out" | grep -q "DEGRADED_SERVICE"; then echo "  => handled by: GRACEFUL DEGRADATION"
  elif echo "$out" | grep -q "FALLBACK:";        then echo "  => handled by: FALLBACK MODEL"
  elif echo "$out" | grep -q "nova-lite";        then echo "  => handled by: PRIMARY"
  else echo "  => UNKNOWN (inspect output above)"; fi
}

run_exec() {
  local label="$1" arn status out err cause
  arn=$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" \
        --input "$INPUT" --region "$REGION" --query executionArn --output text)
  echo "----- $label -----"
  echo "  execution: $arn"
  status="RUNNING"
  while [ "$status" = "RUNNING" ]; do
    sleep 2
    status=$(aws stepfunctions describe-execution --execution-arn "$arn" \
             --region "$REGION" --query status --output text)
  done
  echo "  status: $status"
  if [ "$status" = "SUCCEEDED" ]; then
    out=$(aws stepfunctions describe-execution --execution-arn "$arn" \
          --region "$REGION" --query output --output text)
    classify "$out"
    echo "  raw: $out"
  else
    # v2: FAILED executions carry error/cause, not output.
    err=$(aws stepfunctions describe-execution --execution-arn "$arn" \
          --region "$REGION" --query error --output text)
    cause=$(aws stepfunctions describe-execution --execution-arn "$arn" \
            --region "$REGION" --query cause --output text)
    echo "  error: $err"
    echo "  cause: $cause"
    echo "  --- last history events (which state failed & why) ---"
    aws stepfunctions get-execution-history --execution-arn "$arn" \
      --region "$REGION" --reverse-order --max-items 8 \
      --query 'events[].{id:id,type:type,stateEntered:stateEnteredEventDetails.name,taskErr:taskFailedEventDetails.error,taskCause:taskFailedEventDetails.cause,execErr:executionFailedEventDetails.error,execCause:executionFailedEventDetails.cause}' \
      --output json
  fi
  echo
}

echo "=========================================="
echo " Part 3 resilience test v2 — $(date)"
echo "=========================================="

fix_fn "$PRIMARY"; fix_fn "$FALLBACK"; sleep 3

echo
echo "TEST 1 — HAPPY PATH (expect: PRIMARY, model_used=us.amazon.nova-lite-v1:0)"
run_exec "TEST 1 happy path"

echo "TEST 2 — PRIMARY THROTTLED (expect: FALLBACK, model_used=FALLBACK:us.amazon.nova-lite-v1:0)"
break_fn "$PRIMARY"; sleep 8
run_exec "TEST 2 fallback path"

echo "TEST 3 — PRIMARY + FALLBACK THROTTLED (expect: GRACEFUL DEGRADATION, model_used=DEGRADED_SERVICE)"
break_fn "$FALLBACK"; sleep 8
run_exec "TEST 3 graceful degradation"

echo "All three paths exercised."
