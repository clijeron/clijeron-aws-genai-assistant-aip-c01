"""
Part 4 — Repackage the model artifact to include code/inference.py, then
register it as a NEW VERSION (v2) in the Model Registry.
========================================================================

Fixes the ReadTimeout by embedding a working inference handler in the model
tarball, and doubles as a demonstration of the Step 2 versioning workflow
(v1 = no handler / broken; v2 = with handler / working).

Flow:
  1. Download the Step 1 model.tar.gz (from part4_training.env MODEL_DATA).
  2. Extract it, add code/inference.py + code/requirements.txt.
  3. Re-tar and upload to S3.
  4. Register as a new version in the same Model Package Group, Approved.
  5. Overwrite part4_registry.env LATEST_PACKAGE_ARN to point at v2.

------------------------------------------------------------------------------
CHANGELOG P4-23: the raw artifact has no serving code; the PyTorch DLC needs
code/inference.py (+ its own requirements) INSIDE the tarball under code/.
------------------------------------------------------------------------------
"""

import os
import json
import tarfile
import shutil
import boto3
import sagemaker
from sagemaker import image_uris

REGION = "us-west-2"
GROUP = "ai-assistant-finetuned-models"
WORK = "/tmp/model_repack"


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                env[k] = v
    return env


def main():
    tenv = load_env("part4_training.env")
    model_data = tenv["MODEL_DATA"]
    role = tenv["ROLE_ARN"]

    boto_sess = boto3.Session(region_name=REGION)
    sm_sess = sagemaker.Session(boto_session=boto_sess)
    s3 = boto_sess.client("s3")
    sm = boto_sess.client("sagemaker")

    # 1. Download the original artifact.
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    local_tar = os.path.join(WORK, "model.tar.gz")
    assert model_data.startswith("s3://")
    bkt, key = model_data[5:].split("/", 1)
    print(f"Downloading {model_data} ...")
    s3.download_file(bkt, key, local_tar)

    # 2. Extract + inject code/.
    extract_dir = os.path.join(WORK, "model")
    os.makedirs(extract_dir, exist_ok=True)
    with tarfile.open(local_tar) as t:
        t.extractall(extract_dir)
    code_dir = os.path.join(extract_dir, "code")
    os.makedirs(code_dir, exist_ok=True)
    shutil.copy("inference.py", os.path.join(code_dir, "inference.py"))
    with open(os.path.join(code_dir, "requirements.txt"), "w") as f:
        f.write("transformers==4.26.1\n")
    print("Injected code/inference.py + code/requirements.txt")

    # 3. Re-tar and upload.
    new_tar = os.path.join(WORK, "model-with-code.tar.gz")
    with tarfile.open(new_tar, "w:gz") as t:
        for name in os.listdir(extract_dir):
            t.add(os.path.join(extract_dir, name), arcname=name)
    new_key = "ai-assistant-finetune/repackaged/model.tar.gz"
    s3.upload_file(new_tar, bkt, new_key)
    new_model_data = f"s3://{bkt}/{new_key}"
    print("Uploaded repackaged artifact:", new_model_data)

    # 4. Register as a new version (Approved).
    inference_image = image_uris.retrieve(
        framework="pytorch", region=REGION, version="1.13.1",
        py_version="py39", instance_type="ml.m5.xlarge", image_scope="inference",
    )
    resp = sm.create_model_package(
        ModelPackageGroupName=GROUP,
        ModelPackageDescription="distilgpt2 financial fine-tune (with inference handler)",
        InferenceSpecification={
            "Containers": [{"Image": inference_image, "ModelDataUrl": new_model_data}],
            "SupportedContentTypes": ["application/json"],
            "SupportedResponseMIMETypes": ["application/json"],
        },
        ModelApprovalStatus="PendingManualApproval",
    )
    arn = resp["ModelPackageArn"]
    sm.update_model_package(ModelPackageArn=arn, ModelApprovalStatus="Approved")
    print("Registered + approved new version:", arn)

    versions = sm.list_model_packages(ModelPackageGroupName=GROUP,
                                      SortBy="CreationTime", SortOrder="Ascending")
    print("\nVersions in group:")
    for p in versions["ModelPackageSummaryList"]:
        print(f"  v{p['ModelPackageVersion']}  {p['ModelApprovalStatus']}  {p['ModelPackageArn']}")

    # 5. Point deploy step at the new version.
    with open("part4_registry.env", "w") as f:
        f.write(f"MODEL_PACKAGE_GROUP={GROUP}\n")
        f.write(f"LATEST_PACKAGE_ARN={arn}\n")
        f.write(f"ROLE_ARN={role}\n")
    print("\nUpdated part4_registry.env -> v2. Now re-run: python deploy_test_rollback.py")


if __name__ == "__main__":
    main()
