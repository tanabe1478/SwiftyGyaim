#!/usr/bin/env python3
"""Extract lightweight IME evaluation cases from ~/.gyaim/gyaim.log.

The script builds a feedback-loop dataset from real usage logs without sending
text anywhere.  It focuses on committed conversion events because they encode a
weak label: the word the user finally accepted and the candidate list/order that
was shown at that moment.

Usage:
  python3 Tools/eval/extract-ime-log-cases.py \
    --log ~/.gyaim/gyaim.log \
    --jsonl /tmp/gyaim-ime-cases.jsonl
"""

from __future__ import annotations

import argparse
import ast
import json
import re
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from statistics import mean

FIXED_RE = re.compile(
    r'Fixed: "(?P<word>.*?)" \(reading: "(?P<reading>.*?)", '
    r'index: (?P<index>\d+)/(?P<count>\d+), candidates: (?P<candidates>\[.*\])\)'
)
KANA_RE = re.compile(
    r'Fixed as kana\((?P<mode>hiragana|katakana)\): "(?P<word>.*?)" '
    r'\(input: "(?P<reading>.*?)", candidates: (?P<count>\d+)\)'
)
SEARCH_RE = re.compile(r'search\((?P<query>.*?), (?P<mode>prefix|exact)\): (?P<ms>[0-9.]+)ms')
AI_APPLIED_RE = re.compile(
    r'AI rerank applied: mode=(?P<mode>\S+) input="(?P<input>.*?)" '
    r'model=(?P<model>.*?) order=(?P<order>\[.*?\]) latency=(?P<ms>[0-9.]+)ms'
)
ZENZ_ALT_RE = re.compile(
    r'Zenz alternative constraint: input="(?P<input>.*?)" base="(?P<base>.*?)" prefix="(?P<prefix>.*?)"'
)
ZENZ_GEN_RE = re.compile(r'Zenz generated candidate: input="(?P<input>.*?)" text="(?P<text>.*?)"')


@dataclass
class FixedCase:
    type: str
    reading: str
    accepted: str
    index: int | None
    count: int
    candidates: list[str]
    line: str


def parse_candidates(text: str) -> list[str]:
    try:
        value = ast.literal_eval(text)
    except Exception:
        return []
    return value if isinstance(value, list) else []


def iter_lines(path: Path):
    with path.expanduser().open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            yield line.rstrip("\n")


def extract(path: Path):
    fixed: list[FixedCase] = []
    search_latencies: list[float] = []
    search_by_query: dict[str, list[float]] = defaultdict(list)
    ai_latencies: list[float] = []
    zenz_alt = Counter()
    zenz_gen = Counter()

    for line in iter_lines(path):
        if m := FIXED_RE.search(line):
            candidates = parse_candidates(m.group("candidates"))
            fixed.append(
                FixedCase(
                    type="fixed",
                    reading=m.group("reading"),
                    accepted=m.group("word"),
                    index=int(m.group("index")),
                    count=int(m.group("count")),
                    candidates=candidates,
                    line=line,
                )
            )
            continue
        if m := KANA_RE.search(line):
            fixed.append(
                FixedCase(
                    type=f"kana-{m.group('mode')}",
                    reading=m.group("reading"),
                    accepted=m.group("word"),
                    index=None,
                    count=int(m.group("count")),
                    candidates=[],
                    line=line,
                )
            )
            continue
        if m := SEARCH_RE.search(line):
            ms = float(m.group("ms"))
            search_latencies.append(ms)
            search_by_query[m.group("query")].append(ms)
            continue
        if m := AI_APPLIED_RE.search(line):
            ai_latencies.append(float(m.group("ms")))
            continue
        if m := ZENZ_ALT_RE.search(line):
            zenz_alt[(m.group("input"), m.group("prefix"))] += 1
            continue
        if m := ZENZ_GEN_RE.search(line):
            zenz_gen[(m.group("input"), m.group("text"))] += 1
            continue

    return fixed, search_latencies, search_by_query, ai_latencies, zenz_alt, zenz_gen


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * pct)))
    return ordered[idx]


def print_summary(fixed, search_latencies, search_by_query, ai_latencies, zenz_alt, zenz_gen):
    converted = [case for case in fixed if case.type == "fixed"]
    kana = [case for case in fixed if case.type.startswith("kana-")]
    top1 = [case for case in converted if case.index == 1]
    poor = [case for case in converted if case.index is not None and case.index >= 4]
    huge = [case for case in fixed if case.count >= 100]

    print("# IME log evaluation summary")
    print(f"fixed conversions: {len(converted)}")
    print(f"kana fixes: {len(kana)}")
    if converted:
        print(f"top1 accepted: {len(top1)}/{len(converted)} = {len(top1)/len(converted):.1%}")
        print(f"accepted rank >=4: {len(poor)}")
    if search_latencies:
        print(
            "search latency ms: "
            f"avg={mean(search_latencies):.1f} "
            f"p50={percentile(search_latencies, 0.50):.1f} "
            f"p95={percentile(search_latencies, 0.95):.1f} "
            f"max={max(search_latencies):.1f}"
        )
    if ai_latencies:
        print(
            "AI Tab latency ms: "
            f"avg={mean(ai_latencies):.1f} "
            f"p50={percentile(ai_latencies, 0.50):.1f} "
            f"p95={percentile(ai_latencies, 0.95):.1f} "
            f"max={max(ai_latencies):.1f}"
        )

    print("\n## Worst accepted ranks")
    for case in sorted(poor, key=lambda c: (c.index or 0), reverse=True)[:20]:
        print(f"- {case.reading}: accepted={case.accepted} rank={case.index}/{case.count} head={case.candidates[:8]}")

    print("\n## Large candidate lists / kana fixes")
    for case in sorted(huge, key=lambda c: c.count, reverse=True)[:20]:
        print(f"- {case.reading}: {case.type} accepted={case.accepted} candidates={case.count}")

    watch = [case for case in fixed if case.reading in {"nise", "niseno", "yousei"}]
    if watch:
        print("\n## Watchlist")
        for case in watch[-20:]:
            print(f"- {case.reading}: {case.type} accepted={case.accepted} rank={case.index}/{case.count} head={case.candidates[:10]}")

    if zenz_gen:
        print("\n## Zenz generated candidates")
        for (input_pat, text), count in zenz_gen.most_common(20):
            print(f"- {input_pat} -> {text} ({count})")
    if zenz_alt:
        print("\n## Zenz alternative prefixes")
        for (input_pat, prefix), count in zenz_alt.most_common(20):
            print(f"- {input_pat} -> {prefix} ({count})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", default="~/.gyaim/gyaim.log")
    parser.add_argument("--jsonl", help="write extracted fixed cases as JSONL")
    parser.add_argument("--azookey-json", help="write azooKey anco evaluate-compatible JSON")
    parser.add_argument("--study-dict", help="write SwiftyGyaim study dictionary TSV from fixed cases")
    args = parser.parse_args()

    fixed, search_latencies, search_by_query, ai_latencies, zenz_alt, zenz_gen = extract(Path(args.log))
    print_summary(fixed, search_latencies, search_by_query, ai_latencies, zenz_alt, zenz_gen)

    if args.jsonl:
        out = Path(args.jsonl)
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("w", encoding="utf-8") as handle:
            for case in fixed:
                handle.write(json.dumps(asdict(case), ensure_ascii=False) + "\n")
        print(f"\nwrote {len(fixed)} cases to {out}")

    if args.azookey_json:
        out = Path(args.azookey_json)
        out.parent.mkdir(parents=True, exist_ok=True)
        items = [
            {
                "query": case.reading,
                "answer": [case.accepted],
                "tag": [case.type],
            }
            for case in fixed
            if case.type == "fixed" and case.reading and case.accepted
        ]
        with out.open("w", encoding="utf-8") as handle:
            json.dump(items, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        print(f"wrote {len(items)} azooKey-compatible cases to {out}")
        print(f"wrote {len(items)} azooKey-compatible cases to {out}")

    if args.study_dict:
        out = Path(args.study_dict)
        out.parent.mkdir(parents=True, exist_ok=True)
        frequencies: Counter[tuple[str, str]] = Counter()
        last_seen: dict[tuple[str, str], int] = {}
        for line_no, case in enumerate(fixed, start=1):
            if case.type == "fixed" and case.reading and case.accepted:
                key = (case.reading, case.accepted)
                frequencies[key] += 1
                last_seen[key] = line_no
        with out.open("w", encoding="utf-8") as handle:
            for (reading, word), frequency in frequencies.most_common():
                handle.write(f"{reading}\t{word}\t{last_seen[(reading, word)]}\t{frequency}\n")
        print(f"wrote {len(frequencies)} study entries to {out}")

if __name__ == "__main__":
    main()
