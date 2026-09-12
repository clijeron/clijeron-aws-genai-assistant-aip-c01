"""
Part 4 — Step 1b: SageMaker training script (distilgpt2 fine-tune)
==================================================================

Runs INSIDE the SageMaker HuggingFace training container. Reads the financial
Q&A CSV from the training channel, fine-tunes distilgpt2, and saves the model
to SM_MODEL_DIR (which SageMaker uploads to S3 as model.tar.gz).

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
P4-2. The assignment's train.py is TRUNCATED mid-line (ends at
      `return tokenizer(examples`). Completed the tokenize function and the
      whole training loop.
P4-3. distilgpt2 has NO pad token; the assignment's code would crash on
      tokenization with padding. Set tokenizer.pad_token = eos_token.
P4-4. Causal-LM training needs `labels`. The assignment never set them →
      Trainer would error. We copy input_ids to labels.
P4-5. Added TrainingArguments(report_to="none") to avoid the container trying
      to init W&B / other loggers and hanging on credentials.
P4-6. Save BOTH model and tokenizer to args.model_dir so the artifact is
      self-contained for later deployment.
P4-7. Added --epochs hyperparameter (default 3) instead of a hard-coded value.
------------------------------------------------------------------------------
"""

import argparse
import os
import pandas as pd
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    Trainer,
    TrainingArguments,
    DataCollatorForLanguageModeling,
)
from datasets import Dataset


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=str, default=os.environ.get("SM_MODEL_DIR", "/opt/ml/model"))
    parser.add_argument("--training-dir", type=str, default=os.environ.get("SM_CHANNEL_TRAINING", "/opt/ml/input/data/training"))
    parser.add_argument("--epochs", type=int, default=3)  # P4-7
    parser.add_argument("--model-name", type=str, default="distilgpt2")
    return parser.parse_args()


def main():
    args = parse_args()

    # Load dataset from the training channel.
    data_path = os.path.join(args.training_dir, "financial_qa_dataset.csv")
    df = pd.read_csv(data_path)

    def format_instruction(row):
        return f"Question: {row['question']}\nAnswer: {row['answer']}"

    df["text"] = df.apply(format_instruction, axis=1)
    dataset = Dataset.from_pandas(df[["text"]])

    # Model + tokenizer.
    tokenizer = AutoTokenizer.from_pretrained(args.model_name)
    tokenizer.pad_token = tokenizer.eos_token          # P4-3: distilgpt2 has no pad token
    model = AutoModelForCausalLM.from_pretrained(args.model_name)

    # P4-2: completed tokenize function.
    def tokenize_function(examples):
        return tokenizer(examples["text"], truncation=True, padding="max_length", max_length=128)

    tokenized = dataset.map(tokenize_function, batched=True, remove_columns=["text"])

    # P4-4: causal-LM labels via the standard data collator (mlm=False copies
    # input_ids to labels at batch time).
    collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)

    training_args = TrainingArguments(
        output_dir="/opt/ml/output",
        num_train_epochs=args.epochs,
        per_device_train_batch_size=2,
        logging_steps=10,
        save_strategy="no",
        report_to="none",                              # P4-5
    )

    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized,
        data_collator=collator,
    )
    trainer.train()

    # P4-6: persist a self-contained artifact.
    trainer.save_model(args.model_dir)
    tokenizer.save_pretrained(args.model_dir)
    print(f"Saved fine-tuned model + tokenizer to {args.model_dir}")


if __name__ == "__main__":
    main()
