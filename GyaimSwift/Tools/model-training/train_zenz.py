#!/usr/bin/env python3
"""Train a kana-kanji conversion model in the zenz-v3 format.

Per docs/specs/zenz-model-tuning.md, the SwiftyGyaim specialized model is
trained FROM THE ORIGINAL BASE MODEL (ku-nlp/gpt2-small-japanese-char),
not by continued SFT on zenz weights. Data format matches ZenzPrompt:

    <left_context><input_katakana><output></s>

with loss computed on the output span only (prompt tokens masked to -100),
following the published zenz recipe (NLP2025 P1-19).

Input JSONL rows: {"input": <katakana>, "output": <text>,
                   "left_context": <text or null>}
(zenz-v2.5-dataset schema; build_sft_dataset.py produces the same.)

Examples:

    # 10-example overfit smoke on MPS
    .venv/bin/python3 train_zenz.py --train smoke.jsonl --output out-smoke \
        --epochs 60 --smoke

    # real run
    .venv/bin/python3 train_zenz.py --train train.jsonl --valid valid.jsonl \
        --output out-v1 --epochs 1 --batch-size 32
"""

from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path

import torch
from torch.utils.data import Dataset
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    Trainer,
    TrainingArguments,
)

CONTEXT_TAG = "\uEE02"
INPUT_TAG = "\uEE00"
OUTPUT_TAG = "\uEE01"

DEFAULT_BASE = "ku-nlp/gpt2-small-japanese-char"


def build_prompt(row: dict) -> str:
    prompt = ""
    context = row.get("left_context")
    if context:
        prompt += CONTEXT_TAG + context
    prompt += INPUT_TAG + row["input"] + OUTPUT_TAG
    return prompt


class ZenzSFTDataset(Dataset):
    def __init__(self, path: Path, tokenizer, max_length: int) -> None:
        self.rows = []
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    self.rows.append(json.loads(line))
        self.tokenizer = tokenizer
        self.max_length = max_length

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict:
        row = self.rows[index]
        prompt_ids = self.tokenizer.encode(build_prompt(row), add_special_tokens=False)
        output_ids = self.tokenizer.encode(row["output"], add_special_tokens=False)
        output_ids = output_ids + [self.tokenizer.eos_token_id]
        input_ids = (prompt_ids + output_ids)[: self.max_length]
        # Output-only loss: mask the prompt span.
        labels = ([-100] * len(prompt_ids) + list(output_ids))[: self.max_length]
        return {
            "input_ids": torch.tensor(input_ids),
            "labels": torch.tensor(labels),
            "attention_mask": torch.ones(len(input_ids), dtype=torch.long),
        }


def collate(batch, pad_token_id: int):
    length = max(len(item["input_ids"]) for item in batch)

    def pad(tensor, value):
        return torch.cat([tensor, torch.full((length - len(tensor),), value, dtype=tensor.dtype)])

    return {
        "input_ids": torch.stack([pad(b["input_ids"], pad_token_id) for b in batch]),
        "labels": torch.stack([pad(b["labels"], -100) for b in batch]),
        "attention_mask": torch.stack([pad(b["attention_mask"], 0) for b in batch]),
    }


def pick_device() -> str:
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def greedy_decode(model, tokenizer, prompt: str, device: str, max_new_tokens: int = 64) -> str:
    ids = tokenizer.encode(prompt, add_special_tokens=False, return_tensors="pt").to(device)
    with torch.no_grad():
        out = model.generate(
            ids,
            max_new_tokens=max_new_tokens,
            do_sample=False,
            eos_token_id=tokenizer.eos_token_id,
            pad_token_id=tokenizer.eos_token_id,
        )
    return tokenizer.decode(out[0][ids.shape[1]:], skip_special_tokens=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-model", default=DEFAULT_BASE)
    parser.add_argument("--train", required=True, type=Path)
    parser.add_argument("--valid", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--epochs", type=float, default=1.0)
    parser.add_argument("--lr", type=float, default=5e-5)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--grad-accum", type=int, default=1)
    parser.add_argument("--max-length", type=int, default=256)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--save-steps", type=int, default=2000)
    parser.add_argument("--resume", action="store_true",
                        help="output配下の最新checkpointから学習を再開する")
    parser.add_argument("--smoke", action="store_true",
                        help="After training, greedy-decode every train row and report exact match.")
    args = parser.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = pick_device()
    print(f"device={device} base={args.base_model}")

    tokenizer = AutoTokenizer.from_pretrained(args.base_model)
    model = AutoModelForCausalLM.from_pretrained(args.base_model).to(device)

    train_ds = ZenzSFTDataset(args.train, tokenizer, args.max_length)
    valid_ds = ZenzSFTDataset(args.valid, tokenizer, args.max_length) if args.valid else None
    print(f"train={len(train_ds)} valid={len(valid_ds) if valid_ds else 0}")

    training_args = TrainingArguments(
        output_dir=str(args.output),
        num_train_epochs=args.epochs,
        learning_rate=args.lr,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.grad_accum,
        logging_steps=50,
        save_steps=args.save_steps,
        save_total_limit=2,
        eval_strategy="epoch" if valid_ds else "no",
        report_to=[],
        seed=args.seed,
        use_cpu=(device == "cpu"),
    )
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=train_ds,
        eval_dataset=valid_ds,
        data_collator=lambda batch: collate(batch, tokenizer.eos_token_id),
    )
    trainer.train(resume_from_checkpoint=True if args.resume else None)
    trainer.save_model(str(args.output / "final"))
    tokenizer.save_pretrained(str(args.output / "final"))

    if valid_ds:
        metrics = trainer.evaluate()
        print(f"valid loss={metrics['eval_loss']:.4f} ppl={math.exp(metrics['eval_loss']):.2f}")

    if args.smoke:
        model.eval()
        hits = 0
        for row in train_ds.rows:
            decoded = greedy_decode(model, tokenizer, build_prompt(row), device)
            ok = decoded == row["output"]
            hits += ok
            mark = "OK " if ok else "NG "
            print(f"{mark} input={row['input']} expected={row['output']} got={decoded}")
        print(f"smoke exact match: {hits}/{len(train_ds.rows)}")
        return 0 if hits == len(train_ds.rows) else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
