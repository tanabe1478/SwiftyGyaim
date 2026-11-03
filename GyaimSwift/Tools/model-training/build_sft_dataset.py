#!/usr/bin/env python3
"""Build domain SFT data from the user's dogfood logs.

Extracts (left_context, input_katakana, output) triples from the dogfood
logs and writes zenz-v2.5-dataset-schema JSONL for train_zenz.py.

Sources (issue #125):
- `Fast context accepted detail` lines: the candidate the user picked.
- `Commit outcome` lines with path kana-hiragana / kana-katakana: the kana
  the user confirmed as-is, so the model also learns where kana is the answer.

Labels: when the same reading is retyped within 15 s in the same controller
and a different word is picked, the first commit was a mistake and is dropped
(ADR-040; the IME itself undoes that learning, ADR-037).

Context: the runtime scores candidates with the last 20 characters of the
committed text (`aiRerankFastContextMaxContextLength`), so the context is cut
to 20 and, by default, each pair is also emitted with its last 10 / 5 / 0
characters so short contexts are seen in training too (--context-variants).

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

def default_logs() -> list[Path]:
    """アーカイブ（古い順）→ ローテーション済み → 現行ログの順で読む。
    アーカイブは archive_gyaim_log.py（launchd毎時）が保全している。"""
    archives = sorted((Path.home() / ".gyaim/archive").glob("gyaim-*.log"))
    return archives + [
        Path.home() / ".gyaim/gyaim.log.1",
        Path.home() / ".gyaim/gyaim.log",
    ]
ROMAKANA_SWIFT = Path(__file__).resolve().parents[1].parent / "Sources/Gyaim/RomaKana.swift"

STAMP_RE = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]")
DETAIL_RE = re.compile(r'Fast context accepted detail: input="([^"]*)" payload=(\{.*\})$')
COMMIT_RE = re.compile(r'Commit outcome: input="([^"]*)" payload=(\{.*\})$')
KANA_PATHS = {"kana-hiragana": "hiragana", "kana-katakana": "katakana"}
RETYPE_WINDOW_SECONDS = 15
DEFAULT_CONTEXT_VARIANTS = "20,10,5,0"
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


def katakana_to_hiragana(text: str) -> str:
    return "".join(chr(ord(ch) - 0x60) if "\u30a1" <= ch <= "\u30f6" else ch for ch in text)


def iter_events(log_paths: list[Path], converter: "RomaToKata | None" = None):
    """Yield dicts {time, controller, input, word, context, source} in log order.

    source is "accepted" for picked candidates and "kana" for kana confirms
    (the word is the kana spelling of the input, derived with `converter`).
    """
    seen_keys: set[tuple] = set()
    for path in log_paths:
        if not path.exists():
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                stamp = STAMP_RE.match(line)
                time = stamp.group(1) if stamp else ""
                match = DETAIL_RE.search(line)
                source = "accepted"
                if not match:
                    match = COMMIT_RE.search(line)
                    source = "kana"
                    if not match:
                        continue
                input_pat = match.group(1)
                try:
                    payload = json.loads(match.group(2))
                except json.JSONDecodeError:
                    continue
                if source == "accepted":
                    tops = {c["rank"]: c for c in payload.get("top", [])}
                    chosen = tops.get(payload.get("chosenRank"))
                    if not chosen:
                        continue
                    word = chosen.get("word", "")
                else:
                    kind = KANA_PATHS.get(payload.get("path"))
                    if kind is None or converter is None:
                        continue
                    katakana = converter.convert(input_pat)
                    if katakana is None:
                        continue
                    word = katakana if kind == "katakana" else katakana_to_hiragana(katakana)
                # Archives and rotated logs overlap; keep the first copy of a line.
                key = (time, source, payload.get("controller"), payload.get("generation"),
                       payload.get("composition"), input_pat)
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                yield {"time": time, "controller": payload.get("controller"), "input": input_pat,
                       "word": word, "context": payload.get("context") or None, "source": source}


def iter_accepted(log_paths: list[Path]):
    for event in iter_events(log_paths):
        yield event["input"], event["word"], event["context"]


def _seconds(stamp: str) -> float | None:
    if not stamp:
        return None
    from datetime import datetime
    return datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").timestamp()


def drop_retyped(events: list[dict]) -> tuple[list[dict], int]:
    """Drop a commit that the user immediately retyped with the same reading
    and a different word (the first was a mistake)."""
    last_by_controller: dict = {}
    drop: set[int] = set()
    for index, event in enumerate(events):
        previous = last_by_controller.get(event["controller"])
        if previous is not None:
            prev_index, prev = previous
            t0, t1 = _seconds(prev["time"]), _seconds(event["time"])
            same_reading = event["input"] == prev["input"] or (
                len(prev["input"]) >= 3 and event["input"].startswith(prev["input"]))
            if (t0 is not None and t1 is not None and 0 <= t1 - t0 <= RETYPE_WINDOW_SECONDS
                    and same_reading and event["word"] != prev["word"]):
                drop.add(prev_index)
        last_by_controller[event["controller"]] = (index, event)
    kept = [e for i, e in enumerate(events) if i not in drop]
    return kept, len(drop)


def context_variants(context: str | None, lengths: list[int]) -> list[str | None]:
    """Distinct tails of `context` for each length (0 means no context)."""
    out: list[str | None] = []
    for length in lengths:
        tail = (context or "")[-length:] if length > 0 else ""
        value = tail or None
        if value not in out:
            out.append(value)
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs", nargs="*", type=Path, default=None)
    parser.add_argument("--romakana", type=Path, default=ROMAKANA_SWIFT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--no-redact", action="store_true")
    parser.add_argument("--merge", action="store_true", default=True,
                        help="出力先の既存JSONLと統合する（ログローテーションによる履歴消失を防ぐ。既定ON）")
    parser.add_argument("--no-merge", dest="merge", action="store_false")
    parser.add_argument("--exclude-regex", default=None,
                        help="このパターンに一致する行（文脈・表記）を除外する（人名等の手動除外用）")
    parser.add_argument("--max-context", type=int, default=20,
                        help="左文脈の末尾文字数。実行時にモデルが見るのは 20 文字（aiRerankFastContextMaxContextLength）")
    parser.add_argument("--context-variants", default=DEFAULT_CONTEXT_VARIANTS,
                        help="同じペアを文脈の末尾 N 文字でも出す（カンマ区切り、0 は文脈なし）。'' で無効")
    parser.add_argument("--no-kana-commits", action="store_true",
                        help="かな確定（kana-hiragana / kana-katakana）を学習ペアに入れない")
    parser.add_argument("--keep-retyped", action="store_true",
                        help="15 秒以内に同じ読みを別の語で打ち直した最初の確定を落とさない")
    args = parser.parse_args()

    if args.logs is None:
        args.logs = default_logs()
    converter = RomaToKata(load_roma_to_kata(args.romakana))
    exclude_re = re.compile(args.exclude_regex) if args.exclude_regex else None
    stats = Counter()
    rows = []
    seen = Counter()
    events = list(iter_events(args.logs, converter))
    if args.no_kana_commits:
        events = [e for e in events if e["source"] != "kana"]
    if not args.keep_retyped:
        events, dropped = drop_retyped(events)
        stats["retype-dropped"] = dropped
    variant_lengths = [int(v) for v in args.context_variants.split(",") if v.strip() != ""]
    if not variant_lengths:
        variant_lengths = [args.max_context]
    for event in events:
        input_pat, word, context = event["input"], event["word"], event["context"]
        stats["accepted" if event["source"] == "accepted" else "kana-commits"] += 1
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
        for variant in context_variants(context, [min(n, args.max_context) for n in variant_lengths]):
            key = (katakana, word, variant)
            seen[key] += 1
            if seen[key] > 1:
                stats["dup-merged"] += 1
                continue
            rows.append({"input": katakana, "output": word, "left_context": variant})

    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.merge and args.output.exists():
        existing = [json.loads(l) for l in open(args.output, encoding="utf-8") if l.strip()]
        current = {(r["input"], r["output"], r.get("left_context")) for r in rows}
        carried = [r for r in existing
                   if (r["input"], r["output"], r.get("left_context")) not in current]
        rows = carried + rows
        stats["merged-from-existing"] = len(carried)
    with open(args.output, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"wrote {args.output}: {len(rows)} unique rows")
    for key, value in sorted(stats.items()):
        print(f"  {key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
