#!/usr/bin/env python3
"""Suggest connection-dictionary additions from the user's own usage.

First step of the "dictionary-growing workflow" (issue #59 方向性4, #29/#45):
words the user actually committed — especially via the Google Transliterate
fallback — that the connection dictionary cannot compose are, by definition,
dictionary gaps. This tool mines studydict/localdict/gyaim.log for such words
and emits reviewable TSV suggestion lines.

Design constraints:
- REVIEW REQUIRED: nothing is applied automatically. Suggested lines use the
  general-noun class (3 -> 4, the dominant class in dict.txt). Verbs,
  adjectives and particles need manual classes — see issue #45 for the
  human-readable class mapping effort.
- Privacy: reads only local files, sends nothing anywhere. The output may
  contain private vocabulary — review before sharing.
- Composability check is a Python port of ConnectionDict's bounded exact
  search (ADR-022 constrainedCompositions), so a word that the dictionary can
  already form as a compound (e.g. 局所化) is not suggested.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

INTERNAL_CONNECTION_LABELS = {
    "い形容詞", "な形容詞", "形容詞語尾", "動詞語尾", "名詞接続", "終止接続", "連用接続",
}

GENERAL_NOUN_IN = 3
GENERAL_NOUN_OUT = 4

GOOGLE_RESULTS_RE = re.compile(r'Google Transliterate results for "([^"]+)": \[(.*)\]')
FIXED_RE = re.compile(r'Fixed: "([^"]+)" \(reading: "([^"]+)"')


@dataclass
class Entry:
    pat: str
    raw_word: str
    in_connection: int
    out_connection: int

    @property
    def word(self) -> str:
        return self.raw_word.replace("*", "")

    @property
    def can_start(self) -> bool:
        return not self.raw_word.startswith("*") and self.raw_word not in INTERNAL_CONNECTION_LABELS

    @property
    def can_terminate(self) -> bool:
        return not self.raw_word.endswith("*") and self.raw_word not in INTERNAL_CONNECTION_LABELS

    @property
    def contributes_surface(self) -> bool:
        return self.raw_word not in INTERNAL_CONNECTION_LABELS


class ConnectionDict:
    """Python port of ConnectionDict's bounded exact composition search."""

    def __init__(self, path: Path) -> None:
        self.entries: list[Entry] = []
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                in_conn = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
                out_conn = int(parts[3]) if len(parts) > 3 and parts[3].isdigit() else 0
                self.entries.append(Entry(parts[0], parts[1], in_conn, out_conn))
        self.by_first_char: dict[str, list[Entry]] = {}
        self.by_in_connection: dict[int, list[Entry]] = {}
        for entry in self.entries:
            if entry.pat:
                if entry.can_start:
                    self.by_first_char.setdefault(entry.pat[0], []).append(entry)
                self.by_in_connection.setdefault(entry.in_connection, []).append(entry)

    def compositions(self, pat: str, max_results: int = 50, max_depth: int = 8) -> set[str]:
        results: set[str] = set()
        self._enumerate(None, pat, "", 0, max_results, max_depth, results)
        return results

    def _enumerate(self, connection: int | None, pat: str, found: str, depth: int,
                   max_results: int, max_depth: int, results: set[str]) -> None:
        if len(results) >= max_results or depth >= max_depth or not pat:
            return
        if connection is None:
            candidates = self.by_first_char.get(pat[0], [])
        else:
            candidates = self.by_in_connection.get(connection, [])
        for entry in candidates:
            if len(results) >= max_results:
                return
            next_word = found + entry.word if entry.contributes_surface else found
            if pat == entry.pat:
                if entry.can_terminate and next_word:
                    results.add(next_word)
            elif entry.pat and pat.startswith(entry.pat):
                self._enumerate(entry.out_connection, pat[len(entry.pat):], next_word,
                                depth + 1, max_results, max_depth, results)


@dataclass
class Suggestion:
    reading: str
    word: str
    provenance: list[str] = field(default_factory=list)

    @property
    def suggested_line(self) -> str:
        return f"{self.reading}\t{self.word}\t{GENERAL_NOUN_IN}\t{GENERAL_NOUN_OUT}"

    @property
    def is_google_origin(self) -> bool:
        return any(p.startswith("google") for p in self.provenance)

    @property
    def study_frequency(self) -> int:
        for p in self.provenance:
            if p.startswith("study:freq="):
                return int(p.split("=", 1)[1])
        return 0


def is_romaji_reading(reading: str) -> bool:
    return len(reading) >= 2 and re.fullmatch(r"[a-z-]+", reading) is not None


def is_japanese_char(ch: str) -> bool:
    code = ord(ch)
    return (0x3041 <= code <= 0x3096 or 0x30A0 <= code <= 0x30FF
            or 0x3400 <= code <= 0x4DBF or 0x4E00 <= code <= 0x9FFF
            or code in (0x3005, 0x3006, 0x3007, 0x30FC))


def is_suggestable_word(word: str) -> bool:
    if not 1 <= len(word) <= 16 or not all(is_japanese_char(ch) for ch in word):
        return False
    # All-hiragana words are usually kana spellings, conjugations or particles —
    # wrong material for a general-noun entry. Kanji/katakana terms only.
    return not all(0x3041 <= ord(ch) <= 0x3096 for ch in word)


def load_study_pairs(path: Path, min_frequency: int) -> dict[tuple[str, str], int]:
    pairs: dict[tuple[str, str], int] = {}
    if not path.exists():
        return pairs
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 4 and parts[3].isdigit() and int(parts[3]) >= min_frequency:
                pairs[(parts[0], parts[1])] = int(parts[3])
    return pairs


def load_local_pairs(path: Path) -> set[tuple[str, str]]:
    pairs: set[tuple[str, str]] = set()
    if not path.exists():
        return pairs
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0] and parts[1]:
                pairs.add((parts[0], parts[1]))
    return pairs


def load_google_commits(paths: list[Path]) -> set[tuple[str, str]]:
    """(reading, word) pairs the user committed from Google Transliterate
    results — proven gaps: the user needed the fallback for these."""
    pairs: set[tuple[str, str]] = set()
    recent_results: dict[str, set[str]] = {}
    for path in paths:
        if not path.exists():
            continue
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                if match := GOOGLE_RESULTS_RE.search(line):
                    words = set(re.findall(r'"([^"]+)"', match.group(2)))
                    recent_results[match.group(1)] = words
                    continue
                if match := FIXED_RE.search(line):
                    word, reading = match.group(1), match.group(2)
                    if word in recent_results.get(reading, set()):
                        pairs.add((reading, word))
    return pairs


def collect_suggestions(dictionary: ConnectionDict,
                        study: dict[tuple[str, str], int],
                        local: set[tuple[str, str]],
                        google: set[tuple[str, str]]) -> list[Suggestion]:
    merged: dict[tuple[str, str], Suggestion] = {}

    def add(reading: str, word: str, provenance: str) -> None:
        if not is_romaji_reading(reading) or not is_suggestable_word(word):
            return
        suggestion = merged.setdefault((reading, word), Suggestion(reading=reading, word=word))
        suggestion.provenance.append(provenance)

    for (reading, word), frequency in study.items():
        add(reading, word, f"study:freq={frequency}")
    for reading, word in local:
        add(reading, word, "local")
    for reading, word in google:
        add(reading, word, "google")

    suggestions = [s for s in merged.values() if s.word not in dictionary.compositions(s.reading)]
    suggestions.sort(key=lambda s: (not s.is_google_origin, -s.study_frequency, s.reading))
    return suggestions


def print_report(suggestions: list[Suggestion], *, fmt: str, limit: int) -> None:
    shown = suggestions[:limit]
    if fmt == "tsv":
        for suggestion in shown:
            print(f"{suggestion.suggested_line}\t# {','.join(suggestion.provenance)}")
        return
    print("# Connection dictionary suggestions — REVIEW REQUIRED")
    print()
    print(f"{len(suggestions)} gap(s) found, showing {len(shown)}. "
          f"Suggested class is 一般名詞 ({GENERAL_NOUN_IN} -> {GENERAL_NOUN_OUT}); "
          "verbs/adjectives/particles need manual classes (#45). "
          "Output may contain private vocabulary — do not share unreviewed.")
    print()
    for suggestion in shown:
        marker = "★google" if suggestion.is_google_origin else ""
        print(f"- [ ] `{suggestion.suggested_line}` — {','.join(suggestion.provenance)} {marker}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Suggest connection dictionary additions from local usage.")
    parser.add_argument("--dict", type=Path, default=None,
                        help="Connection dict TSV. Defaults to ~/.gyaim/connectiondict.txt "
                             "if present, else the bundled Resources/dict.txt.")
    parser.add_argument("--study", type=Path, default=Path.home() / ".gyaim/studydict.txt")
    parser.add_argument("--local", type=Path, default=Path.home() / ".gyaim/localdict.txt")
    parser.add_argument("--log", type=Path, action="append", default=None,
                        help="gyaim.log files for Google-origin tagging. "
                             "Defaults to ~/.gyaim/gyaim.log(.1).")
    parser.add_argument("--min-frequency", type=int, default=5,
                        help="Minimum study frequency for study-derived suggestions.")
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--format", choices=["markdown", "tsv"], default="markdown")
    args = parser.parse_args()

    dict_path = args.dict
    if dict_path is None:
        imported = Path.home() / ".gyaim/connectiondict.txt"
        bundled = Path(__file__).resolve().parents[2] / "Resources/dict.txt"
        dict_path = imported if imported.exists() and imported.stat().st_size > 0 else bundled
    if not dict_path.exists():
        print(f"ERROR: connection dict not found: {dict_path}", file=sys.stderr)
        return 1

    log_paths = args.log or [Path.home() / ".gyaim/gyaim.log.1", Path.home() / ".gyaim/gyaim.log"]
    dictionary = ConnectionDict(dict_path)
    suggestions = collect_suggestions(dictionary,
                                      study=load_study_pairs(args.study, args.min_frequency),
                                      local=load_local_pairs(args.local),
                                      google=load_google_commits(log_paths))
    print_report(suggestions, fmt=args.format, limit=args.limit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
