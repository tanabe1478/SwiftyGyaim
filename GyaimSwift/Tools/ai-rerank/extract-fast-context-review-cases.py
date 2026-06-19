#!/usr/bin/env python3
"""Extract fast-context review cases for manual quality labeling.

This script reads SwiftyGyaim dogfood logs and emits review-fixed cases where
the top order changed. The output is meant to be reviewed by a human before any
private IME log data is used for tuning.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable

LOG_RE = re.compile(
    r'^\[(?P<timestamp>[^\]]+)\] \[input\] \[(?P<level>[^\]]+)\] '
    r'Fast context rerank finished: input="(?P<input>[^"]*)" '
    r'model=(?P<model>\S+) '
    r'(?:outcome=(?P<outcome>\S+) )?'
    r'(?:topChanged=(?P<top_changed>true|false) )?'
    r'candidates=(?P<head_count>\d+)/(?P<total_count>\d+) '
    r'context=(?P<context>\S+) '
    r'order=(?P<order>\[[^\]]*\]) '
    r'before=(?P<before>\[.*\]) after=(?P<after>\[.*\]) '
    r'latency=(?P<latency>[0-9.]+)ms$'
)

FIXED_RE = re.compile(
    r'^\[(?P<timestamp>[^\]]+)\] \[input\] \[(?P<level>[^\]]+)\] '
    r'Zenz fast-context review fixed: input="(?P<input>[^"]*)" '
    r'prefix="(?P<prefix>[^"]*)" replacementIndex=(?P<replacement_index>\d+)$'
)

TIME_FORMAT = "%Y-%m-%d %H:%M:%S"


@dataclass(frozen=True)
class ReviewCase:
    id: str
    timestamp: str
    input: str
    outcome: str
    topChanged: bool
    beforeTop: str | None
    afterTop: str | None
    before: list[str]
    after: list[str]
    order: list[int]
    headCount: int
    totalCount: int
    context: str
    latencyMs: float
    model: str
    fixRequiredPrefix: str | None = None
    fixRequiredPrefixLength: int | None = None
    replacementIndex: int | None = None
    label: str = "unlabeled"
    note: str = ""


def iter_lines(paths: Iterable[Path]) -> Iterable[str]:
    for path in paths:
        if not path.exists():
            continue
        with path.open("r", encoding="utf-8", errors="replace") as f:
            yield from f


def parse_timestamp(value: str) -> datetime | None:
    try:
        return datetime.strptime(value, TIME_FORMAT)
    except ValueError:
        return None


def parse_literal_list(value: str) -> list:
    try:
        parsed = ast.literal_eval(value)
    except Exception:
        return []
    return parsed if isinstance(parsed, list) else []


def infer_outcome(model: str) -> str:
    if "review-fixed" in model:
        return "review-fixed"
    if "review-passed" in model:
        return "review-passed"
    if "review-kept-local" in model:
        return "review-kept-local"
    if "review-unavailable" in model:
        return "review-unavailable"
    if "review-skipped" in model:
        return "protected-exact-skip"
    if "heuristic" in model:
        return "heuristic"
    return "fallback"


def parse_case(line: str, index: int) -> ReviewCase | None:
    match = LOG_RE.match(line.rstrip("\n"))
    if not match:
        return None
    model = match.group("model")
    outcome = match.group("outcome") or infer_outcome(model)
    before = [str(item) for item in parse_literal_list(match.group("before"))]
    after = [str(item) for item in parse_literal_list(match.group("after"))]
    order = [item for item in parse_literal_list(match.group("order")) if isinstance(item, int)]
    top_changed_raw = match.group("top_changed")
    top_changed = top_changed_raw == "true" if top_changed_raw is not None else before[:1] != after[:1]
    return ReviewCase(
        id=f"review-fixed-{index:04d}",
        timestamp=match.group("timestamp"),
        input=match.group("input"),
        outcome=outcome,
        topChanged=top_changed,
        beforeTop=before[0] if before else None,
        afterTop=after[0] if after else None,
        before=before,
        after=after,
        order=order,
        headCount=int(match.group("head_count")),
        totalCount=int(match.group("total_count")),
        context=match.group("context"),
        latencyMs=float(match.group("latency")),
        model=model,
    )


def parse_cases(lines: Iterable[str]) -> list[ReviewCase]:
    cases: list[ReviewCase] = []
    pending_fixed: dict[str, tuple[str, int]] = {}
    for index, line in enumerate(lines, start=1):
        if fixed_match := FIXED_RE.match(line.rstrip("\n")):
            prefix = fixed_match.group("prefix")
            replacement_index = int(fixed_match.group("replacement_index"))
            pending_fixed[fixed_match.group("input")] = (prefix, replacement_index)
            continue
        case = parse_case(line, index)
        if case is None:
            continue
        if case.outcome == "review-fixed" and (fixed := pending_fixed.pop(case.input, None)) is not None:
            prefix, replacement_index = fixed
            case = replace(case,
                           fixRequiredPrefix=prefix,
                           fixRequiredPrefixLength=len(prefix),
                           replacementIndex=replacement_index)
        cases.append(case)
    return cases


def cutoff_for(cases: list[ReviewCase], minutes: int | None) -> datetime | None:
    if minutes is None:
        return None
    timestamps = [parse_timestamp(case.timestamp) for case in cases]
    valid = [timestamp for timestamp in timestamps if timestamp is not None]
    if not valid:
        return None
    return max(valid) - timedelta(minutes=minutes)


def filter_cases(cases: list[ReviewCase], *, outcome: str, changed_only: bool, cutoff: datetime | None) -> list[ReviewCase]:
    result: list[ReviewCase] = []
    for case in cases:
        if case.outcome != outcome:
            continue
        if changed_only and not case.topChanged:
            continue
        timestamp = parse_timestamp(case.timestamp)
        if cutoff is not None and timestamp is not None and timestamp < cutoff:
            continue
        result.append(case)
    return result


def write_markdown(cases: list[ReviewCase]) -> str:
    lines = [
        "# Fast-context review cases",
        "",
        "Labels: `good`, `bad`, `unknown`. Do not export private raw logs without review.",
        "",
    ]
    for case in cases:
        lines.extend([
            f"## {case.id}: {case.input}",
            "",
            f"- timestamp: `{case.timestamp}`",
            f"- outcome: `{case.outcome}`",
            f"- latency: `{case.latencyMs}ms`",
            f"- context: `{case.context}`",
            f"- label: `{case.label}`",
            f"- beforeTop: `{case.beforeTop}`",
            f"- afterTop: `{case.afterTop}`",
            f"- fixRequiredPrefix: `{case.fixRequiredPrefix}`",
            f"- fixRequiredPrefixLength: `{case.fixRequiredPrefixLength}`",
            f"- before: `{case.before}`",
            f"- after: `{case.after}`",
            "- note: ",
            "",
        ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract fast-context review-fixed cases from dogfood logs.")
    parser.add_argument("paths", nargs="*", type=Path, help="Log files. Defaults to ~/.gyaim/gyaim.log(.1).")
    parser.add_argument("--last-minutes", type=int, default=None)
    parser.add_argument("--outcome", default="review-fixed")
    parser.add_argument("--all", action="store_true", help="Include cases even when topChanged=false.")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--format", choices=["jsonl", "markdown"], default="jsonl")
    args = parser.parse_args()

    paths = args.paths or [Path.home() / ".gyaim/gyaim.log.1", Path.home() / ".gyaim/gyaim.log"]
    parsed = parse_cases(iter_lines(paths))
    cutoff = cutoff_for(parsed, args.last_minutes)
    cases = filter_cases(parsed, outcome=args.outcome, changed_only=not args.all, cutoff=cutoff)[: args.limit]

    if args.format == "markdown":
        print(write_markdown(cases))
    else:
        for case in cases:
            print(json.dumps(asdict(case), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
