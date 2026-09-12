# Resilient, Multi-Model Gen AI Assistant on AWS (AIP-C01 · Module 01 · Task 1)

A hands-on, production-shaped Gen AI project: benchmark Amazon Bedrock models,
serve them behind a swappable architecture, make the whole thing survive
outages across regions, and manage a custom fine-tuned model's lifecycle.

> **New to AI/cloud?** Read `BLOG_OUTLINE.md` first — it tells this project as a
> friendly story. This README is the *do-it-yourself* guide: run the four parts
> in order and you'll reproduce the whole thing **with no troubleshooting**,
> because every gotcha we hit is already fixed here (see `CHANGELOG.md` for the
> full "what changed & why").

---

## What you'll build

```
Customer question
      │
      ▼
Route 53 (aws.lijeron.net)  ── health-checked failover ──►  us-west-2 (PRIMARY)  ─┐
      │                                                     us-east-1 (SECONDARY) ─┤
      ▼                                                                            │
API Gateway ─► Lambda ─► AppConfig (which model?) ─► Amazon Bedrock  ◄─────────────┘
                          └► Step Functions: primary → fallback → graceful degradation
Model lifecycle: SageMaker fine-tune → Model Registry (v1, v2…) → deploy → test → rollback
```

| Part | What it does | Key services |
|------|--------------|--------------|
| 1 | Benchmark 3 Bedrock models (quality / latency / cost) → pick primary + fallbacks | Bedrock (Converse API) |
| 2 | Serve the model behind a swappable, config-driven API | API Gateway, Lambda, AppConfig |
| 3 | Survive failures: retry→fallback→degrade, cross-region, DNS failover | Step Functions, CloudFormation, ACM, Route 53 |
| 4 | Fine-tune, version, and safely promote a custom model | SageMaker, Model Registry |

---

## Prerequisites (do these once, up front — this is what prevents delays)

1. **An AWS account + AWS CLI configured.** Confirm:
   ```bash
   aws sts get-caller-identity        # note your Account ID and region
   ```
   This project used account `<AWS_ACCOUNT_ID>`, region **`us-west-2`** (primary) and
   **`us-east-1`** (secondary). Substitute your own throughout.

2. **Enable Bedrock model access — PER REGION.** Bedrock console → *Model access* →
   enable the models you'll use, in **both** us-west-2 **and** us-east-1.
   > ⚠️ Model access does **not** cross regions. A model enabled in us-west-2 will
   > return `AccessDenied` in us-east-1 until enabled there too. This is the #1
   > silent stumbling block.

3. **Discover the model IDs actually available to you** (they change over time):
   ```bash
   aws bedrock list-inference-profiles --region us-west-2 \
     --query "inferenceProfileSummaries[].inferenceProfileId" --output table
   ```
   Anthropic/Nova models are invoked via **inference-profile IDs** (the `us.`-prefixed
   ones), not the bare model IDs. Put your three choices in `part1/benchmark.py`.

4. **Python + tooling:**
   ```bash
   python -m pip install boto3 pandas "sagemaker>=2.220,<3"
   brew install jq                     # optional, for pretty JSON in tests
   ```
   > ⚠️ Pin `sagemaker<3`. The v3 SDK removed the classic `sagemaker.huggingface` /
   > estimator API this project uses.

5. **(Part 3 failover only) A domain you control**, so you can delegate a subdomain
   (e.g. `aws.lijeron.net`) to this account for Route 53 health checks. See
   `part3/failover/README_failover.md`.

---

## Cost & cleanup (read before you deploy)

Most of this project is **pay-per-use and ~$0 at idle**. The exceptions:

| Resource | Cost | Action |
|----------|------|--------|
| Bedrock invocations | per-token, tiny | nothing idles |
| Lambda / API Gateway / AppConfig / Step Functions | ~$0 idle | fine to leave |
| **SageMaker inference endpoint** | **per-hour, continuous** | **delete immediately after testing** (Part 4 auto-deletes it) |
| SageMaker training job | per-second, only while running | auto-terminates |
| **Route 53 health check** | **~$0.50/month** | delete when done |
| ACM certificates | free | — |

Everything is tagged **`auto-delete=true`**. To find/sweep everything later:
```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=auto-delete,Values=true --region us-west-2
```
> **A tag does not delete anything by itself** — it's just a label so you (or an
> account janitor) can find and remove resources. Use the per-part teardown
> scripts for guaranteed cleanup.

---

## Run it — four parts, in order

### Part 1 — Benchmark the models
```bash
cd task1/part1
python benchmark.py
# → model_evaluation_results.csv, model_selection_strategy.json
```
Edit the `MODELS = [...]` list at the top with your enabled inference-profile IDs
(or leave it to auto-discover). `model_selection_strategy.json` feeds Part 2.

### Part 2 — Serve it behind a swappable API
```bash
cd ../part2
chmod +x deploy_part2.sh teardown_part2.sh
bash deploy_part2.sh          # creates role → Lambda → AppConfig → API Gateway
# test (endpoint is printed by the script):
curl -s -X POST "<endpoint>" -H 'Content-Type: application/json' \
  -d '{"prompt":"What is a 401(k)?","use_case":"general"}' | jq .
# cleanup when done:
bash teardown_part2.sh
```

### Part 3 — Make it resilient
```bash
cd ../part3
chmod +x *.sh
bash deploy_part3.sh          # Step Functions + fallback + degradation Lambdas
bash test_resilience.sh       # proves primary → fallback → degradation (forces failures safely)

# cross-region secondary (us-east-1):
bash deploy_crossregion.sh    # CloudFormation stack (self-contained, env-var model)

# DNS failover on your subdomain (see failover/README_failover.md for the full ordered flow):
cd failover && chmod +x *.sh
bash r53_01_health.sh         # /health endpoint (us-west-2)
cd .. && bash deploy_crossregion.sh   # adds /health to us-east-1
cd failover
bash r53_02_certs.sh          # ACM certs (waits for ISSUED)
bash r53_03_custom_domains.sh # API Gateway custom domains
bash r53_04_failover_records.sh
# test the unified endpoint:
curl -s -X POST https://<your-subdomain>/generate -H 'Content-Type: application/json' \
  -d '{"prompt":"What is a 401(k)?","use_case":"general"}' | jq .

# cleanup:
bash r53_teardown.sh ; cd .. ; bash teardown_crossregion.sh ; bash teardown_part3.sh
```

### Part 4 — Fine-tune, version, and safely promote
```bash
cd ../part4
python prepare_dataset.py          # financial_qa_dataset.csv
python launch_training.py          # SageMaker training job → model.tar.gz (CPU, ~3 min)
python register_model.py           # Model Registry: register + approve v1
python repackage_with_inference.py # add serving handler → register v2
python deploy_test_rollback.py     # deploy v2 → smoke test → auto-delete endpoint
# backstop cleanup:
bash teardown_part4.sh
```

---

## Gotchas already handled for you (so you hit none)

These were real errors during the build; the code here already avoids them.
Full detail + reasons in `CHANGELOG.md`.

| Symptom you'd otherwise hit | Why | Already fixed by |
|---|---|---|
| `ValidationException: temperature and top_p cannot both be specified` | Newer Claude models reject both | Converse sends only `temperature` |
| Benchmark silently ranks only 1 model | Per-model errors were swallowed | current model IDs + Converse |
| AppConfig profile rejects your JSON | `FeatureFlags` type enforces a schema | use `AWS.Freeform` |
| API endpoint returns 500 | API Gateway lacked permission to call Lambda | `lambda:add-permission` added |
| Step Functions fails instead of failing over | `Catch` replaced the input, losing `$.prompt` | `ResultPath` preserves input |
| `FunctionName cannot be empty` | shell vars empty when rendering the state machine | `update_state_machine.sh` hard-fails on empty ARNs |
| `Unsupported processor: cpu` | HuggingFace training DLC is GPU-only | use the PyTorch estimator + `requirements.txt` |
| `ModuleNotFoundError: sagemaker.huggingface` | SDK v3 removed it | pin `sagemaker<3` |
| Endpoint invoke hangs → `ReadTimeout` | no inference handler in the artifact | `inference.py` in `code/` |
| `Tags are not supported in Model Package versions` | tags belong on the group | tag the group, not the version |
| DNS/subdomain won't resolve | parent domain expired / registrar not pointing at Route 53 | see `failover/README_failover.md` |

---

## Repo layout
```
module01/
├── README.md              ← you are here
├── BLOG_OUTLINE.md        ← the friendly story version
├── CHANGELOG.md           ← every change vs. the original assignment, with reasons
└── task1/
    ├── part1/  benchmark.py
    ├── part2/  lambda_function.py, deploy_part2.sh, teardown_part2.sh
    ├── part3/  state_machine.json, fallback_lambda.py, degradation_lambda.py,
    │           deploy_part3.sh, teardown_part3.sh, test_resilience.sh,
    │           update_state_machine.sh, template.yaml, deploy_crossregion.sh,
    │           teardown_crossregion.sh, failover/
    └── part4/  prepare_dataset.py, train.py, launch_training.py, requirements.txt,
                register_model.py, repackage_with_inference.py, inference.py,
                deploy_test_rollback.py, teardown_part4.sh
```

---

## Credits & sharing
Built as an AWS Exam Prep bonus project (AIP-C01). If you adapt it, tag
**#awsexamprep**. The `CHANGELOG.md` documents how the original assignment was
updated for the current AWS environment — the real skill isn't following a
tutorial, it's adapting when the tutorial goes stale.
