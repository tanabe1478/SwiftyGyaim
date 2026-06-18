#!/usr/bin/env python3
"""Summarize manually labeled fast-context review cases.

Input is JSONL produced by extract-fast-context-review-cases.py after a human
changes each record's `label` to one of:

  good     - review-fixed improved the top candidate
  bad      - review-fixed made the top candidate worse
  unknown  - cannot judge from the redacted/local context

`unlabeled` records are accepted but excluded from precision.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from statistics import mean, median
from typing import Any, Iterable

VALID_LABELS = {"good", "bad", "unknown", "unlabeled"}
LABELED = {"good", "bad"}


class LabelError(Exception):
    pass


@dataclass(frozen=True)
class LabeledCase:
    id: str
    input: str
    label: str
    latencyMs: float | None
    beforeTop: str | None
    afterTop: str | None
    outcome: str
    fixRequiredPrefixLength: int | None

    @property
    def input_length_bucket(self) -> str:
        length = len(self.input)
        if length <= 2:
            return "01-02"
        if length <= 4:
            return "03-04"
        if length <= 8:
            return "05-08"
        return "09+"

    @property
    def after_script(self) -> str:
        return script_class(self.afterTop or "")

    @property
    def fix_prefix_length_bucket(self) -> str:
        length = self.fixRequiredPrefixLength
        if length is None:
            return "none"
        if length <= 1:
            return "01"
        if length <= 3:
            return "02-03"
        return "04+"


def load_jsonl(paths: Iterable[Path]) -> list[LabeledCase]:
    cases: list[LabeledCase] = []
    for path in paths:
        with path.open("r", encoding="utf-8") as f:
            for line_number, line in enumerate(f, start=1):
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    record = json.loads(stripped)
                except json.JSONDecodeError as exc:
                    raise LabelError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
                cases.append(parse_record(record, path=path, line_number=line_number))
    return cases


def parse_record(record: dict[str, Any], *, path: Path, line_number: int) -> LabeledCase:
    label = record.get("label", "unlabeled")
    if label not in VALID_LABELS:
        raise LabelError(f"{path}:{line_number}: invalid label {label!r}; expected one of {sorted(VALID_LABELS)}")
    latency = record.get("latencyMs")
    if latency is not None and not isinstance(latency, (int, float)):
        raise LabelError(f"{path}:{line_number}: latencyMs must be numeric when present")
    return LabeledCase(
        id=require_string(record, "id", path, line_number),
        input=require_string(record, "input", path, line_number),
        label=label,
        latencyMs=float(latency) if latency is not None else None,
        beforeTop=optional_string(record, "beforeTop", path, line_number),
        afterTop=optional_string(record, "afterTop", path, line_number),
        outcome=require_string(record, "outcome", path, line_number),
        fixRequiredPrefixLength=optional_int(record, "fixRequiredPrefixLength", path, line_number),
    )


def require_string(record: dict[str, Any], field: str, path: Path, line_number: int) -> str:
    value = record.get(field)
    if not isinstance(value, str) or not value:
        raise LabelError(f"{path}:{line_number}: {field} must be a non-empty string")
    return value


def optional_string(record: dict[str, Any], field: str, path: Path, line_number: int) -> str | None:
    value = record.get(field)
    if value is None:
        return None
    if not isinstance(value, str):
        raise LabelError(f"{path}:{line_number}: {field} must be a string or null")
    return value


def optional_int(record: dict[str, Any], field: str, path: Path, line_number: int) -> int | None:
    value = record.get(field)
    if value is None:
        return None
    if not isinstance(value, int):
        raise LabelError(f"{path}:{line_number}: {field} must be an integer or null")
    return value


def script_class(text: str) -> str:
    if not text:
        return "empty"
    has_hiragana = any(0x3040 <= ord(ch) <= 0x309F for ch in text)
    has_katakana = any(0x30A0 <= ord(ch) <= 0x30FF for ch in text)
    has_kanji = any(0x4E00 <= ord(ch) <= 0x9FFF for ch in text)
    has_ascii = any(ch.isascii() and ch.isalnum() for ch in text)
    if has_kanji and (has_hiragana or has_katakana):
        return "kanji-mixed"
    if has_kanji:
        return "kanji"
    if has_hiragana and not has_katakana:
        return "hiragana"
    if has_katakana and not has_hiragana:
        return "katakana"
    if has_ascii:
        return "ascii"
    return "other"


def latency_summary(cases: list[LabeledCase]) -> dict[str, Any]:
    values = [case.latencyMs for case in cases if case.latencyMs is not None]
    if not values:
        return {"count": 0, "avgMs": None, "p50Ms": None, "maxMs": None}
    return {
        "count": len(values),
        "avgMs": round(mean(values), 3),
        "p50Ms": round(median(values), 3),
        "maxMs": round(max(values), 3),
    }


def summarize(cases: list[LabeledCase]) -> dict[str, Any]:
    labels = Counter(case.label for case in cases)
    judged = labels["good"] + labels["bad"]
    return {
        "total": len(cases),
        "labels": dict(sorted(labels.items())),
        "judged": judged,
        "precision": round(labels["good"] / judged, 4) if judged else None,
        "badRate": round(labels["bad"] / judged, 4) if judged else None,
        "unknownRate": round(labels["unknown"] / len(cases), 4) if cases else None,
        "latency": latency_summary(cases),
        "byInputLength": summarize_groups(cases, lambda case: case.input_length_bucket),
        "byAfterScript": summarize_groups(cases, lambda case: case.after_script),
        "byFixPrefixLength": summarize_groups(cases, lambda case: case.fix_prefix_length_bucket),
        "badExamples": [case_to_example(case) for case in cases if case.label == "bad"][:20],
    }


def summarize_groups(cases: list[LabeledCase], key_fn) -> dict[str, dict[str, Any]]:
    groups: dict[str, list[LabeledCase]] = defaultdict(list)
    for case in cases:
        groups[str(key_fn(case))].append(case)
    return {key: summarize_small(group) for key, group in sorted(groups.items())}


def summarize_small(cases: list[LabeledCase]) -> dict[str, Any]:
    labels = Counter(case.label for case in cases)
    judged = labels["good"] + labels["bad"]
    return {
        "total": len(cases),
        "good": labels["good"],
        "bad": labels["bad"],
        "unknown": labels["unknown"],
        "unlabeled": labels["unlabeled"],
        "precision": round(labels["good"] / judged, 4) if judged else None,
    }


def case_to_example(case: LabeledCase) -> dict[str, Any]:
    return {
        "id": case.id,
        "input": case.input,
        "beforeTop": case.beforeTop,
        "afterTop": case.afterTop,
        "latencyMs": case.latencyMs,
        "fixRequiredPrefixLength": case.fixRequiredPrefixLength,
    }


def print_text(summary: dict[str, Any]) -> None:
    print("# fast-context review label summary")
    print(json.dumps({k: v for k, v in summary.items() if k not in {"byInputLength", "byAfterScript", "byFixPrefixLength", "badExamples"}}, ensure_ascii=False, indent=2))
    print("\n## by input length")
    print_table(summary["byInputLength"])
    print("\n## by after-top script")
    print_table(summary["byAfterScript"])
    print("\n## by fix-required prefix length")
    print_table(summary["byFixPrefixLength"])
    if summary["badExamples"]:
        print("\n## bad examples")
        for example in summary["badExamples"]:
            print(
                f"{example['id']} input={example['input']} "
                f"before={example['beforeTop']} after={example['afterTop']} "
                f"fixPrefixLen={example['fixRequiredPrefixLength']} latency={example['latencyMs']}ms"
            )


def print_table(rows: dict[str, dict[str, Any]]) -> None:
    print("key\ttotal\tgood\tbad\tunknown\tunlabeled\tprecision")
    for key, values in rows.items():
        print(
            f"{key}\t{values['total']}\t{values['good']}\t{values['bad']}\t"
            f"{values['unknown']}\t{values['unlabeled']}\t{values['precision']}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize labeled fast-context review-fixed cases.")
    parser.add_argument("paths", nargs="+", type=Path, help="Labeled JSONL files from extract-fast-context-review-cases.py")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    cases = load_jsonl(args.paths)
    summary = summarize(cases)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print_text(summary)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LabelError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
