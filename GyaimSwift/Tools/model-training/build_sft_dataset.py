#!/usr/bin/env python3
"""Build domain SFT data from the user's dogfood logs.

Extracts (left_context, input_katakana, output) triples from
`Fast context accepted detail` lines in ~/.gyaim/gyaim.log(.1) and writes
zenz-v2.5-dataset-schema JSONL for train_zenz.py.

Romaji -> katakana conversion reuses the IME's own rule table by parsing
`rklist` out of Sources/Gyaim/RomaKana.swift (longest-match, sokuon via
doubled consonant), so readings convert exactly like the IME converts them.

Privacy: rows containing URLs, ASCII identifiers or long digit runs are
dropped by default. Output stays local; review before sharing anywhere.

Example:

    .venv/bin/python3 build_sft_dataset.py --output data/domain.jsonl
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

DEFAULT_LOGS = [
    Path.home() / ".gyaim/gyaim.log.1",
    Path.home() / ".gyaim/gyaim.log",
]
ROMAKANA_SWIFT = Path(__file__).resolve().parents[1].parent / "Sources/Gyaim/RomaKana.swift"

DETAIL_RE = re.compile(r'Fast context accepted detail: input="([^"]*)" payload=(\{.*\})$')
REDACT_RE = re.compile(r"https?://|[A-Za-z0-9_.-]{12,}|\d{5,}")
CONSONANTS = set("bcdfghjklmpqrstvwxyz")


def load_roma_to_kata(swift_path: Path) -> dict[str, str]:
    text = swift_path.read_text(encoding="utf-8")
    start = text.index('static let rklist = """') + len('static let rklist = """')
    end = text.index('"""', start)
    table = {}
    for line in text[start:end].splitlines():
        # Swift multiline string: tabs are written as the two-character
        # sequence backslash+t and expanded at compile time.
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\\t")
        if len(parts) >= 3 and parts[0]:
            table[parts[0]] = parts[2]
    if not table:
        raise SystemExit(f"rklist parse failed: {swift_path}")
    return table


class RomaToKata:
    def __init__(self, table: dict[str, str]) -> None:
        self.table = table
        self.max_len = max(len(k) for k in table)

    def convert(self, roma: str) -> str | None:
        """Longest-match conversion. Returns None when any part fails."""
        out = []
        i = 0
        s = roma.lower()
        while i < len(s):
            # sokuon: doubled consonant (kk, tt, ...) that is not 'nn'
            if (
                i + 1 < len(s)
                and s[i] == s[i + 1]
                and s[i] in CONSONANTS
                and s[i] != "n"
                and s[i : i + 2] not in self.table
            ):
                out.append("ッ")
                i += 1
                continue
            for length in range(min(self.max_len, len(s) - i), 0, -1):
                chunk = s[i : i + length]
                if chunk in self.table:
                    out.append(self.table[chunk])
                    i += length
                    break
            else:
                return None
        return "".join(out)


def iter_accepted(log_paths: list[Path]):
    for path in log_paths:
        if not path.exists():
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                match = DETAIL_RE.search(line)
                if not match:
                    continue
                input_pat = match.group(1)
                try:
                    payload = json.loads(match.group(2))
                except json.JSONDecodeError:
                    continue
                tops = {c["rank"]: c for c in payload.get("top", [])}
                chosen = tops.get(payload.get("chosenRank"))
                if not chosen:
                    continue
                yield input_pat, chosen.get("word", ""), payload.get("context") or None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs", nargs="*", type=Path, default=DEFAULT_LOGS)
    parser.add_argument("--romakana", type=Path, default=ROMAKANA_SWIFT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--no-redact", action="store_true")
    parser.add_argument("--exclude-regex", default=None,
                        help="このパターンに一致する行（文脈・表記）を除外する（人名等の手動除外用）")
    parser.add_argument("--max-context", type=int, default=40)
    args = parser.parse_args()

    converter = RomaToKata(load_roma_to_kata(args.romakana))
    exclude_re = re.compile(args.exclude_regex) if args.exclude_regex else None
    stats = Counter()
    rows = []
    seen = Counter()
    for input_pat, word, context in iter_accepted(args.logs):
        stats["accepted"] += 1
        if not input_pat or not word or word == input_pat:
            stats["skip-raw-or-empty"] += 1
            continue
        if not args.no_redact and (
            REDACT_RE.search(word) or (context and REDACT_RE.search(context))
        ):
            stats["skip-redacted"] += 1
            continue
        katakana = converter.convert(input_pat)
        if katakana is None:
            stats["skip-unconvertible-reading"] += 1
            continue
        # 選択テキスト/クリップボード候補由来のノイズ: 読みに対して表記が長すぎるペアは学習に有害
        if len(word) > len(katakana) * 3 + 5:
            stats["skip-reading-output-mismatch"] += 1
            continue
        if exclude_re and (exclude_re.search(word) or (context and exclude_re.search(context))):
            stats["skip-excluded-pattern"] += 1
            continue
        if context and len(context) > args.max_context:
            context = context[-args.max_context :]
        key = (katakana, word, context)
        seen[key] += 1
        if seen[key] > 1:
            stats["dup-merged"] += 1
            continue
        rows.append({"input": katakana, "output": word, "left_context": context})

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"wrote {args.output}: {len(rows)} unique rows")
    for key, value in sorted(stats.items()):
        print(f"  {key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
