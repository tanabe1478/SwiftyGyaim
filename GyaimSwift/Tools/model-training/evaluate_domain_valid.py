#!/usr/bin/env python3
"""Greedy-decode a domain validation split and report exact-match accuracy.

The evaluator uses the same prompt builder as train_zenz.py.  It is intended
for the held-out domain-valid.jsonl rows that are never mixed into training.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from transformers import AutoModelForCausalLM, AutoTokenizer

from train_zenz import build_prompt, greedy_decode, pick_device


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--model",
        required=True,
        help="Hugging Face model ID or directory, for example runs/mixed-v1/final",
    )
    parser.add_argument("--data", type=Path, default=Path("data/domain-valid.jsonl"))
    parser.add_argument("--max-new-tokens", type=int, default=64)
    parser.add_argument("--json", action="store_true", help="Print a machine-readable summary")
    parser.add_argument("--show-misses", action="store_true")
    args = parser.parse_args()

    device = pick_device()
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(args.model).to(device)
    model.eval()

    rows = [json.loads(line) for line in args.data.read_text(encoding="utf-8").splitlines() if line]
    hits = 0
    misses = []
    for row in rows:
        predicted = greedy_decode(
            model,
            tokenizer,
            build_prompt(row),
            device,
            max_new_tokens=args.max_new_tokens,
        )
        expected = row["output"]
        if predicted == expected:
            hits += 1
        elif args.show_misses:
            misses.append({
                "input": row["input"],
                "left_context": row.get("left_context"),
                "expected": expected,
                "predicted": predicted,
            })

    total = len(rows)
    accuracy = hits / total if total else 0.0
    summary = {
        "model": str(args.model),
        "data": str(args.data),
        "device": device,
        "exact_match": hits,
        "total": total,
        "accuracy": accuracy,
    }
    if args.show_misses:
        summary["misses"] = misses

    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print(f"device={device} model={args.model}")
        print(f"domain exact match: {hits}/{total} ({accuracy:.1%})")
        for miss in misses:
            print(
                "NG "
                f"input={miss['input']} "
                f"expected={miss['expected']} "
                f"got={miss['predicted']}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
