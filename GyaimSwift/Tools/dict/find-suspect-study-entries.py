#!/usr/bin/env python3
"""Find study-dictionary entries that look like typos or dead weight.

Issue #58: studydict quality management. Typo entries are not just noise —
BUG-025 showed a single typo entry (してほしいい, freq 1) demoting the user's
most frequent phrase via incompleteStemPenalty. This tool lists suspects for
manual review; deletion is done with Shift+X while converting, or via the
dictionary editor. Nothing is deleted automatically and nothing leaves the
machine.

Suspect classes:
- garbage-completion: the word is another entry's word plus one trailing
  character, and the shorter word is used far more (してほしいい vs してほしい
  freq 22). The classic typo-commit shape.
- stale-singleton: frequency 1 and unused for --stale-days (default 90).
  Mostly accidental commits that will never be wanted again.
"""

from __future__ import annotations

import argparse
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass
class StudyEntry:
    reading: str
    word: str
    last_access: float
    frequency: int


@dataclass
class Suspect:
    entry: StudyEntry
    reason: str
    detail: str


def load_entries(path: Path) -> list[StudyEntry]:
    entries: list[StudyEntry] = []
    if not path.exists():
        return entries
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 4:
                try:
                    entries.append(StudyEntry(parts[0], parts[1], float(parts[2]), int(parts[3])))
                except ValueError:
                    continue
    return entries


def find_suspects(entries: list[StudyEntry], *, stale_days: int, now: float,
                  dominance: int = 3) -> list[Suspect]:
    suspects: list[Suspect] = []
    frequency_by_word: dict[str, int] = {}
    for entry in entries:
        frequency_by_word[entry.word] = max(frequency_by_word.get(entry.word, 0), entry.frequency)

    stale_cutoff = now - stale_days * 24 * 3600
    for entry in entries:
        if len(entry.word) >= 2:
            shorter = entry.word[:-1]
            shorter_frequency = frequency_by_word.get(shorter, 0)
            if shorter_frequency >= max(entry.frequency * dominance, entry.frequency + 2):
                suspects.append(Suspect(
                    entry, "garbage-completion",
                    f"「{shorter}」(freq {shorter_frequency}) の末尾1文字付きで freq {entry.frequency}"))
                continue
        if entry.frequency == 1 and entry.last_access < stale_cutoff:
            age_days = int((now - entry.last_access) / 86400)
            suspects.append(Suspect(entry, "stale-singleton", f"freq 1、最終使用 {age_days} 日前"))
    order = {"garbage-completion": 0, "stale-singleton": 1}
    suspects.sort(key=lambda s: (order[s.reason], -s.entry.frequency, s.entry.reading))
    return suspects


def main() -> int:
    parser = argparse.ArgumentParser(description="List suspicious study-dictionary entries for manual review.")
    parser.add_argument("--study", type=Path, default=Path.home() / ".gyaim/studydict.txt")
    parser.add_argument("--stale-days", type=int, default=90)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--format", choices=["markdown", "tsv"], default="markdown")
    args = parser.parse_args()

    entries = load_entries(args.study)
    suspects = find_suspects(entries, stale_days=args.stale_days, now=time.time())
    shown = suspects[: args.limit]

    if args.format == "tsv":
        for suspect in shown:
            print(f"{suspect.entry.reading}\t{suspect.entry.word}\t{suspect.reason}\t{suspect.detail}")
        return 0

    print("# Study dictionary suspects — REVIEW REQUIRED")
    print()
    print(f"{len(suspects)} suspect(s) in {len(entries)} entries, showing {len(shown)}. "
          "削除は変換中に Shift+X、またはユーザー辞書エディタから。自動削除はしない。")
    print()
    for suspect in shown:
        print(f"- [ ] `{suspect.entry.reading}` → `{suspect.entry.word}` — {suspect.reason}: {suspect.detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
