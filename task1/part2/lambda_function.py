"""
Part 2 — Model Abstraction Lambda
=================================

Adapted from the AWS Exam Prep bonus assignment (Part 2, Step 2). This Lambda
sits behind API Gateway, reads the model-selection strategy from AWS AppConfig,
picks a model, and invokes it on Amazon Bedrock.

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
P2-1. AppConfig retrieval uses the DATA PLANE (appconfigdata) instead of the
      deprecated appconfig.get_configuration() call in the assignment.
      get_configuration() is deprecated; AWS now expects the two-step
      StartConfigurationSession -> GetLatestConfiguration flow (or the AppConfig
      Lambda extension). The data-plane client needs no extra layer, so it is
      the cleanest drop-in for a lab.

P2-2. Model invocation uses the Converse API (bedrock-runtime.converse) instead
      of per-provider hand-built JSON bodies + `if "anthropic"/"amazon"`
      branching. Same reasoning as Part 1: one uniform shape across Claude,
      Nova, Llama, etc.

P2-3. inferenceConfig sends ONLY temperature (no topP). Claude Sonnet 4.6 /
      Haiku 4.5 reject a Converse call that specifies both
      (ValidationException). Carried over from Part 1 Change #8.

P2-4. Region pinned to us-west-2 on every client (env-overridable).

P2-5. Config identifiers are read from environment variables so the same code
      works across environments without edits.
------------------------------------------------------------------------------
"""

import os
import json
import boto3

REGION = os.environ.get("AWS_REGION", "us-west-2")
APP = os.environ.get("APPCONFIG_APP", "AIAssistantApp")
ENV = os.environ.get("APPCONFIG_ENV", "Production")
PROFILE = os.environ.get("APPCONFIG_PROFILE", "ModelSelectionStrategy")

# Data-plane client for AppConfig (P2-1) + Bedrock runtime for invocation.
appconfigdata = boto3.client("appconfigdata", region_name=REGION)
bedrock_runtime = boto3.client("bedrock-runtime", region_name=REGION)

# Cache the session token + last-known config across warm invocations so we
# don't open a new configuration session on every request.
_cache = {"token": None, "config": None}


def _load_config():
    """Fetch the latest model-selection strategy from AppConfig (data plane)."""
    if _cache["token"] is None:
        session = appconfigdata.start_configuration_session(
            ApplicationIdentifier=APP,
            EnvironmentIdentifier=ENV,
            ConfigurationProfileIdentifier=PROFILE,
        )
        _cache["token"] = session["InitialConfigurationToken"]

    resp = appconfigdata.get_latest_configuration(ConfigurationToken=_cache["token"])
    # Always roll the token forward for the next poll.
    _cache["token"] = resp["NextPollConfigurationToken"]

    content = resp["Configuration"].read()
    if content:  # empty payload means "unchanged since last poll"
        _cache["config"] = json.loads(content.decode("utf-8"))
    return _cache["config"]


def select_model(config, use_case):
    """Select a model based on config + use case (unchanged logic from assignment)."""
    use_case_models = config.get("use_case_models", {})
    if use_case in use_case_models:
        return use_case_models[use_case]
    return config.get("primary_model")


def invoke_model(model_id, prompt):
    """Invoke the selected model via the Converse API (P2-2, P2-3)."""
    # P3-12: do NOT swallow Bedrock errors here. The original returned the
    # error string as a normal value, so the handler always produced a 200 and
    # Step Functions never saw a failure -> the fallback/degradation chain
    # could never fire. Let the exception propagate; the handler decides how to
    # surface it per invocation source.
    resp = bedrock_runtime.converse(
        modelId=model_id,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 500, "temperature": 0.7},  # no topP (P2-3)
    )
    return resp["output"]["message"]["content"][0]["text"]


def lambda_handler(event, context):
    config = _load_config()

    # P3-11: accept BOTH invocation shapes.
    #   - API Gateway proxy: payload is a JSON string in event["body"].
    #   - Direct / Step Functions: payload IS the event (no "body" wrapper).
    # The original only handled the API Gateway shape, so Step Functions
    # invocation produced an empty prompt -> Bedrock ValidationException
    # ("text field ... is blank").
    raw = event.get("body")
    if isinstance(raw, str):
        body = json.loads(raw or "{}")
    elif isinstance(raw, dict):
        body = raw
    else:
        body = event
    prompt = body.get("prompt", "")
    use_case = body.get("use_case", "general")

    # P3-12: API Gateway proxy always includes a "body" key; a direct/Step
    # Functions invocation does not. We use that to decide error handling:
    #   - API Gateway  -> return a clean HTTP 500 (don't throw at the client)
    #   - Step Functions -> RAISE so the state machine's Catch routes to fallback
    is_apigw = "body" in event

    model_id = select_model(config, use_case)
    try:
        response = invoke_model(model_id, prompt)
    except Exception as e:
        print(f"Error invoking model {model_id}: {e}")
        if is_apigw:
            return {
                "statusCode": 500,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"model_used": model_id, "error": str(e)}),
            }
        raise  # propagate to Step Functions Catch -> fallback

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"model_used": model_id, "response": response}),
    }
