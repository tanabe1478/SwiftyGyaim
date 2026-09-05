#!/usr/bin/env python3
"""Discrimination (rerank) evaluation on real candidate lists.

SwiftyGyaimでのモデルの本番の仕事は「生成」ではなく「辞書が出した候補
リストの中から文脈に合うものを上位にする判別」。この評価は dogfood ログ
から作った (context, input_katakana, candidates[], chosen) に対して、
本番と同じ条件付き平均logprobで候補を順位付けし、chosen が1位になる率を測る。

データ: data/rerank-valid.jsonl（domain-valid と同じ (読み,出力) 隔離
グループから構築。学習セットとのリークなし）

Usage:
    .venv/bin/python3 evaluate_rerank.py --model tanabe1478/gyaim-lm-small-public-v1
    .venv/bin/python3 evaluate_rerank.py --model runs/gyaim-lm-small-v2/final --show-misses
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

CONTEXT_TAG = "\uEE02"
INPUT_TAG = "\uEE00"
OUTPUT_TAG = "\uEE01"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--cases", type=Path, default=Path(__file__).parent / "data/rerank-valid.jsonl")
    parser.add_argument("--show-misses", action="store_true")
    args = parser.parse_args()

    cases = [json.loads(l) for l in open(args.cases, encoding="utf-8")]
    device = "cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(args.model).to(device).eval()

    hits = 0
    for case in cases:
        prompt = ""
        if case.get("context"):
            prompt += CONTEXT_TAG + case["context"]
        prompt += INPUT_TAG + case["input"] + OUTPUT_TAG
        prompt_ids = tokenizer.encode(prompt, add_special_tokens=False)
        best, best_score = None, None
        for cand in case["candidates"]:
            cand_ids = tokenizer.encode(cand, add_special_tokens=False)
            if not cand_ids:
                continue
            ids = torch.tensor([prompt_ids + cand_ids]).to(device)
            with torch.no_grad():
                log_probs = model(ids).logits.log_softmax(-1)
            score = sum(float(log_probs[0, len(prompt_ids) - 1 + i, t])
                        for i, t in enumerate(cand_ids)) / len(cand_ids)
            if best_score is None or score > best_score:
                best, best_score = cand, score
        ok = best == case["chosen"]
        hits += ok
        if args.show_misses and not ok:
            print(f"NG {case['input']} chose={best} expected={case['chosen']} "
                  f"ctx={case.get('context')!r} cands={case['candidates']}")
    print(f"rerank top1: {hits}/{len(cases)} ({hits/len(cases):.1%})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
