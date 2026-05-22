#!/usr/bin/env python3
"""Resident HTTP server for SwiftyGyaim GPT-2 char AI reranking.

This keeps ku-nlp/gpt2-small-japanese-char loaded in memory and exposes a small
localhost-only JSON API.  Use gyaim-gpt2-char-rerank-client.py as the
GYAIM_AI_RERANK_COMMAND so the IME only spawns a tiny client process per request.

Install dependencies:
  python3 -m pip install torch transformers safetensors

Start:
  GYAIM_GPT2_RERANK_PORT=8765 ./gyaim-gpt2-char-rerank-server.py
"""

from __future__ import annotations

import argparse
import json
import math
import os
import signal
import sys
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

MODEL_ID = os.environ.get("GYAIM_GPT2_RERANK_MODEL", "ku-nlp/gpt2-small-japanese-char")
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = int(os.environ.get("GYAIM_GPT2_RERANK_PORT", "8765"))

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
    score: float


class GPT2CharReranker:
    def __init__(self, model_id: str) -> None:
        print(f"Loading {model_id}...", file=sys.stderr, flush=True)
        self.tokenizer = AutoTokenizer.from_pretrained(model_id, use_fast=False)
        self.model = AutoModelForCausalLM.from_pretrained(model_id)
        self.model.eval()
        self.device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        self.model.to(self.device)
        self.model_id = model_id
        self.lock = threading.Lock()
        self.lm_weight = float(os.environ.get("GYAIM_GPT2_RERANK_LM_WEIGHT", "0.05"))
        self.rank_penalty = float(os.environ.get("GYAIM_GPT2_RERANK_RANK_PENALTY", "0.50"))
        print(f"Loaded {model_id} on {self.device}", file=sys.stderr, flush=True)

    def rerank(self, request: dict[str, Any]) -> dict[str, Any]:
        candidates = request.get("candidates") or []
        if not candidates:
            return {"order": [], "scores": {}, "model": self.model_id}

        prompt = self._build_prompt(request)
        input_pat = str(request.get("inputPat") or "")
        hiragana = str(request.get("hiragana") or input_pat)
        scored: list[CandidateScore] = []
        # Serialise model calls. ThreadingHTTPServer can accept concurrent requests,
        # but PyTorch/MPS inference is safer and usually faster when run one at a time.
        with self.lock:
            lm_scores = self._candidate_logprobs(prompt, [str(c["text"]) for c in candidates])
            for candidate, lm_score in zip(candidates, lm_scores):
                index = int(candidate["index"])
                source = str(candidate.get("source") or "")
                kind = str(candidate.get("kind") or "")
                text = str(candidate["text"])
                original_rank = int(candidate.get("index", index))
                final_score = (
                    self.lm_weight * lm_score
                    - self.rank_penalty * original_rank
                    + self._source_bias(source)
                    + self._kind_bias(kind)
                    + self._candidate_bias(text, input_pat, hiragana)
                )
                scored.append(CandidateScore(index=index, score=final_score))

        scored.sort(key=lambda item: item.score, reverse=True)
        return {
            "order": [item.index for item in scored],
            "scores": {str(item.index): item.score for item in scored},
            "model": self.model_id,
        }

    def _build_prompt(self, request: dict[str, Any]) -> str:
        hiragana = request.get("hiragana") or request.get("inputPat") or ""
        context = str(request.get("context") or "")[-80:]
        if context:
            return f"<s>文脈:{context}\n読み:{hiragana}\n変換:"
        return f"<s>読み:{hiragana}\n変換:"

    def _candidate_logprobs(self, prompt: str, candidates: list[str]) -> list[float]:
        encoded_prompt = self.tokenizer(prompt, return_tensors="pt").input_ids[0]
        prompt_len = int(encoded_prompt.shape[0])
        sequences = [self.tokenizer(prompt + candidate, return_tensors="pt").input_ids[0] for candidate in candidates]
        max_len = max(int(seq.shape[0]) for seq in sequences)
        pad_id = self.tokenizer.eos_token_id or 0

        input_ids = torch.full((len(sequences), max_len), pad_id, dtype=torch.long)
        labels = torch.full((len(sequences), max_len), -100, dtype=torch.long)
        for row, seq in enumerate(sequences):
            length = int(seq.shape[0])
            input_ids[row, :length] = seq
            labels[row, prompt_len:length] = seq[prompt_len:length]

        input_ids = input_ids.to(self.device)
        labels = labels.to(self.device)

        with torch.no_grad():
            logits = self.model(input_ids).logits

        shift_logits = logits[:, :-1, :].contiguous()
        shift_labels = labels[:, 1:].contiguous()
        losses = torch.nn.functional.cross_entropy(
            shift_logits.view(-1, shift_logits.size(-1)),
            shift_labels.view(-1),
            reduction="none",
            ignore_index=-100,
        ).view(shift_labels.shape)
        mask = shift_labels.ne(-100)
        token_counts = mask.sum(dim=1).clamp(min=1)
        loss_sums = (losses * mask).sum(dim=1)
        normalized = -loss_sums / torch.sqrt(token_counts.float())
        return [float(x) for x in normalized.detach().cpu()]

    @staticmethod
    def _candidate_bias(text: str, input_pat: str, hiragana: str) -> float:
        # Candidate generation usually includes raw roman input as a safe fallback.
        # It should almost never beat actual Japanese conversion candidates.
        if input_pat and text == input_pat and text.isascii():
            return -8.0
        # Small bonus preserves particles/kana when they are already high-ranked,
        # while rank prior prevents kana from always beating kanji candidates.
        if hiragana and text == hiragana:
            return 0.10
        return 0.0

    @staticmethod
    def _source_bias(source: str) -> float:
        if source == "study":
            return 0.40
        if source == "local":
            return 0.30
        if source == "connection":
            return 0.10
        if source == "google":
            return 0.60
        if source == "external":
            return -0.10
        if source == "synthetic":
            return -0.50
        return 0.0

    @staticmethod
    def _kind_bias(kind: str) -> float:
        if kind == "google":
            return 0.35
        if kind == "exact":
            return 0.20
        if kind == "compound":
            return 0.10
        if kind == "prefix":
            return -0.15
        if kind == "completion":
            return -0.20
        if kind == "kana":
            return -0.30
        if kind == "raw":
            return -1.00
        return 0.0


class Handler(BaseHTTPRequestHandler):
    reranker: GPT2CharReranker

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._send_json({"ok": True, "model": self.reranker.model_id})
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/rerank":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(length).decode("utf-8"))
            response = self.reranker.rerank(request)
            self._send_json(response)
        except Exception as exc:  # pragma: no cover - runtime diagnostics
            self.send_response(500)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}, ensure_ascii=False).encode("utf-8"))

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.address_string()} - {fmt % args}", file=sys.stderr)

    def _send_json(self, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--model", default=MODEL_ID)
    args = parser.parse_args()

    Handler.reranker = GPT2CharReranker(args.model)
    server = ReusableThreadingHTTPServer((args.host, args.port), Handler)

    def stop(_signum: int, _frame: Any) -> None:
        print("Shutting down", file=sys.stderr)
        server.shutdown()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    print(f"Serving on http://{args.host}:{args.port}", file=sys.stderr, flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
