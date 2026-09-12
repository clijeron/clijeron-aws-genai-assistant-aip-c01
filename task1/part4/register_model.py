"""
Part 4 — Step 2: Model versioning via SageMaker Model Registry
==============================================================

Registers the fine-tuned model artifact (from Step 1) as a VERSIONED model
package inside a Model Package Group. Re-running registers a new version (v1,
v2, ...) in the same group — this is the "model versioning" the assignment's
lifecycle-management step asks for.

Registry entries are metadata only — near-zero cost, safe to leave in place.

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
P4-15. The assignment describes "model versioning and deployment workflows" but
       provides NO code. Implemented with the SageMaker Model Registry:
       a Model Package Group + versioned ModelPackage entries with an approval
       status (PendingManualApproval -> Approved), which is the standard AWS
       lifecycle/versioning primitive.
P4-16. Reads MODEL_DATA + ROLE_ARN from part4_training.env (written by Step 1)
       so the registered version points at the exact artifact we trained.
P4-17. Uses a PyTorch INFERENCE image (matching the 1.13.1/py39 training DLC)
       for the model package's container definition, so the registered version
       is deployable as-is in Step 3.
------------------------------------------------------------------------------
"""

import os
import boto3
import sagemaker
from sagemaker import image_uris

REGION = "us-west-2"
GROUP = "ai-assistant-finetuned-models"
TAG = [{"Key": "auto-delete", "Value": "true"}]


def load_env(path="part4_training.env"):
    env = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                env[k] = v
    return env


def main():
    env = load_env()
    model_data = env["MODEL_DATA"]
    print("Registering artifact:", model_data)

    sm = boto3.client("sagemaker", region_name=REGION)

    # 1. Create the Model Package Group (idempotent).
    try:
        sm.create_model_package_group(
            ModelPackageGroupName=GROUP,
            ModelPackageGroupDescription="Fine-tuned distilgpt2 financial assistant — versioned",
            Tags=TAG,
        )
        print(f"Created model package group {GROUP}")
    except sm.exceptions.ClientError as e:
        if "already exists" in str(e):
            print(f"Reusing existing group {GROUP}")
        else:
            raise

    # 2. PyTorch inference image matching the training DLC (P4-17).
    inference_image = image_uris.retrieve(
        framework="pytorch",
        region=REGION,
        version="1.13.1",
        py_version="py39",
        instance_type="ml.m5.xlarge",
        image_scope="inference",
    )
    print("Inference image:", inference_image)

    # 3. Register a new VERSION in the group.
    resp = sm.create_model_package(
        ModelPackageGroupName=GROUP,
        ModelPackageDescription="distilgpt2 financial fine-tune",
        InferenceSpecification={
            "Containers": [{
                "Image": inference_image,
                "ModelDataUrl": model_data,
            }],
            "SupportedContentTypes": ["application/json"],
            "SupportedResponseMIMETypes": ["application/json"],
        },
        ModelApprovalStatus="PendingManualApproval",  # P4-15 lifecycle
    )
    arn = resp["ModelPackageArn"]
    print("Registered model package version:", arn)

    # 4. Approve it (so Step 3 can deploy it). In a real workflow this is a
    #    separate human/CI gate.
    sm.update_model_package(ModelPackageArn=arn, ModelApprovalStatus="Approved")
    print("Approved:", arn)

    # List all versions in the group for visibility.
    versions = sm.list_model_packages(ModelPackageGroupName=GROUP,
                                      SortBy="CreationTime", SortOrder="Ascending")
    print("\nVersions in group:")
    for p in versions["ModelPackageSummaryList"]:
        print(f"  v{p['ModelPackageVersion']}  {p['ModelApprovalStatus']}  {p['ModelPackageArn']}")

    with open("part4_registry.env", "w") as f:
        f.write(f"MODEL_PACKAGE_GROUP={GROUP}\n")
        f.write(f"LATEST_PACKAGE_ARN={arn}\n")
        f.write(f"ROLE_ARN={env['ROLE_ARN']}\n")
    print("\nWrote part4_registry.env")


if __name__ == "__main__":
    main()
