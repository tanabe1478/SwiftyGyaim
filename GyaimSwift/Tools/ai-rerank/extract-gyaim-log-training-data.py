#!/usr/bin/env python3
"""Extract AI reranker training/evaluation data from ~/.gyaim/gyaim.log.

The extractor parses lines like:
  Fixed: "機能" (reading: "kinou", index: 2/4, candidates: ["kinou", "昨日", "機能", "きのう"])

It emits JSONL records usable by evaluate-reranker.py.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
from pathlib import Path
from typing import Iterable

FIXED_RE = re.compile(
    r'^\[(?P<timestamp>[^\]]+)\] \[input\] \[info\] '
    r'Fixed: "(?P<word>.*)" '
    r'\(reading: "(?P<reading>.*)", index: (?P<index>\d+)/(?P<count>\d+), candidates: (?P<candidates>\[.*\])\)$'
)


def iter_lines(paths: Iterable[Path]) -> Iterable[str]:
    for path in paths:
        if not path.exists():
            continue
        with path.open("r", encoding="utf-8", errors="replace") as f:
            yield from f


def parse_line(line: str) -> dict | None:
    m = FIXED_RE.match(line.rstrip("\n"))
    if not m:
        return None
    try:
        candidates = ast.literal_eval(m.group("candidates"))
    except Exception:
        return None
    if not isinstance(candidates, list) or not all(isinstance(x, str) for x in candidates):
        return None

    index = int(m.group("index"))
    count = int(m.group("count"))
    word = m.group("word")
    reading = m.group("reading")
    if count != len(candidates) or index >= len(candidates):
        return None
    if not word or not reading or not candidates:
        return None

    return {
        "timestamp": m.group("timestamp"),
        "inputPat": reading,
        "selected": word,
        "selectedIndex": index,
        "candidates": candidates,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", type=Path, help="Log files. Defaults to ~/.gyaim/gyaim.log(.1).")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--min-candidates", type=int, default=2)
    parser.add_argument("--max-candidates", type=int, default=20)
    parser.add_argument("--drop-selected-index-zero", action="store_true", help="Keep only cases where baseline top1 missed.")
    args = parser.parse_args()

    paths = args.paths or [Path.home() / ".gyaim/gyaim.log.1", Path.home() / ".gyaim/gyaim.log"]
    args.out.parent.mkdir(parents=True, exist_ok=True)

    total = kept = 0
    with args.out.open("w", encoding="utf-8") as out:
        for line in iter_lines(paths):
            record = parse_line(line)
            if record is None:
                continue
            total += 1
            n = len(record["candidates"])
            if n < args.min_candidates or n > args.max_candidates:
                continue
            if args.drop_selected_index_zero and record["selectedIndex"] == 0:
                continue
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            kept += 1

    print(json.dumps({"totalFixedParsed": total, "kept": kept, "out": str(args.out)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
