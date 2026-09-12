"""
Part 3 — Fallback Model Lambda
==============================

Invoked by the Step Functions state machine when the primary model
(the Part 2 abstraction Lambda) fails after its retries. Uses a simpler,
more-reliable model with reduced parameters.

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
P3-1. Fallback model amazon.titan-text-express-v1 -> us.amazon.nova-lite-v1:0.
      Titan Text Express is RETIRED in acct <AWS_ACCOUNT_ID>/us-west-2 (Part 1
      finding #7); Nova Lite is the current Amazon text model and is also this
      account's Part 1 "primary", so it's a proven-reliable fallback.

P3-2. Invocation uses the Converse API instead of the raw invoke_model + hand
      built Titan JSON body. Same rationale as Parts 1-2.

P3-3. inferenceConfig sends ONLY temperature (no topP) — Claude models reject
      both; kept consistent across all parts (Part 1 Change #8).

P3-4. Region pinned to us-west-2 (env-overridable) on the client.

P3-5. On failure the handler RAISES, so Step Functions' Catch moves to the
      GracefulDegradation state (this behavior matches the assignment intent).
------------------------------------------------------------------------------
"""

import os
import json
import boto3

REGION = os.environ.get("AWS_REGION", "us-west-2")
FALLBACK_MODEL = os.environ.get("FALLBACK_MODEL", "us.amazon.nova-lite-v1:0")  # P3-1

bedrock_runtime = boto3.client("bedrock-runtime", region_name=REGION)


def lambda_handler(event, context):
    prompt = event.get("prompt", "")
    use_case = event.get("use_case", "general")

    try:
        resp = bedrock_runtime.converse(  # P3-2
            modelId=FALLBACK_MODEL,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            inferenceConfig={"maxTokens": 300, "temperature": 0.5},  # P3-3 (no topP)
        )
        output = resp["output"]["message"]["content"][0]["text"]
        return {
            "statusCode": 200,
            "body": json.dumps({
                "model_used": f"FALLBACK:{FALLBACK_MODEL}",
                "response": output,
            }),
        }
    except Exception as e:
        # P3-5: let Step Functions catch this and route to graceful degradation.
        raise Exception(f"Fallback model failed: {e}")
