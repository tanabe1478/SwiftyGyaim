#!/usr/bin/env python3
"""Count how often candidate-like surfaces occur in a reference corpus.

Heuristic rerank has no general word-frequency prior: among many connection
candidates with the same reading (kaeru: 帰る 買える カエル 換える 返る 蛙
替える 変える ...) the order is close to dictionary order. This tokenizes the
`output` side of a zenz-format JSONL corpus with UniDic and counts every
concatenation of 1..3 consecutive tokens that contains kanji or katakana
(帰る, 変えた, 変える), so a candidate surface can be looked up as-is.

Output TSV: `surface<TAB>count`, sorted by count. Needs fugashi + unidic-lite
at build time only.

    /tmp/ud/bin/python Tools/dict/build-corpus-frequency.py \\
        --corpus Tools/model-training/data/train.jsonl --limit 300000 --output /tmp/freq.tsv
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

NEEDS_SCRIPT = re.compile(r"[一-鿿々゠-ヿ]")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=0, help="read only the first N lines (0 = all)")
    parser.add_argument("--max-tokens", type=int, default=3)
    parser.add_argument("--max-length", type=int, default=8)
    parser.add_argument("--min-count", type=int, default=2)
    args = parser.parse_args()

    import fugashi  # noqa: PLC0415 - build-time dependency

    tagger = fugashi.Tagger()
    counts: Counter[str] = Counter()
    with args.corpus.open(encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            if args.limit and number > args.limit:
                break
            text = json.loads(line).get("output") or ""
            tokens = [t.surface for t in tagger(text)]
            for start in range(len(tokens)):
                surface = ""
                for token in tokens[start:start + args.max_tokens]:
                    surface += token
                    if len(surface) > args.max_length:
                        break
                    if NEEDS_SCRIPT.search(surface):
                        counts[surface] += 1

    rows = [(s, c) for s, c in counts.items() if c >= args.min_count]
    rows.sort(key=lambda row: (-row[1], row[0]))
    args.output.write_text("".join(f"{s}\t{c}\n" for s, c in rows), encoding="utf-8")
    print(f"wrote {len(rows)} surfaces to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
