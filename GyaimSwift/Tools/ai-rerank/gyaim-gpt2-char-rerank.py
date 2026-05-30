#!/usr/bin/env python3
"""SwiftyGyaim external AI reranker using ku-nlp/gpt2-small-japanese-char.

Protocol:
  stdin:  AIRerankRequest JSON emitted by SwiftyGyaim
  stdout: {"order": [candidate indexes], "scores": {index: score}, "model": "..."}

Dependencies:
  python3 -m pip install torch transformers safetensors

The first invocation downloads/loads the model and is too slow for interactive use.
For practical use, keep the Hugging Face cache warm and consider wrapping this
logic in a small resident server later. This script is intentionally simple so
SwiftyGyaim can experiment with a GPT-2-char reranker without linking ML runtimes
into the IME process.
"""

from __future__ import annotations

import json
import math
import os
import sys
from dataclasses import dataclass
from typing import Any

MODEL_ID = os.environ.get("GYAIM_GPT2_RERANK_MODEL", "ku-nlp/gpt2-small-japanese-char")

try:
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
except Exception as exc:  # pragma: no cover - depends on local environment
    print(f"Missing dependency: {exc}", file=sys.stderr)
    print("Install with: python3 -m pip install torch transformers safetensors", file=sys.stderr)
    sys.exit(2)


@dataclass
class CandidateScore:
    index: int
    text: str
    score: float


def load_model() -> tuple[Any, Any, Any]:
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, use_fast=False)
    model = AutoModelForCausalLM.from_pretrained(MODEL_ID)
    model.eval()
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model.to(device)
    return tokenizer, model, device


def candidate_logprob(tokenizer: Any, model: Any, device: Any, prompt: str, candidate: str) -> float:
    # Score only the candidate continuation, not the prompt.  A length-normalized
    # log probability is used so short raw-input candidates do not win only by
    # being short.
    full = prompt + candidate
    prompt_ids = tokenizer(prompt, return_tensors="pt").input_ids.to(device)
    full_ids = tokenizer(full, return_tensors="pt").input_ids.to(device)

    labels = full_ids.clone()
    prompt_len = min(prompt_ids.shape[1], labels.shape[1])
    labels[:, :prompt_len] = -100

    with torch.no_grad():
        output = model(full_ids, labels=labels)

    continuation_len = max(labels.ne(-100).sum().item(), 1)
    return -float(output.loss.item()) / math.sqrt(continuation_len)


def source_bias(source: str) -> float:
    # Keep the neural score advisory rather than absolute.  Synthetic/raw input
    # should remain available but should not dominate real dictionary candidates.
    if source == "study":
        return 0.20
    if source == "local":
        return 0.15
    if source == "connection":
        return 0.05
    if source == "external":
        return -0.05
    if source == "synthetic":
        return -0.20
    return 0.0



def kind_bias(kind: str) -> float:
    if kind == "google":
        return 0.20
    if kind == "exact":
        return 0.10
    if kind == "compound":
        return 0.05
    if kind == "prefix":
        return -0.05
    if kind == "completion":
        return -0.10
    if kind == "kana":
        return -0.15
    if kind == "raw":
        return -0.50
    return 0.0

def build_prompt(request: dict[str, Any]) -> str:
    hiragana = request.get("hiragana") or request.get("inputPat") or ""
    # Keep prompt stable and short.  The char-level GPT-2 was not instruction
    # tuned; we use it as a language model scorer, not as a JSON generator.
    return f"<s>読み:{hiragana}\n変換:"


def main() -> int:
    request = json.load(sys.stdin)
    candidates = request.get("candidates") or []
    if not candidates:
        print(json.dumps({"order": [], "scores": {}, "model": MODEL_ID}, ensure_ascii=False))
        return 0

    tokenizer, model, device = load_model()
    prompt = build_prompt(request)

    scored: list[CandidateScore] = []
    for candidate in candidates:
        index = int(candidate["index"])
        text = str(candidate["text"])
        source = str(candidate.get("source") or "")
        kind = str(candidate.get("kind") or "")
        lm_score = candidate_logprob(tokenizer, model, device, prompt, text)
        score = lm_score + source_bias(source) + kind_bias(kind)
        scored.append(CandidateScore(index=index, text=text, score=score))

    scored.sort(key=lambda item: item.score, reverse=True)
    response = {
        "order": [item.index for item in scored],
        "scores": {str(item.index): item.score for item in scored},
        "model": MODEL_ID,
    }
    print(json.dumps(response, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
