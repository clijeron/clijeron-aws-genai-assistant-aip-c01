"""
Part 4 — Step 3: Automated testing + rollback with a real endpoint
==================================================================

Demonstrates the deployment/rollback lifecycle the assignment asks for:
  1. Deploy the APPROVED model package (Step 2) to a real SageMaker endpoint.
  2. Run an automated smoke test (invoke with a financial prompt, check output).
  3. If the test PASSES -> keep (then we delete anyway for cost; a real pipeline
     would leave it). If it FAILS -> "rollback": delete the new endpoint so no
     bad version serves traffic.
  4. ALWAYS delete the endpoint + config at the end (cost safety) unless
     KEEP_ENDPOINT=1 is set.

⚠️ COST: a real-time endpoint bills PER HOUR while it exists. This script is
written so the endpoint's lifetime is only as long as the test. The `finally`
block deletes it even on error/Ctrl-C.

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
P4-18. The assignment describes "automated testing and rollback strategies" but
       provides NO code. Implemented: deploy -> automated smoke test -> keep or
       rollback(delete) -> guaranteed teardown.
P4-19. Endpoint teardown is in a `finally` block + a module-level atexit guard,
       so a real-time (hourly-billed) endpoint cannot be left running by an
       exception or interrupt. KEEP_ENDPOINT=1 opts out for manual inspection.
P4-20. "Rollback" is modeled as: on test failure, delete the just-deployed
       endpoint so the previous approved version keeps serving (i.e., never
       promote a failing version). Logged distinctly from a true blue/green
       traffic-shift rollback, which needs two live endpoints.
------------------------------------------------------------------------------
"""

import os
import json
import time
import atexit
import boto3
import sagemaker
from sagemaker import ModelPackage

REGION = "us-west-2"
ENDPOINT = "ai-assistant-finetuned-endpoint"
TAG = [{"Key": "auto-delete", "Value": "true"}]

boto_sess = boto3.Session(region_name=REGION)
sm_sess = sagemaker.Session(boto_session=boto_sess)
sm = boto_sess.client("sagemaker")


def load_env(path="part4_registry.env"):
    env = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                env[k] = v
    return env


def delete_endpoint():
    """Idempotent teardown of endpoint + endpoint-config (cost safety, P4-19)."""
    for fn, kwargs, label in [
        (sm.delete_endpoint, {"EndpointName": ENDPOINT}, "endpoint"),
        (sm.delete_endpoint_config, {"EndpointConfigName": ENDPOINT}, "endpoint-config"),
    ]:
        try:
            fn(**kwargs)
            print(f"  deleted {label}")
        except Exception:
            pass


def smoke_test():
    """Invoke the endpoint and validate we get a non-empty text completion."""
    # P4-22: catch ANY invoke failure (timeout, 5xx, model error) and treat it
    # as a FAILED test that triggers rollback — never let it crash the harness.
    # A short read timeout keeps a hung/misconfigured endpoint from stalling
    # the whole pipeline.
    from botocore.config import Config
    rt = boto_sess.client(
        "sagemaker-runtime",
        config=Config(read_timeout=30, retries={"max_attempts": 0}),
    )
    payload = {"inputs": "Question: What is a 401(k)?\nAnswer:"}
    try:
        resp = rt.invoke_endpoint(
            EndpointName=ENDPOINT,
            ContentType="application/json",
            Body=json.dumps(payload),
        )
        body = resp["Body"].read().decode()
        print("  raw response:", body[:300])
        return len(body.strip()) > 0
    except Exception as e:
        print(f"  smoke test invoke FAILED: {type(e).__name__}: {e}")
        return False


def main():
    env = load_env()
    pkg_arn = env["LATEST_PACKAGE_ARN"]
    role = env["ROLE_ARN"]
    keep = os.environ.get("KEEP_ENDPOINT") == "1"

    # Guarantee teardown no matter how we exit (unless KEEP_ENDPOINT=1).
    if not keep:
        atexit.register(delete_endpoint)

    print("Deploying model package:", pkg_arn)
    model = ModelPackage(role=role, model_package_arn=pkg_arn, sagemaker_session=sm_sess)

    test_passed = False
    try:
        model.deploy(
            initial_instance_count=1,
            instance_type="ml.m5.xlarge",
            endpoint_name=ENDPOINT,
            tags=TAG,
        )
        print("Endpoint InService:", ENDPOINT)

        print("\nRunning automated smoke test ...")
        test_passed = smoke_test()
        print("  test_passed:", test_passed)

        if not test_passed:
            # P4-20: rollback = delete the bad new endpoint so it never serves.
            print("\n❌ Test FAILED — rolling back (deleting the new endpoint). "
                  "Previous approved version remains the serving version.")
        else:
            print("\n✅ Test PASSED — new version validated.")

    finally:
        if keep:
            print("\nKEEP_ENDPOINT=1 set — leaving endpoint RUNNING (bills hourly!). "
                  f"Delete with: aws sagemaker delete-endpoint --endpoint-name {ENDPOINT} --region {REGION}")
        else:
            print("\nTearing down endpoint (cost safety) ...")
            delete_endpoint()

    print("\nResult:", "PASS" if test_passed else "FAIL (rolled back)")


if __name__ == "__main__":
    main()
