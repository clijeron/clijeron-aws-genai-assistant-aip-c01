"""
Part 4 — Step 1c: Launch the SageMaker training job
===================================================

The piece the assignment never shows: it writes train.py but never submits it.
This creates (or reuses) a SageMaker execution role, uploads the dataset, and
launches a training job that runs train.py. All tagged auto-delete=true.

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
P4-8.  The assignment provides no estimator / .fit() call at all. Added the
       full estimator + fit().
P4-9.  Instance type ml.m5.xlarge (CPU). distilgpt2 on 8 rows trains fine on
       CPU in a couple of minutes and AVOIDS the GPU training-quota wall that
       fresh accounts hit (ml.g* training quota is often 0 until raised).
P4-10. Creates a SageMaker execution role if one isn't supplied (the
       assignment assumes a role exists). Tagged auto-delete=true.
P4-14. Use the generic **PyTorch** estimator (sagemaker.pytorch.PyTorch), NOT
       the HuggingFace estimator. The HuggingFace training DLCs are GPU-ONLY
       for every version we tried (4.36/2.1 AND 4.26/1.13) -> on a CPU instance
       the SDK raises "Unsupported processor: cpu. Supported processor(s): gpu."
       The PyTorch training DLC DOES ship CPU images, so we run on CPU and
       install transformers/datasets at train time via requirements.txt (placed
       in source_dir; SageMaker installs it automatically before running
       train.py). This supersedes the earlier P4-11/P4-13 HF-version approach.
------------------------------------------------------------------------------
"""

import os
import time
import json
import boto3
import sagemaker
from sagemaker.pytorch import PyTorch          # P4-14: PyTorch DLC has CPU images

REGION = "us-west-2"
ROLE_NAME = "ai-assistant-sagemaker-role"
TAG = {"Key": "auto-delete", "Value": "true"}

boto_sess = boto3.Session(region_name=REGION)
sm_sess = sagemaker.Session(boto_session=boto_sess)
iam = boto_sess.client("iam")


def ensure_role():
    """Create (or reuse) a SageMaker execution role. Returns its ARN."""
    trust = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "sagemaker.amazonaws.com"},
            "Action": "sts:AssumeRole",
        }],
    }
    try:
        arn = iam.create_role(
            RoleName=ROLE_NAME,
            AssumeRolePolicyDocument=json.dumps(trust),
            Tags=[TAG],
        )["Role"]["Arn"]
        iam.attach_role_policy(
            RoleName=ROLE_NAME,
            PolicyArn="arn:aws:iam::aws:policy/AmazonSageMakerFullAccess",
        )
        print(f"Created role {ROLE_NAME}; waiting 10s for propagation")
        time.sleep(10)
    except iam.exceptions.EntityAlreadyExistsException:
        arn = iam.get_role(RoleName=ROLE_NAME)["Role"]["Arn"]
        print(f"Reusing role {ROLE_NAME}")
    return arn


def main():
    role = os.environ.get("SAGEMAKER_ROLE_ARN") or ensure_role()
    print("Execution role:", role)

    bucket = sm_sess.default_bucket()
    prefix = "ai-assistant-finetune"
    train_input = sm_sess.upload_data(
        path="financial_qa_dataset.csv",
        bucket=bucket,
        key_prefix=f"{prefix}/data",
    )
    print("Training data at:", train_input)

    # P4-14: generic PyTorch estimator. requirements.txt in source_dir (".")
    # is auto-installed by SageMaker into the container before train.py runs,
    # so transformers/datasets are available even though the base PyTorch DLC
    # doesn't include them.
    estimator = PyTorch(
        entry_point="train.py",
        source_dir=".",
        role=role,
        instance_type="ml.m5.xlarge",     # P4-9 CPU
        instance_count=1,
        framework_version="1.13.1",       # PyTorch DLC that ships a CPU image
        py_version="py39",
        hyperparameters={"epochs": 3, "model-name": "distilgpt2"},
        sagemaker_session=sm_sess,
        tags=[TAG],
        base_job_name="ai-assistant-finetune",
    )

    estimator.fit({"training": train_input})
    print("\nTraining complete.")
    print("Model artifact:", estimator.model_data)

    with open("part4_training.env", "w") as f:
        f.write(f"MODEL_DATA={estimator.model_data}\n")
        f.write(f"ROLE_ARN={role}\n")
        f.write(f"TRAINING_JOB={estimator.latest_training_job.name}\n")
    print("Wrote part4_training.env")


if __name__ == "__main__":
    main()
