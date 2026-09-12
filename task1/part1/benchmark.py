"""
Part 1 — Foundation Model Assessment & Benchmarking
===================================================

Adapted from the AWS Exam Prep bonus assignment. This script benchmarks
multiple Amazon Bedrock models on a set of financial-domain test cases and
produces two artifacts consumed by later parts:

    model_evaluation_results.csv   - raw per-model, per-question metrics
    model_selection_strategy.json  - primary + fallback ranking (feeds Part 2 AppConfig)

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
1. Region is now pinned to us-west-2 on every boto3 client. The original
   created `boto3.client('bedrock-runtime')` with no region, which silently
   uses whatever the default profile points at.

2. Model IDs are DISCOVERED at runtime instead of hard-coded. The original
   list (claude-3-sonnet-20240229, claude-instant-v1, titan-text-express-v1)
   is outdated: claude-instant-v1 is retired, and Anthropic models on Bedrock
   now generally require an inference-profile ID (the 'us.' prefixed IDs)
   rather than a bare on-demand model ID, otherwise InvokeModel raises a
   ValidationException. See pick_models() below.

3. A single Converse API call (bedrock-runtime.converse) replaces the
   per-provider hand-built JSON bodies and the `if "anthropic" in model_id`
   branching. Converse gives one uniform request/response shape across
   Claude, Titan, Nova, Llama, etc.

4. Real token counts are read from the Converse `usage` block
   (inputTokens / outputTokens) instead of `len(output.split())`. This is
   what the scenario's "cost per request" comparison actually needs.

5. calculate_similarity() is defined BEFORE evaluate_models() uses it. In the
   original it was referenced before definition, which throws NameError.

6. The word-overlap similarity is KEPT as a cheap baseline but clearly flagged.
   It is not a defensible "response quality" metric. See the note in
   calculate_similarity() for the recommended upgrade (Titan embeddings cosine
   or LLM-as-judge).
------------------------------------------------------------------------------
"""

import boto3
import json
import time
import pandas as pd
from concurrent.futures import ThreadPoolExecutor  # kept from original; used optionally

REGION = "us-west-2"

# One runtime client for invocation, one control-plane client for discovery.
bedrock_runtime = boto3.client("bedrock-runtime", region_name=REGION)
bedrock_control = boto3.client("bedrock", region_name=REGION)


# ---------------------------------------------------------------------------
# Model selection
# ---------------------------------------------------------------------------
# CHANGE #2: Instead of a hard-coded (and now-outdated) list, discover what is
# actually callable in THIS account/region. You can override MODELS manually
# with IDs from:
#     aws bedrock list-inference-profiles --region us-west-2
# If you already know your IDs, just set MODELS = [...] and skip discovery.
# Hard-pinned to IDs confirmed enabled in account <AWS_ACCOUNT_ID> / us-west-2
# on 2026-09-12 (via `aws bedrock list-inference-profiles`). These preserve the
# assignment's original intent — a strong model, a fast/cheap model, and an
# Amazon-native model — with current IDs:
#
#   assignment original                     -> replacement (reason)
#   anthropic.claude-3-sonnet-20240229-v1:0 -> us.anthropic.claude-sonnet-4-6
#                                              (current flagship Sonnet)
#   anthropic.claude-instant-v1             -> us.anthropic.claude-haiku-4-5-20251001-v1:0
#                                              (Claude Instant retired; Haiku 4.5 = current fast tier)
#   amazon.titan-text-express-v1            -> us.amazon.nova-lite-v1:0
#                                              (Titan Text Express RETIRED in this account -
#                                               only titan-embed-* remain; Nova Lite is
#                                               Amazon's current text-generation model)
#
# All three are inference-profile IDs (the 'us.' prefix) — what Converse expects
# for on-demand throughput. Set MODELS = [] to fall back to auto-discovery.
MODELS = [
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.amazon.nova-lite-v1:0",
]


def pick_models(max_models=3):
    """Discover a small, diverse set of callable model IDs in us-west-2.

    Preference order:
      1. Inference profiles (the 'us.' IDs Anthropic/Nova now require for
         on-demand throughput). These are what Converse expects.
      2. Fall back to foundation-model IDs that support ON_DEMAND + TEXT output
         (e.g. Titan), for models that don't need a profile.
    """
    chosen = []

    # 1. Inference profiles first (covers Anthropic + Nova cleanly)
    try:
        profiles = bedrock_control.list_inference_profiles().get(
            "inferenceProfileSummaries", []
        )
        for p in profiles:
            pid = p.get("inferenceProfileId", "")
            # prefer a claude and a nova profile for variety
            if any(k in pid for k in ("claude", "nova")):
                chosen.append(pid)
    except Exception as e:
        print(f"[discover] list_inference_profiles failed: {e}")

    # 2. Add a foundation model that works by bare ID (Titan) for contrast
    try:
        fms = bedrock_control.list_foundation_models(
            byOutputModality="TEXT", byInferenceType="ON_DEMAND"
        ).get("modelSummaries", [])
        for m in fms:
            mid = m.get("modelId", "")
            if "titan-text" in mid and mid not in chosen:
                chosen.append(mid)
                break
    except Exception as e:
        print(f"[discover] list_foundation_models failed: {e}")

    # de-dupe, keep order, cap
    seen, out = set(), []
    for mid in chosen:
        if mid not in seen:
            seen.add(mid)
            out.append(mid)
    return out[:max_models]


# ---------------------------------------------------------------------------
# Test cases (unchanged from the assignment; add more as needed)
# ---------------------------------------------------------------------------
test_cases = [
    {
        "question": "What is a 401(k) retirement plan?",
        "context": "Financial services",
        "ground_truth": "A 401(k) is a tax-advantaged retirement savings plan offered by employers.",
    },
    {
        "question": "How does compound interest work?",
        "context": "Financial services",
        "ground_truth": "Compound interest is interest earned on both the principal and previously accumulated interest.",
    },
    {
        "question": "What is the difference between a Roth IRA and a traditional IRA?",
        "context": "Financial services",
        "ground_truth": "A Roth IRA is funded with after-tax dollars and grows tax-free; a traditional IRA is funded pre-tax and taxed at withdrawal.",
    },
    # Add more test cases...
]


# ---------------------------------------------------------------------------
# CHANGE #5/#6: define similarity BEFORE it is used.
# ---------------------------------------------------------------------------
def calculate_similarity(output, ground_truth):
    """Word-overlap similarity between output and ground truth.

    NOTE (blog): this is a deliberately simple baseline kept from the original
    assignment. It is NOT a defensible measure of response quality. For the
    'response quality' criterion in the scenario, replace this with either:
      - cosine similarity over Bedrock Titan embeddings
        (amazon.titan-embed-text-v2:0), or
      - an LLM-as-judge score (ask a strong model to rate 1-5 vs ground truth).
    """
    output_words = set(output.lower().split())
    truth_words = set(ground_truth.lower().split())
    if not truth_words:
        return 0.0
    common_words = output_words.intersection(truth_words)
    return len(common_words) / len(truth_words)


# ---------------------------------------------------------------------------
# CHANGE #3/#4: one Converse call for all providers; real token counts.
# ---------------------------------------------------------------------------
def invoke_model(model_id, prompt, max_tokens=500):
    """Invoke a model via the Converse API and return the response + metrics.

    Converse normalizes the request/response across providers, so we no longer
    branch on 'anthropic' vs 'amazon'. Token counts and server-side latency
    come straight from the response.
    """
    start_time = time.time()
    try:
        response = bedrock_runtime.converse(
            modelId=model_id,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            # CHANGE #8: send ONLY temperature (dropped topP).
            # The newer Anthropic models (Claude Sonnet 4.6, Haiku 4.5) reject a
            # Converse call that specifies BOTH temperature and topP with:
            #   ValidationException: `temperature` and `top_p` cannot both be
            #   specified for this model. Please use only one.
            # Amazon Nova tolerates both, which is why the original run silently
            # dropped the two Claude models and "benchmarked" only Nova. Sending
            # just temperature works uniformly across Claude, Nova, Llama, etc.
            inferenceConfig={
                "maxTokens": max_tokens,
                "temperature": 0.7,
            },
        )
        output = response["output"]["message"]["content"][0]["text"]

        usage = response.get("usage", {})
        in_tok = usage.get("inputTokens")
        out_tok = usage.get("outputTokens")

        # Prefer Bedrock's server-side latency when present; else wall-clock.
        server_latency_ms = response.get("metrics", {}).get("latencyMs")
        latency = (server_latency_ms / 1000.0) if server_latency_ms else (time.time() - start_time)

        return {
            "success": True,
            "output": output,
            "latency": latency,
            "input_tokens": in_tok,
            "output_tokens": out_tok,
            "token_count": (out_tok if out_tok is not None else len(output.split())),
        }
    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "latency": time.time() - start_time,
        }


def evaluate_models():
    """Evaluate all models on all test cases and return a DataFrame."""
    results = []
    for test_case in test_cases:
        prompt = f"Question: {test_case['question']}\nContext: {test_case['context']}"
        for model_id in MODELS:
            print(f"Evaluating {model_id} on: {test_case['question']}")
            response = invoke_model(model_id, prompt)
            if response["success"]:
                similarity = calculate_similarity(response["output"], test_case["ground_truth"])
                results.append({
                    "model_id": model_id,
                    "question": test_case["question"],
                    "output": response["output"],
                    "latency": response["latency"],
                    "input_tokens": response.get("input_tokens"),
                    "output_tokens": response.get("output_tokens"),
                    "token_count": response["token_count"],
                    "similarity_score": similarity,
                })
            else:
                results.append({
                    "model_id": model_id,
                    "question": test_case["question"],
                    "error": response["error"],
                    "latency": response["latency"],
                })
    return pd.DataFrame(results)


def create_model_selection_strategy(results_df):
    """Rank models into primary + fallbacks based on the benchmark results.

    (This is Part 1, Step 2 from the assignment, unchanged in logic: 0.7 weight
    on similarity, 0.3 on normalized latency.)
    """
    model_scores = (
        results_df[results_df.get("similarity_score").notna()]
        .groupby("model_id")
        .agg({"latency": "mean", "similarity_score": "mean"})
        .reset_index()
    )
    max_latency = model_scores["latency"].max()
    model_scores["latency_score"] = 1 - (model_scores["latency"] / max_latency)
    model_scores["overall_score"] = (
        0.7 * model_scores["similarity_score"] + 0.3 * model_scores["latency_score"]
    )
    model_scores = model_scores.sort_values("overall_score", ascending=False)

    strategy = {
        "primary_model": model_scores.iloc[0]["model_id"],
        "fallback_models": model_scores.iloc[1:]["model_id"].tolist(),
        "model_scores": model_scores.to_dict(orient="records"),
    }
    return strategy


if __name__ == "__main__":
    # Resolve the model list: manual override wins, else auto-discover.
    if not MODELS:
        MODELS = pick_models()
    if not MODELS:
        raise SystemExit(
            "No callable models found. Run:\n"
            "  aws bedrock list-inference-profiles --region us-west-2\n"
            "and set MODELS=[...] at the top of this file, and confirm model "
            "access is granted in the Bedrock console (us-west-2)."
        )
    print("Models under test:", MODELS)

    results_df = evaluate_models()
    results_df.to_csv("model_evaluation_results.csv", index=False)

    print("\nEvaluation Summary:")
    summary = (
        results_df[results_df.get("similarity_score").notna()]
        .groupby("model_id")
        .agg({"latency": "mean", "similarity_score": "mean", "token_count": "mean"})
        .reset_index()
    )
    print(summary)

    strategy = create_model_selection_strategy(results_df)
    print("\nSelection strategy:")
    print(json.dumps(strategy, indent=2, default=str))

    with open("model_selection_strategy.json", "w") as f:
        json.dump(strategy, f, indent=2, default=str)
    print("\nWrote model_evaluation_results.csv and model_selection_strategy.json")
