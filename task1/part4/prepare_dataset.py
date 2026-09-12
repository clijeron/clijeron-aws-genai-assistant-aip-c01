"""
Part 4 — Step 1a: Prepare the fine-tuning dataset
=================================================

Creates financial_qa_dataset.csv — a small financial-domain Q&A set used to
fine-tune distilgpt2 via SageMaker (Part 4, Step 1 of the assignment).

------------------------------------------------------------------------------
WHAT CHANGED vs. THE ORIGINAL ASSIGNMENT (blog changelog)
------------------------------------------------------------------------------
P4-1. Expanded the dataset from the assignment's 2 stub rows to a handful of
      real financial Q&A pairs. A 2-row dataset can't fine-tune anything
      meaningful; this is still tiny (lab-scale) but produces a running job.
------------------------------------------------------------------------------
"""

import pandas as pd

data = [
    {"question": "What is a 401(k)?",
     "answer": "A 401(k) is a tax-advantaged retirement savings plan offered by employers in which employees contribute pre-tax income, often with an employer match."},
    {"question": "How does compound interest work?",
     "answer": "Compound interest is interest earned on both the original principal and previously accumulated interest, so balances grow faster over time."},
    {"question": "What is the difference between a Roth IRA and a traditional IRA?",
     "answer": "A Roth IRA is funded with after-tax dollars and grows tax-free, while a traditional IRA is funded pre-tax and is taxed at withdrawal."},
    {"question": "What is diversification?",
     "answer": "Diversification is spreading investments across different assets to reduce the risk that any single holding hurts the overall portfolio."},
    {"question": "What is an index fund?",
     "answer": "An index fund is a pooled investment that tracks a market index like the S&P 500, offering broad exposure at low cost."},
    {"question": "What is an emergency fund?",
     "answer": "An emergency fund is cash set aside — typically three to six months of expenses — to cover unexpected costs without borrowing."},
    {"question": "What is dollar-cost averaging?",
     "answer": "Dollar-cost averaging is investing a fixed amount at regular intervals regardless of price, smoothing out the effect of market volatility."},
    {"question": "What is a credit score?",
     "answer": "A credit score is a number summarizing a person's creditworthiness based on their credit history, used by lenders to assess risk."},
]

if __name__ == "__main__":
    df = pd.DataFrame(data)
    df.to_csv("financial_qa_dataset.csv", index=False)
    print(f"Wrote financial_qa_dataset.csv with {len(df)} rows")
    print(df.head())
