"""
Part 4 — Custom inference handler for the fine-tuned distilgpt2 model
====================================================================

Placed inside the model artifact as code/inference.py. The SageMaker PyTorch
INFERENCE container calls these functions to load and run the model. Without
this file the container has no idea how to load a raw transformers model, so
invocations hang until timeout (the ReadTimeout you saw).

------------------------------------------------------------------------------
WHY THIS IS NEEDED (blog changelog — P4-23)
------------------------------------------------------------------------------
The assignment registers/deploys the raw training artifact with NO inference
code. The PyTorch DLC's default handler can't load a HuggingFace CausalLM, so
`invoke_endpoint` never gets a response -> ReadTimeout. A custom handler
(model_fn / input_fn / predict_fn / output_fn) is required to serve it.
------------------------------------------------------------------------------
"""

import os
import json
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer


def model_fn(model_dir):
    """Load the fine-tuned model + tokenizer from the extracted artifact."""
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForCausalLM.from_pretrained(model_dir)
    model.eval()
    return {"model": model, "tokenizer": tokenizer}


def input_fn(request_body, content_type="application/json"):
    if content_type == "application/json":
        data = json.loads(request_body)
        return data.get("inputs", data.get("prompt", ""))
    raise ValueError(f"Unsupported content type: {content_type}")


def predict_fn(prompt, ctx):
    tokenizer, model = ctx["tokenizer"], ctx["model"]
    inputs = tokenizer(prompt, return_tensors="pt")
    with torch.no_grad():
        out = model.generate(
            **inputs,
            max_new_tokens=80,
            do_sample=True,
            temperature=0.7,
            pad_token_id=tokenizer.eos_token_id,
        )
    text = tokenizer.decode(out[0], skip_special_tokens=True)
    return {"generated_text": text}


def output_fn(prediction, accept="application/json"):
    return json.dumps(prediction), "application/json"
