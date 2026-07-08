#!/usr/bin/env python3
"""Compare zenz-v3.1-xsmall HF (non-quantized) vs GGUF Q5_K_M candidate scoring.

M4-1 of docs/zenz-model-tuning-tasklist.md: measure how quantization changes
candidate ranking on the fast-context eval fixture, using the same conditional
mean log-probability scoring as LlamaZenzContext.score / the exact-homophone
direct comparison.

Prompt format matches ZenzPrompt (Zenz v3):

    <context><input_katakana><candidate>

Dependencies are opt-in per backend:
  - HF backend:   pip install torch transformers
  - GGUF backend: pip install llama-cpp-python

Examples:

    # HF only (downloads Miwa-Keita/zenz-v3.1-xsmall on first run)
    python3 Tools/zenz-tuning/compare-hf-gguf.py --backend hf

    # Both backends, comparing rankings case by case
    python3 Tools/zenz-tuning/compare-hf-gguf.py \
      --gguf ~/Downloads/ggml-model-Q5_K_M.gguf --limit 50
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

GYAIM_SWIFT_DIR = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = GYAIM_SWIFT_DIR / "Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl"
DEFAULT_GGUF = GYAIM_SWIFT_DIR / "Resources/Models/zenz-v3.1-xsmall-gguf/ggml-model-Q5_K_M.gguf"
DEFAULT_HF_MODEL = "Miwa-Keita/zenz-v3.1-xsmall"

# Zenz v3 control tags (ZenzPrompt.swift / AzooKeyKanaKanjiConverter zenzai.md)
CONTEXT_TAG = "\uEE02"
INPUT_TAG = "\uEE00"
OUTPUT_TAG = "\uEE01"


def load_cases(path: Path) -> list[dict[str, Any]]:
    cases = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            if stripped:
                cases.append(json.loads(stripped))
    return cases


def build_prompt(case: dict[str, Any], *, context_mode: str) -> str:
    prompt = ""
    context = (case.get("context") or "").strip() if context_mode == "fixture" else ""
    if context:
        prompt += CONTEXT_TAG + context
    prompt += INPUT_TAG + case["inputKana"] + OUTPUT_TAG
    return prompt


class HFScorer:
    name = "hf"

    def __init__(self, model_id: str) -> None:
        try:
            import torch
            from transformers import AutoModelForCausalLM, AutoTokenizer
        except ImportError as exc:
            raise SystemExit(
                f"HF backend requires torch + transformers: {exc}\n"
                "  python3 -m pip install torch transformers"
            ) from exc
        self.torch = torch
        self.tokenizer = AutoTokenizer.from_pretrained(model_id)
        self.model = AutoModelForCausalLM.from_pretrained(model_id)
        self.model.eval()

    def score(self, prompt: str, continuation: str) -> float | None:
        torch = self.torch
        prompt_ids = self.tokenizer.encode(prompt, add_special_tokens=False)
        continuation_ids = self.tokenizer.encode(continuation, add_special_tokens=False)
        if not prompt_ids or not continuation_ids:
            return None
        input_ids = torch.tensor([prompt_ids + continuation_ids])
        with torch.no_grad():
            logits = self.model(input_ids).logits[0]
        log_probs = torch.log_softmax(logits, dim=-1)
        total = 0.0
        for position, token_id in enumerate(continuation_ids):
            total += float(log_probs[len(prompt_ids) - 1 + position, token_id])
        return total / len(continuation_ids)


class GGUFScorer:
    name = "gguf"

    def __init__(self, model_path: Path) -> None:
        try:
            from llama_cpp import Llama
        except ImportError as exc:
            raise SystemExit(
                f"GGUF backend requires llama-cpp-python: {exc}\n"
                "  python3 -m pip install llama-cpp-python"
            ) from exc
        if not model_path.exists():
            raise SystemExit(f"GGUF model not found: {model_path}")
        self.llama = Llama(model_path=str(model_path), logits_all=True, verbose=False, n_ctx=1024)

    def score(self, prompt: str, continuation: str) -> float | None:
        llama = self.llama
        prompt_tokens = llama.tokenize(prompt.encode("utf-8"), add_bos=True, special=False)
        continuation_tokens = llama.tokenize(continuation.encode("utf-8"), add_bos=False, special=False)
        if not prompt_tokens or not continuation_tokens:
            return None
        tokens = prompt_tokens + continuation_tokens
        llama.reset()
        llama.eval(tokens)
        total = 0.0
        for position, token_id in enumerate(continuation_tokens):
            row = llama.scores[len(prompt_tokens) - 1 + position]
            max_logit = max(row)
            logsumexp = max_logit + math.log(sum(math.exp(value - max_logit) for value in row))
            total += row[token_id] - logsumexp
        return total / len(continuation_tokens)


def rank_candidates(scorer, case: dict[str, Any], *, context_mode: str) -> list[tuple[str, float | None]]:
    prompt = build_prompt(case, context_mode=context_mode)
    return [
        (candidate["text"], scorer.score(prompt, candidate["text"]))
        for candidate in case["candidates"]
        if candidate["kind"] != "raw"
    ]


def ordered_texts(scored: list[tuple[str, float | None]]) -> list[str]:
    return [text for text, score in sorted(scored, key=lambda pair: -(pair[1] if pair[1] is not None else -1e9))]


def kendall_tau_distance(lhs: list[str], rhs: list[str]) -> int:
    common = [text for text in lhs if text in rhs]
    distance = 0
    for i in range(len(common)):
        for j in range(i + 1, len(common)):
            if (rhs.index(common[i]) > rhs.index(common[j])) != (lhs.index(common[i]) > lhs.index(common[j])):
                distance += 1
    return distance


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare HF vs GGUF zenz candidate scoring on eval fixtures.")
    parser.add_argument("fixture", nargs="?", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--backend", choices=["both", "hf", "gguf"], default="both")
    parser.add_argument("--hf-model", default=DEFAULT_HF_MODEL)
    parser.add_argument("--gguf", type=Path, default=DEFAULT_GGUF)
    parser.add_argument("--context-mode", choices=["fixture", "none"], default="fixture")
    parser.add_argument("--limit", type=int, default=0, help="Evaluate only the first N cases (0 = all).")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    cases = load_cases(args.fixture)
    if args.limit > 0:
        cases = cases[: args.limit]

    scorers = []
    if args.backend in ("both", "hf"):
        scorers.append(HFScorer(args.hf_model))
    if args.backend in ("both", "gguf"):
        scorers.append(GGUFScorer(args.gguf))

    per_case = []
    top1_hits = {scorer.name: 0 for scorer in scorers}
    agreement = 0
    tau_total = 0
    for case in cases:
        entry: dict[str, Any] = {"id": case["id"], "expectedTop": case["expectedTop"]}
        orders: dict[str, list[str]] = {}
        for scorer in scorers:
            scored = rank_candidates(scorer, case, context_mode=args.context_mode)
            order = ordered_texts(scored)
            orders[scorer.name] = order
            entry[scorer.name] = {
                "order": order,
                "scores": {text: (round(score, 4) if score is not None else None) for text, score in scored},
            }
            if order and order[0] == case["expectedTop"]:
                top1_hits[scorer.name] += 1
        if len(scorers) == 2:
            lhs, rhs = orders[scorers[0].name], orders[scorers[1].name]
            entry["top1Agree"] = bool(lhs and rhs and lhs[0] == rhs[0])
            entry["kendallTauDistance"] = kendall_tau_distance(lhs, rhs)
            agreement += entry["top1Agree"]
            tau_total += entry["kendallTauDistance"]
        per_case.append(entry)

    summary: dict[str, Any] = {
        "fixture": str(args.fixture),
        "cases": len(cases),
        "contextMode": args.context_mode,
        "top1": {name: {"hits": hits, "rate": round(hits / len(cases), 4) if cases else None}
                 for name, hits in top1_hits.items()},
    }
    if len(scorers) == 2:
        summary["top1AgreementRate"] = round(agreement / len(cases), 4) if cases else None
        summary["meanKendallTauDistance"] = round(tau_total / len(cases), 4) if cases else None

    output = {"summary": summary, "cases": per_case}
    if args.json:
        print(json.dumps(output, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        disagreements = [entry for entry in per_case if entry.get("top1Agree") is False]
        if disagreements:
            print("\n## top1 disagreements")
            for entry in disagreements:
                lines = [f"{name}={entry[name]['order'][:3]}" for name in top1_hits]
                print(f"{entry['id']}\texpected={entry['expectedTop']}\t" + "\t".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
