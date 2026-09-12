# Module 01 — Change Log

**Certification:** AIP-C01
**Account:** <AWS_ACCOUNT_ID>   **Region:** us-west-2
**Purpose:** Track every deviation from the original AWS Exam Prep assignment, with
the reason, so the blog can explain *what changed and why*. Keep this file updated
as each part is deployed and validated.

> Format: each part has a table of changes. "Original" = as written in the
> assignment; "Change" = what was actually used; "Why" = justification for the blog.

---

## Task 1 — Building a Resilient, Multi-Model AI Assistant

### Part 1 — Foundation Model Assessment & Benchmarking
**File:** `task1/part1/benchmark.py`
**Status:** ✅ Deployed & validated (all 3 models succeed; run 2026-09-12)

| # | Original (assignment) | Change | Why |
|---|---|---|---|
| 1 | `boto3.client('bedrock-runtime')` (no region) | `boto3.client('bedrock-runtime', region_name='us-west-2')` | Original silently uses the default profile's region; pinning guarantees us-west-2. |
| 2 | Hard-coded `models=[claude-3-sonnet-20240229, claude-instant-v1, titan-text-express-v1]` | Runtime discovery via `pick_models()` + hard-pinned current IDs | Original list is outdated (see #7); discovery keeps the script runnable as models change. |
| 3 | Per-provider hand-built JSON body + `if "anthropic"/"amazon"` branching | Single `bedrock-runtime.converse(...)` call | Converse gives one uniform request/response shape across Claude, Nova, Titan, Llama — no per-provider code. |
| 4 | `token_count = len(output.split())` | Read `usage.inputTokens` / `usage.outputTokens` from Converse response | Real token counts are required for the "cost per request" comparison; word count ≠ tokens. |
| 5 | `calculate_similarity()` referenced before definition | Defined before `evaluate_models()` uses it | Original would raise `NameError` at runtime. |
| 6 | Word-overlap "similarity" as quality metric | Kept as cheap baseline **but flagged**; upgrade path documented (Titan embeddings cosine or LLM-as-judge) | Word overlap is not a defensible measure of response quality; noted for the blog. |
| 7 | `amazon.titan-text-express-v1` | → `us.amazon.nova-lite-v1:0` | **Titan Text Express is retired** in acct <AWS_ACCOUNT_ID>/us-west-2 — only `titan-embed-*` models remain. Nova Lite is Amazon's current text-generation model. |
| 8 | `inferenceConfig={maxTokens, temperature:0.7, topP:0.9}` | Removed `topP`; send only `temperature` | Claude Sonnet 4.6 & Haiku 4.5 throw `ValidationException: temperature and top_p cannot both be specified`. Nova tolerates both, which silently reduced the first run to a single model. |

**Model mapping (original intent → current ID):**

| Assignment original | Role | Replacement (enabled in acct) |
|---|---|---|
| `anthropic.claude-3-sonnet-20240229-v1:0` | Strong Claude | `us.anthropic.claude-sonnet-4-6` |
| `anthropic.claude-instant-v1` | Fast/cheap Claude | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `amazon.titan-text-express-v1` | Amazon-native | `us.amazon.nova-lite-v1:0` |

**Key findings (blog-worthy):**
- **Titan Text Express fully retired** — the assignment's third model no longer exists on Bedrock; only Titan *embedding* models remain.
- **Anthropic requires inference-profile IDs** — `list-foundation-models` shows bare IDs (e.g. `anthropic.claude-sonnet-4-6`), but on-demand invocation needs the `us.`-prefixed inference-profile ID (`us.anthropic.claude-sonnet-4-6`), or Converse errors.
- **Provider inconsistency in inferenceConfig** — Nova accepts both `temperature` + `topP`; newer Claude rejects sending both. Sending only `temperature` is the portable choice.

**Artifacts produced:**
- `model_evaluation_results.csv` — raw per-model, per-question metrics
- `model_selection_strategy.json` — primary + fallback ranking (feeds Part 2 AppConfig)

**Validated run results (2026-09-12, us-west-2):**

| Model | Mean latency (s) | Similarity* | Mean tokens | Overall score |
|---|---|---|---|---|
| `us.amazon.nova-lite-v1:0` | 2.98 | 0.711 | 500 | 0.645 → **primary** |
| `us.anthropic.claude-haiku-4-5-20251001-v1:0` | 2.93 | 0.610 | 334 | 0.577 → fallback 1 |
| `us.anthropic.claude-sonnet-4-6` | 5.86 | 0.582 | 373 | 0.407 → fallback 2 |

*Similarity = naive word-overlap (see Change #6). This metric rewards longer,
keyword-dense answers, so Nova Lite — which emitted the full 500-token responses —
scores highest largely because it produced more words that overlap the ground
truth, NOT necessarily because its answers are better. Nova also hit the 500-token
cap on every question while the Claude models answered more concisely (334/373
tokens). Treat the ranking as a plumbing/latency validation, not a real quality
verdict. A defensible quality metric (Titan-embeddings cosine or LLM-as-judge)
would likely reorder these.

---

### Part 2 — Flexible Architecture for Dynamic Model Selection
**Files:** `task1/part2/lambda_function.py`, `deploy_part2.sh`, `teardown_part2.sh`
**Status:** ✅ Deployed & validated end-to-end (run 2026-09-12)

| # | Original (assignment) | Change | Why |
|---|---|---|---|
| P2-1 | Lambda uses `appconfig.get_configuration()` | AppConfig **data plane**: `appconfigdata.start_configuration_session()` + `get_latest_configuration()` | `get_configuration()` is deprecated; the data-plane two-step flow is the current API and needs no extra Lambda layer. |
| P2-2 | Per-provider hand-built JSON body + `if "anthropic"/"amazon"` branching | Single `bedrock-runtime.converse(...)` call | Uniform request/response across Claude, Nova, Llama — same rationale as Part 1 Change #3. |
| P2-3 | `inferenceConfig` with `temperature` + `topP` | Send only `temperature` | Claude Sonnet 4.6 / Haiku 4.5 reject both (ValidationException); carried over from Part 1 Change #8. |
| P2-4 | `boto3.client(...)` (no region) | Region pinned to `us-west-2` (env-overridable) | Guarantee correct region regardless of default profile. |
| P2-5 | Hard-coded `Application`/`Environment`/`Configuration` names in the Lambda | Read from environment variables | Same code works across environments without edits. |
| P2-A | Profile type `AWS.AppConfig.FeatureFlags` | `AWS.Freeform` | The content is freeform strategy JSON, not a feature-flag document; FeatureFlags enforces a schema and would reject `model_selection_strategy.json`. |
| P2-B | CLI steps reference an execution role that is never created | `deploy_part2.sh` creates `ai-assistant-lambda-role` with Bedrock + AppConfig data-plane permissions | Assignment's Lambda has no role to run under. |
| P2-C | No `lambda:add-permission` for API Gateway | Added resource-based permission for `apigateway.amazonaws.com` | Without it the endpoint returns 500 — API Gateway can't invoke the Lambda. |
| P2-D | `YOUR_APP_ID` / `YOUR_*_ID` placeholders pasted between commands | Script chains IDs automatically and writes them to `part2_resources.env` | Removes manual copy/paste; enables clean teardown. |
| P2-E | `Runtime: python3.9` | `python3.12` | 3.9 is EOL on Lambda. |
| P2-F | AppConfig content is a manual placeholder | Uploads `../part1/model_selection_strategy.json` | Chains Part 1's real output into Part 2 (primary + fallbacks). |

**Deploy / teardown:**
- `bash deploy_part2.sh` — creates IAM role → Lambda → AppConfig (app/env/profile/hosted version + deployment) → API Gateway; prints the `/prod/generate` endpoint and saves IDs to `part2_resources.env`.
- `bash teardown_part2.sh` — deletes everything using those saved IDs.
- All resources tagged `auto-delete=true`.

**Artifacts produced (at deploy time):**
- `part2_resources.env` — resource IDs (API, Lambda, AppConfig, role) for teardown
- API endpoint URL: `https://<api-id>.execute-api.us-west-2.amazonaws.com/prod/generate`

---

### Part 3 — Resilient System Design
**Files:** `task1/part3/state_machine.json`, `fallback_lambda.py`, `degradation_lambda.py`, `deploy_part3.sh`, `teardown_part3.sh`
**Status:** 🟢 Core deployed & validated end-to-end (run 2026-09-12) — cross-region + Route 53 still to come

**Validated resilience run (2026-09-12, us-west-2) via `test_resilience.sh` v2:**

| Test | Injected failure | Handler | `model_used` |
|---|---|---|---|
| 1 | none | PRIMARY | `us.amazon.nova-lite-v1:0` |
| 2 | primary throttled (reserved-concurrency=0) | FALLBACK | `FALLBACK:us.amazon.nova-lite-v1:0` |
| 3 | primary + fallback throttled | GRACEFUL DEGRADATION | `DEGRADED_SERVICE` |

All three SUCCEEDED. Tests 2 & 3 output showed `error.Error = Lambda.TooManyRequestsException`
captured in the `$.error` sub-field alongside the intact original `prompt` — confirming the
P3-13 `ResultPath` fix. Failure injection via Lambda reserved-concurrency=0 (see `test_resilience.sh`).

| # | Original (assignment) | Change | Why |
|---|---|---|---|
| P3-1 | Fallback Lambda hard-codes `amazon.titan-text-express-v1` | → `us.amazon.nova-lite-v1:0` (env-overridable) | Titan Text Express is retired in acct <AWS_ACCOUNT_ID>/us-west-2 (Part 1 finding #7); Nova Lite is the current Amazon text model and a proven-reliable choice. |
| P3-2 | Fallback uses raw `invoke_model` + hand-built Titan JSON | `bedrock-runtime.converse(...)` | Uniform API across providers; consistent with Parts 1–2. |
| P3-3 | `textGenerationConfig` with temperature + topP | Converse `inferenceConfig` with only `temperature` | Claude models reject both params; kept portable (Part 1 Change #8). |
| P3-4 | `boto3.client('bedrock-runtime')` (no region) | Region pinned to us-west-2 (env-overridable) | Correct region regardless of default profile. |
| P3-5 | Fallback error handling implicit | Explicit `raise` so Step Functions `Catch` routes to GracefulDegradation | Matches assignment intent; makes the state transition deterministic. |
| P3-6 | Degradation Lambda | Kept as-is (canned per-use-case responses, no Bedrock dep) + Content-Type header | This is the point of graceful degradation — no model dependency. |
| P3-7 | ASL references Lambdas but no Step Functions execution role is created | `deploy_part3.sh` creates `ai-assistant-sfn-role` scoped to invoke exactly the 3 Lambdas | Assignment never creates the SFN role; state machine can't invoke Lambdas without it. |
| P3-8 | ASL uses `${PrimaryModelLambdaArn}` etc. placeholder tokens | Script substitutes the REAL deployed Lambda ARNs (incl. Part 2's primary) via `sed` | Placeholders aren't resolved by Step Functions; must be concrete ARNs. |
| P3-9 | `Runtime: python3.9` | `python3.12` | 3.9 is EOL on Lambda. |
| P3-10 | State machine described as "circuit breaker" | Implemented as retry-with-fallback + graceful degradation; documented that it is NOT a true circuit breaker | Honest for the blog: there's no shared state tracking "primary is currently failing" — it's per-request retry+fallback. A real breaker would need e.g. DynamoDB state. |
| P3-E | (n/a) | `deploy_part3.sh` writes `part3_resources.env`; `teardown_part3.sh` reads it | Clean, dependency-ordered teardown; leaves Part 2 intact. |
| P3-11 | Primary Lambda reads payload only from `event["body"]` (API Gateway shape) | Accept BOTH shapes: `event["body"]` (API Gateway) AND the raw event (direct/Step Functions) | Step Functions invokes Lambda directly with no `body` wrapper → prompt arrived blank → Bedrock `ValidationException: text field ... is blank`. Surfaced only when the SFN happy path ran. |
| P3-12 | `invoke_model` catches Bedrock errors and returns them as a normal 200 string | `invoke_model` raises; handler returns HTTP 500 for API Gateway but RE-RAISES for Step Functions | Error-swallowing meant the primary always "succeeded" (200) even when Bedrock failed, so the SFN `Catch`/fallback chain could NEVER fire. Raising makes the resilience path reachable — the whole point of Part 3. |
| P3-13 | Catch clauses had no `ResultPath`; states pass `Payload{prompt.$:$.prompt,...}` | Added `"ResultPath":"$.error"` to every Catch and `"ResultPath":"$.result"` to each task | When a Catch fires, Step Functions REPLACES the state input with the error object. Without `ResultPath`, the next state's `$.prompt` no longer exists → terminal, uncatchable `States.Runtime` error → whole execution FAILED instead of falling back. Tucking the error into `$.error` preserves the original `prompt`/`use_case` so fallback + degradation can read them. |
| P3-14 (test harness) | v1 `test_resilience.sh` only queried `output` | v2 reads `status`; on failure dumps `error`, `cause`, and last 8 history events | A FAILED execution has null `output`; the reason lives in `error`/`cause`. v1 showed "raw: None / UNKNOWN", hiding the actual failure (the P3-13 bug). |
| P3-15 (tooling) | Manual multi-line render+`update-state-machine` relied on shell vars being set in-session | `update_state_machine.sh` resolves ARNs itself, HARD-FAILS on any empty ARN, and greps the rendered ASL for leftover `${...}` tokens / empty `FunctionName` before deploying | When the manual vars were empty, `sed` produced `"FunctionName": ""` → runtime `Lambda.SdkClientException: FunctionName cannot be empty` on every task. The script makes an empty deploy impossible. |
| P3-16 | Cross-region Lambda would read model config from us-west-2 AppConfig | Secondary-region Lambda reads model from an ENV VAR (`PRIMARY_MODEL`) — self-contained per region | Pointing the HA region at the primary region's AppConfig creates a single-region dependency, defeating cross-region failover. Each region must stand alone. |
| P3-17 | CFN template Lambda body was `pass` (placeholder) | Real handler: Converse API, no topP, dual invocation shape (P3-11), per-source error handling (P3-12) | The assignment's template deploys a no-op Lambda; replaced with working code consistent with Parts 1–3. |
| P3-18 | CFN `Runtime: python3.9` | `python3.12` | 3.9 is EOL on Lambda. |
| P3-19 | CFN cross-region template had no `AWS::Lambda::Permission` for API Gateway | Added the permission resource | Without it the secondary endpoint returns 500 (same class of bug as P2-C, here in the CFN path). |
| P3-20 | Assignment deploys the SAME stack to us-east-1 AND us-west-2 | Deploy CFN to us-east-1 ONLY; us-west-2 keeps the Part 2 CLI endpoint as PRIMARY | Avoids a name collision with the already-deployed Part 2 resources in us-west-2; still yields two comparable regional endpoints for failover. |

**Cross-region files:** `template.yaml`, `deploy_crossregion.sh`, `teardown_crossregion.sh`
**Status (cross-region sub-step):** 🟢 Deployed & validated end-to-end (run 2026-09-12)
- Primary endpoint (us-west-2, Part 2): `https://mtipvxmr4k.execute-api.us-west-2.amazonaws.com/prod/generate`
- Secondary endpoint (us-east-1, CFN): `https://95wrutetrf.execute-api.us-east-1.amazonaws.com/prod/generate` — smoke test returned `model_used=us.amazon.nova-lite-v1:0` ✅
- ⚠️ Bedrock model access is per-region — `us.amazon.nova-lite-v1:0` must also be enabled in us-east-1.
- Stack-level tag `auto-delete=true`; teardown = one `delete-stack`.

#### Route 53 failover sub-step (`task1/part3/failover/`)
**Files:** `README_failover.md`, `r53_01_health.sh`, `r53_02_certs.sh`, `r53_03_custom_domains.sh`, `r53_04_failover_records.sh`, `r53_teardown.sh` (+ `/health` added to `template.yaml`)
**Status:** ✅ Deployed & validated end-to-end incl. failover drill (run 2026-09-12)
**Target hostname:** `https://aws.lijeron.net/generate` (PRIMARY us-west-2 → SECONDARY us-east-1)

**Deployed resources (2026-09-12):**
- ACM certs (ISSUED): us-west-2 `4c2b1ca0-…`, us-east-1 `2a410ea3-…` (shared validation CNAME `_dd9fbd58….aws.lijeron.net`)
- Custom domain targets: PRIMARY `d-4bqcnjl475.execute-api.us-west-2.amazonaws.com`, SECONDARY `d-yd3ay5wa1e.execute-api.us-east-1.amazonaws.com`
- Route 53 health check `470091cb-7b85-4264-948e-32f8f3ae252f` on primary `/prod/health`
- Failover A-alias records for `aws.lijeron.net` (PRIMARY→us-west-2 w/ health check, SECONDARY→us-east-1)
- ✅ Happy path: `curl https://aws.lijeron.net/generate` returned `model_used=us.amazon.nova-lite-v1:0` (served from us-west-2 PRIMARY)
- ✅ Failover drill: set health check resource-path to `/prod/nonexistent` → 403 across all checkers → PRIMARY Unhealthy. `dig aws.lijeron.net` shifted to us-east-1 IPs (3.221.81.106, 98.85.39.137, 100.56.76.46) and `curl https://aws.lijeron.net/generate` still returned a clean answer — traffic transparently served from us-east-1 SECONDARY. Restored with `--resource-path /prod/health`.
- ⚠️ Limitation (blog): DNS failover is TTL-bound — an already-resolved client may keep hitting the old region until the record TTL expires; not instantaneous.

| # | Original (assignment) | Change | Why |
|---|---|---|---|
| P3-R1 | Failover A-alias records point directly at the `execute-api` endpoints | Front each regional API with an **API Gateway custom domain** (`aws.lijeron.net`) + **regional ACM cert**, then alias the failover records at the custom-domain targets | A raw `execute-api` endpoint rejects a foreign `Host: aws.lijeron.net` header with 403; you cannot alias your own domain straight at it. Custom domain + cert is required. |
| P3-R2 | Health check implied against the app endpoint | Added a dedicated `GET /health` (MOCK 200) in BOTH regions and health-check that | Route 53 health checks issue GET/HEAD; a body-less `POST /generate` sends an empty prompt → Bedrock error → the check would flap. |
| P3-R3 | Single cert / single region assumption | **Two regional ACM certs** (one per region), DNS-validated via the `aws.lijeron.net` zone | API Gateway regional custom domains require a cert in the SAME region; us-east-1 and us-west-2 each need their own. |
| P3-R4 | (n/a) | Staged, idempotent scripts that hard-fail on empty targets + wait on ACM validation | Same discipline as P3-15: never deploy empty values; ACM issuance is async so steps must wait. |
| P3-21 | CFN template had no `/health`; single `ApiDeployment` | Added `HealthResource`/`HealthMethod` (MOCK 200) and bumped the deployment logical id (`ApiDeployment`→`ApiDeploymentV2`) | A new method isn't published to the stage unless the `AWS::ApiGateway::Deployment` logical id changes; without the bump `/health` would be absent from the live us-east-1 stage. |

**Deploy order:** `r53_01_health.sh` (us-west-2 /health) → re-run `deploy_crossregion.sh` (us-east-1 /health) → `r53_02_certs.sh` (waits for ISSUED) → `r53_03_custom_domains.sh` → `r53_04_failover_records.sh` → test at `https://aws.lijeron.net/generate`.
**Cost:** ACM certs free; **Route 53 health check ~$0.50/mo** (only idle cost); delete via `r53_teardown.sh`.

**Architecture:** primary (Part 2 `ai-assistant-model-abstraction`) → on failure retry (2×, backoff) → fallback Lambda (`us.amazon.nova-lite-v1:0`) → on failure → graceful degradation (canned response). All tagged `auto-delete=true`.

**Still to come in Part 3 (not yet built):**
- Cross-region deploy (CloudFormation) to us-east-1 + us-west-2.
- Route 53 failover on `aws.lijeron.net` (subdomain delegation to work account ✅ done; needs two live regional endpoints first).

**DNS foundation (prep for Route 53 step):**
- Parent `lijeron.net` (personal account) → Route 53 zone, Squarespace pointed at its 4 AWS nameservers ✅
- Subdomain `aws.lijeron.net` (work account <AWS_ACCOUNT_ID>) → zone created + delegated via NS record in parent ✅
- Dead zones to delete: `aws.carloslijeron.com` (Z05260642IHEBC6LBSNBK, expired parent), `aws.lijeron.com` (Z0687935337TFK6BU71UU, typo)

---

### Part 4 — Model Customization & Lifecycle Management
**Files:** `task1/part4/prepare_dataset.py`, `train.py`, `launch_training.py`, `teardown_part4.sh`
**Status:** 🟢 Step 1 (fine-tune) deployed & validated (run 2026-09-12); Steps 2–3 (versioning, rollback) to come

**Validated training run (2026-09-12, us-west-2):**
- Job: `ai-assistant-finetune-2026-09-12-20-10-45-580` — Completed; 164 billable seconds on `ml.m5.xlarge` (CPU)
- Model artifact: `s3://sagemaker-us-west-2-<AWS_ACCOUNT_ID>/ai-assistant-finetune-2026-09-12-20-10-45-580/output/model.tar.gz`
- `part4_training.env` written (MODEL_DATA / ROLE_ARN / TRAINING_JOB) for Step 2 registration
- Estimator: PyTorch 1.13.1/py39 CPU DLC + `requirements.txt` (transformers 4.26.1, datasets 2.10.1) — per P4-14

| # | Original (assignment) | Change | Why |
|---|---|---|---|
| P4-1 | Dataset has 2 stub rows | Expanded to 8 real financial Q&A pairs | 2 rows can't fine-tune anything; still lab-scale but runs. |
| P4-2 | `train.py` is TRUNCATED mid-line (`return tokenizer(examples`) | Completed the tokenize fn + full training loop | Assignment code is literally unfinished and won't run. |
| P4-3 | No pad token set | `tokenizer.pad_token = tokenizer.eos_token` | distilgpt2 has no pad token; tokenization with padding crashes without it. |
| P4-4 | No `labels` for causal LM | `DataCollatorForLanguageModeling(mlm=False)` supplies labels | Trainer errors without labels; collator copies input_ids→labels. |
| P4-5 | (n/a) | `TrainingArguments(report_to="none")` | Prevents the container from trying to init W&B/loggers and hanging. |
| P4-6 | Saves model only | Save model AND tokenizer to `SM_MODEL_DIR` | Self-contained artifact for later deployment. |
| P4-7 | Hard-coded epochs | `--epochs` hyperparameter (default 3) | Configurable without editing the script. |
| P4-8 | No estimator / `.fit()` shown at all | Added full `sagemaker.huggingface.HuggingFace` estimator + `fit()` in `launch_training.py` | The assignment writes train.py but never submits it — the job never runs. |
| P4-9 | (implied GPU) | `ml.m5.xlarge` (CPU) | distilgpt2 on 8 rows trains in ~minutes on CPU and AVOIDS the GPU training-quota wall fresh accounts hit (ml.g* quota often 0). |
| P4-10 | Assumes an execution role exists | `launch_training.py` creates `ai-assistant-sagemaker-role` if none supplied | Assignment references a role it never creates. |
| P4-11 | (n/a) | Pinned HF DLC versions (transformers 4.36 / pytorch 2.1 / py310) | Reproducible container; adjust if the combo isn't available in-region. |
| P4-12 | `pip install sagemaker` (unpinned) | Pin `sagemaker>=2.220,<3` | Unpinned install now pulls SDK **v3.x**, which restructured the package into a namespace layout and REMOVED the v2 `sagemaker.huggingface.HuggingFace` estimator path (and top-level `__version__`) → `ModuleNotFoundError: No module named 'sagemaker.huggingface'`. The assignment (and most SageMaker training tutorials) assume the v2 API, so pin v2. Note: leftover v3 sub-packages (`sagemaker-mlops`/`-train`/`-serve`) may print non-fatal pip dependency-conflict warnings; they're unused by the v2 estimator workflow and can be uninstalled. |
| P4-13 | HF DLC `transformers 4.36 / pytorch 2.1 / py310` on a CPU instance | Pin `transformers 4.26.0 / pytorch 1.13.1 / py39` (CPU-capable DLC) | The 4.36/2.1 DLC is **GPU-only** — with `ml.m5.xlarge` (CPU) the SDK raises `ValueError: Unsupported processor: cpu. Supported processor(s): gpu.` The older 4.26/1.13 DLC ships a CPU training image, which keeps distilgpt2 on CPU and avoids the GPU training-quota wall (ties to P4-9). |
| P4-14 | **Supersedes P4-11/P4-13.** Use the HuggingFace estimator at all | Switch to the generic **PyTorch estimator** (`sagemaker.pytorch.PyTorch`, framework 1.13.1/py39) + a `requirements.txt` (transformers/datasets) in `source_dir` | The HuggingFace training DLC is **GPU-only for EVERY version** (both 4.36/2.1 and 4.26/1.13 resolved GPU-only → `Unsupported processor: cpu`). Pinning HF versions can't fix it. The generic PyTorch training DLC **does** ship CPU images; SageMaker auto-installs `requirements.txt` into the container before `train.py` runs, so transformers/datasets are available on CPU. `train.py` itself is unchanged. |

**Deploy order:** `python prepare_dataset.py` → `python launch_training.py` (creates role, uploads data, runs job, writes `part4_training.env`).
**⚠️ COST — the important one:** training jobs bill per-second only while running (minutes here). A SageMaker **inference endpoint** (Steps 2–3) bills PER HOUR continuously until deleted — this is the biggest idle-cost risk in the whole module. `teardown_part4.sh` deletes endpoint + config + model + role. Delete endpoints as soon as testing is done.

**Still to come in Part 4 (not yet built):** Step 2 model versioning/registration (SageMaker Model Registry), Step 3 automated testing + rollback workflow.

#### Step 2 — Model versioning (`register_model.py`) & Step 3 — deploy/test/rollback (`deploy_test_rollback.py`)
**Status:** Step 2 🟢 validated (run 2026-09-12) · Step 3 🟡 deploy pending

**Step 3 validated (run 2026-09-12):** repackaged v2 (with `code/inference.py`) → deployed to `ai-assistant-finetuned-endpoint` → automated smoke test returned a real `generated_text` completion → **PASS** → endpoint auto-deleted (`deleted endpoint` / `deleted endpoint-config`). Versioning demonstrated: v1 (no handler, ReadTimeout) → v2 (handler, working). Endpoint lifetime bounded to the test; no cost leak.

**Validated Step 2 run (2026-09-12):** registered `ai-assistant-finetuned-models/1` → **Approved**; inference image `pytorch-inference:1.13.1-cpu-py39`; `part4_registry.env` written with `LATEST_PACKAGE_ARN`.

| # | Original (assignment) | Change | Why |
|---|---|---|---|
| P4-15 | "model versioning and deployment workflows" — no code | SageMaker **Model Registry**: Model Package Group + versioned packages with approval status (PendingManualApproval→Approved) | Standard AWS versioning/lifecycle primitive; re-running registers v1, v2, … |
| P4-16 | (n/a) | Reads `MODEL_DATA`/`ROLE_ARN` from `part4_training.env` | Registered version points at the exact Step 1 artifact. |
| P4-17 | (n/a) | PyTorch **inference** image (1.13.1/py39) in the package container def | Registered version is deployable as-is in Step 3. |
| P4-18 | "automated testing and rollback strategies" — no code | `deploy_test_rollback.py`: deploy approved package → automated smoke test → keep or rollback → guaranteed teardown | Implements the lifecycle the assignment only describes. |
| P4-19 | (n/a) | Endpoint teardown in `finally` + `atexit` guard; `KEEP_ENDPOINT=1` opts out | A real-time endpoint bills **per hour**; this guarantees it can't be left running by an exception/interrupt — the biggest cost risk in the module. |
| P4-20 | (n/a) | "Rollback" = on test failure, delete the just-deployed endpoint so the previous approved version keeps serving | Honest scoping: this is fail-safe-on-promote, not a blue/green traffic shift (which needs two live endpoints). |
| P4-21 | `create_model_package(..., Tags=TAG)` | Dropped `Tags` from the model-package (version) call; keep tags only on the Model Package Group | `CreateModelPackage` raises `ValidationException: Tags are not supported in Model Package versions. Please add them to the Model Package Group.` The group is already tagged at creation, so the version inherits governance via the group. |
| P4-22 | `smoke_test()` let an invoke exception propagate and crash the harness | Wrap the invoke in try/except → return `False` on ANY failure; add a 30s read timeout, no retries | An automated test must treat "invoke threw/timed out" as a FAILED test that triggers rollback — not a crash. The v1 endpoint's ReadTimeout crashed the script (though the `finally`/`atexit` teardown still deleted the endpoint first — no cost leak). |
| P4-23 | Registered/deployed the raw training artifact with no serving code | Add `code/inference.py` (model_fn/input_fn/predict_fn/output_fn) + `code/requirements.txt` inside the tarball; `repackage_with_inference.py` injects them and registers a v2 | The PyTorch inference DLC's default handler can't load a HuggingFace CausalLM, so `invoke_endpoint` hung until `ReadTimeout`. A custom handler is required to serve distilgpt2. Bonus: this exercises the Step 2 versioning path (v1 broken → v2 working). |

**Run order:** `python register_model.py` (versioning — near-zero cost, safe to leave) → `python deploy_test_rollback.py` (spins up a real endpoint, tests, tears it down immediately).
**⚠️ Cost:** Model Registry entries are free. The endpoint in Step 3 bills per hour but only lives for the duration of the test (auto-deleted). `teardown_part4.sh` is the backstop.

---

## Resource tagging & cleanup
All persistent AWS resources are tagged **`auto-delete=true`** for temporary lab use.
Cleanup approach: deploy via CloudFormation where possible and `delete-stack` to tear
down; use Resource Groups → Tag Editor (tag `auto-delete=true`, region us-west-2) to
sweep up any manually-created leftovers.

## Cost guardrails
- Billing budget/alert configured to avoid unexpected charges.
- ⚠️ Watch SageMaker inference endpoints (Part 4) — they bill per hour while running.
- ⚠️ Route 53 health checks (Part 3) bill monthly — delete explicitly.
