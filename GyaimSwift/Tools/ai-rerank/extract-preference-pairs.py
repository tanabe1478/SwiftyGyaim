#!/usr/bin/env python3
"""Extract preference cases from dogfood logs (issue #57 / M6-1).

A commit at rank >= 2 is a strong preference signal: the user cycled past the
candidates displayed above and chose this one, so the chosen word should have
outscored everything it beat. This tool converts `Fast context accepted
detail:` log lines (single-line JSON payloads emitted by GyaimController)
into eval-fixture-schema JSONL that both `evaluate-fast-context-rerank.py`
and `train-fast-context-weights.py` consume directly.

Privacy: reads only local logs, sends nothing anywhere. Redaction (on by
default) drops cases containing ASCII-identifier-like words, URLs, emails or
digit-heavy strings. The output still contains private Japanese vocabulary —
review before sharing or committing as fixtures.

Signal-quality notes (zenz-model-tuning.md M6-1):
- deactivation commits never produce accepted logs (skipStudy path), so they
  are excluded at the source
- rank 1 commits are position-biased weak signals and are excluded by default
  (--min-rank 1 to include them)
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

DETAIL_RE = re.compile(r'Fast context accepted detail: input="([^"]*)" payload=(\{.*\})\s*$')
VALIDATOR_PATH = Path(__file__).with_name("validate-fast-context-eval-cases.py")

REDACT_PATTERNS = [
    re.compile(r"[A-Za-z0-9_@:/.\-]{6,}"),  # identifiers, paths, URLs, emails
    re.compile(r"\d{4,}"),                   # long digit runs (IDs, phone numbers)
]


def load_validator():
    spec = importlib.util.spec_from_file_location("fast_context_eval_validator", VALIDATOR_PATH)
    if spec is None or spec.loader is None:
        raise SystemExit(f"failed to load validator: {VALIDATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def needs_redaction(text: str) -> bool:
    return any(pattern.search(text) for pattern in REDACT_PATTERNS)


def build_case(index: int, input_pat: str, payload: dict, *, min_rank: int, redact: bool) -> dict | None:
    chosen_rank = payload.get("chosenRank")
    top = payload.get("top")
    if not isinstance(chosen_rank, int) or chosen_rank < min_rank or not isinstance(top, list):
        return None

    candidates = []
    chosen_word = None
    for item in sorted(top, key=lambda entry: entry.get("rank", 0)):
        word = item.get("word")
        reading = item.get("reading")
        # Candidates without a reading (raw input, clipboard/selected text)
        # carry no dictionary features and are excluded — which also keeps
        # external text out of training data.
        if not isinstance(word, str) or not word or not isinstance(reading, str) or not reading:
            continue
        rank = item.get("rank", 0)
        if rank > chosen_rank:
            continue  # the user never evaluated candidates below the commit
        candidate = {
            "text": word,
            "reading": reading,
            "source": item.get("source", "connection"),
            "kind": item.get("kind", "exact"),
        }
        if isinstance(item.get("studyFrequency"), int):
            candidate["studyFrequency"] = item["studyFrequency"]
        if isinstance(item.get("contextAffinity"), (int, float)) and item["contextAffinity"] > 0:
            candidate["contextAffinity"] = min(float(item["contextAffinity"]), 1.0)
        candidates.append(candidate)
        if rank == chosen_rank:
            chosen_word = word

    if chosen_word is None or len(candidates) < 2:
        return None

    context = payload.get("context") if isinstance(payload.get("context"), str) else ""
    if redact:
        texts = [candidate["text"] for candidate in candidates] + [context]
        if any(needs_redaction(text) for text in texts):
            return None

    return {
        "id": f"preference-{index:05d}",
        "inputPat": input_pat,
        # The log does not carry the kana form; the heuristic never reads it,
        # so the romaji stands in to satisfy the schema.
        "inputKana": input_pat,
        "context": context,
        "candidates": candidates,
        "expectedTop": chosen_word,
        "mustNotTop": [],
        "tags": ["fast-context", "preference"],
        "reason": f"dogfood preference: rank {chosen_rank} commit over {chosen_rank - 1} skipped candidate(s)",
    }


def extract(paths: list[Path], *, min_rank: int, redact: bool) -> tuple[list[dict], int]:
    cases: list[dict] = []
    redacted_or_skipped = 0
    seen: set[tuple[str, str, str]] = set()
    index = 1
    for path in paths:
        if not path.exists():
            continue
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                match = DETAIL_RE.search(line)
                if not match:
                    continue
                try:
                    payload = json.loads(match.group(2))
                except json.JSONDecodeError:
                    redacted_or_skipped += 1
                    continue
                case = build_case(index, match.group(1), payload, min_rank=min_rank, redact=redact)
                if case is None:
                    redacted_or_skipped += 1
                    continue
                key = (case["inputPat"], case["expectedTop"], case["context"])
                if key in seen:
                    continue
                seen.add(key)
                cases.append(case)
                index += 1
    return cases, redacted_or_skipped


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract preference cases from dogfood logs (M6-1).")
    parser.add_argument("--log", type=Path, action="append", default=None,
                        help="gyaim.log files. Defaults to ~/.gyaim/gyaim.log(.1).")
    parser.add_argument("--min-rank", type=int, default=2,
                        help="Minimum commit rank. rank>=2 = the user skipped candidates (strong signal).")
    parser.add_argument("--no-redact", action="store_true",
                        help="Keep cases containing ASCII identifiers / URLs / digit runs.")
    parser.add_argument("--limit", type=int, default=0, help="Emit at most N cases (0 = all).")
    args = parser.parse_args()

    paths = args.log or [Path.home() / ".gyaim/gyaim.log.1", Path.home() / ".gyaim/gyaim.log"]
    cases, skipped = extract(paths, min_rank=args.min_rank, redact=not args.no_redact)
    if args.limit > 0:
        cases = cases[: args.limit]

    # Guarantee schema compatibility with the evaluator / trainer up front.
    validator = load_validator()
    validator.validate([dict(case, __line=i + 1) for i, case in enumerate(cases)])

    for case in cases:
        print(json.dumps(case, ensure_ascii=False))
    print(f"# extracted={len(cases)} skippedOrRedacted={skipped}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
