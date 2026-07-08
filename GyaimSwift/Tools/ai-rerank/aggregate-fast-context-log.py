#!/usr/bin/env python3
"""Aggregate fast-context-rerank dogfood logs.

Reads ~/.gyaim/gyaim.log(.1) by default and summarizes lines like:

  Fast context rerank finished: input="site" model=... outcome=protected-exact-skip
    topChanged=true candidates=24/89 context=present order=[...] before=[...] after=[...] latency=0.8ms

The script is intentionally dependency-free so it can be used during dogfooding
without setting up the Python AI rerank environment.
"""

from __future__ import annotations

import argparse
import ast
import json
import math
import re
from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from statistics import mean, median
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

REVIEW_RE = re.compile(
    r'^\[(?P<timestamp>[^\]]+)\] \[input\] \[(?P<level>[^\]]+)\] '
    r'Zenz fast-context review (?P<event>\w+): input="(?P<input>[^"]*)"(?P<rest>.*)$'
)

ACCEPTED_RE = re.compile(
    r'^\[(?P<timestamp>[^\]]+)\] \[input\] \[(?P<level>[^\]]+)\] '
    r'Fast context accepted: input="(?P<input>[^"]*)" word="(?P<word>[^"]*)" '
    r'rank=(?P<rank>\d+) candidates=(?P<candidates>\d+) '
    r'source=(?P<source>\S+) kind=(?P<kind>\S+)$'
)

TIME_FORMAT = "%Y-%m-%d %H:%M:%S"


@dataclass(frozen=True)
class FastContextEvent:
    timestamp: str
    input: str
    model: str
    outcome: str
    top_changed: bool | None
    head_count: int
    total_count: int
    context: str
    latency_ms: float
    before_top: str | None
    after_top: str | None

    @property
    def input_length(self) -> int:
        return len(self.input)

    @property
    def candidate_bucket(self) -> str:
        if self.head_count <= 2:
            return "01-02"
        if self.head_count <= 5:
            return "03-05"
        if self.head_count <= 12:
            return "06-12"
        return "13+"


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


def parse_list_head(value: str) -> str | None:
    try:
        parsed = ast.literal_eval(value)
    except Exception:
        return None
    if isinstance(parsed, list) and parsed:
        return str(parsed[0])
    return None


def infer_outcome(model: str) -> str:
    if "review-affinity-skipped" in model:
        return "affinity-skip"
    if "review-skipped" in model:
        return "protected-exact-skip"
    if "review-exact-homophone-unavailable" in model:
        return "exact-homophone-unavailable"
    if "review-exact-homophone-fixed" in model:
        return "exact-homophone-fixed"
    if "review-exact-homophone-kept-local" in model:
        return "exact-homophone-kept-local"
    if "review-exact-homophone-passed" in model:
        return "exact-homophone-passed"
    if "review-unavailable" in model:
        return "review-unavailable"
    if "review-fixed" in model:
        return "review-fixed"
    if "review-kept-local" in model:
        return "review-kept-local"
    if "review-passed" in model:
        return "review-passed"
    if "review" in model:
        return "review-applied"
    if "swift-fast-context-heuristic" in model:
        return "heuristic"
    return "fallback"


def parse_fast_context_line(line: str) -> FastContextEvent | None:
    match = LOG_RE.match(line.rstrip("\n"))
    if not match:
        return None
    model = match.group("model")
    outcome = match.group("outcome") or infer_outcome(model)
    top_changed_raw = match.group("top_changed")
    top_changed = None if top_changed_raw is None else top_changed_raw == "true"
    before_top = parse_list_head(match.group("before"))
    after_top = parse_list_head(match.group("after"))
    if top_changed is None and before_top is not None and after_top is not None:
        top_changed = before_top != after_top
    return FastContextEvent(
        timestamp=match.group("timestamp"),
        input=match.group("input"),
        model=model,
        outcome=outcome,
        top_changed=top_changed,
        head_count=int(match.group("head_count")),
        total_count=int(match.group("total_count")),
        context=match.group("context"),
        latency_ms=float(match.group("latency")),
        before_top=before_top,
        after_top=after_top,
    )


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((pct / 100.0) * len(ordered)) - 1))
    return ordered[index]


def summarize(events: list[FastContextEvent]) -> dict:
    latencies = [e.latency_ms for e in events]
    changed = [e for e in events if e.top_changed is True]
    return {
        "count": len(events),
        "avgMs": round(mean(latencies), 3) if latencies else None,
        "p50Ms": round(median(latencies), 3) if latencies else None,
        "p95Ms": round(percentile(latencies, 95), 3) if latencies else None,
        "maxMs": round(max(latencies), 3) if latencies else None,
        "topChanged": len(changed),
        "topChangedRate": round(len(changed) / len(events), 3) if events else None,
    }


def group_by(events: list[FastContextEvent], key) -> dict[str, dict]:
    groups: dict[str, list[FastContextEvent]] = defaultdict(list)
    for event in events:
        groups[str(key(event))].append(event)
    return {name: summarize(items) for name, items in sorted(groups.items())}


def cutoff_for_events(events: list[FastContextEvent], minutes: int | None) -> datetime | None:
    if minutes is None:
        return None
    timestamps = [parse_timestamp(e.timestamp) for e in events]
    valid = [t for t in timestamps if t is not None]
    if not valid:
        return None
    return max(valid) - timedelta(minutes=minutes)


def filter_since(events: list[FastContextEvent], cutoff: datetime | None) -> list[FastContextEvent]:
    if cutoff is None:
        return events
    return [event for event in events if (parse_timestamp(event.timestamp) or cutoff) >= cutoff]


def collect_review_events(lines: Iterable[str], cutoff: datetime | None) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    for line in lines:
        match = REVIEW_RE.match(line.rstrip("\n"))
        if not match:
            continue
        if cutoff is not None:
            timestamp = parse_timestamp(match.group("timestamp"))
            if timestamp is not None and timestamp < cutoff:
                continue
        event = match.group("event")
        rest = match.group("rest")
        if event == "unavailable":
            reason = re.search(r'reason=([^ ]+)', rest)
            counts[f"unavailable:{reason.group(1) if reason else 'unknown'}"] += 1
        else:
            counts[event] += 1
    return dict(sorted(counts.items()))


def collect_accepted_events(lines: Iterable[str], cutoff: datetime | None) -> dict:
    """Summarize `Fast context accepted` commit logs.

    rank=0 is the raw input committed as-is; rank=1 is the first displayed
    candidate. acceptedTop1Rate / acceptedTop3Rate measure how often the user
    committed a top-ranked dictionary candidate — the closest dogfood proxy to
    top1/top3 accuracy on real input.
    """
    ranks: list[int] = []
    by_source: dict[str, int] = defaultdict(int)
    for line in lines:
        match = ACCEPTED_RE.match(line.rstrip("\n"))
        if not match:
            continue
        if cutoff is not None:
            timestamp = parse_timestamp(match.group("timestamp"))
            if timestamp is not None and timestamp < cutoff:
                continue
        ranks.append(int(match.group("rank")))
        by_source[match.group("source")] += 1
    if not ranks:
        return {"count": 0}
    histogram: dict[str, int] = defaultdict(int)
    for rank in ranks:
        key = str(rank) if rank <= 3 else "4+"
        histogram[key] += 1
    non_raw = [rank for rank in ranks if rank >= 1]
    return {
        "count": len(ranks),
        "rawCommitCount": sum(1 for rank in ranks if rank == 0),
        "meanRank": round(mean(ranks), 3),
        "rankHistogram": dict(sorted(histogram.items())),
        "acceptedTop1Rate": round(sum(1 for rank in non_raw if rank == 1) / len(non_raw), 3) if non_raw else None,
        "acceptedTop3Rate": round(sum(1 for rank in non_raw if rank <= 3) / len(non_raw), 3) if non_raw else None,
        "bySource": dict(sorted(by_source.items())),
    }


def print_table(title: str, rows: dict[str, dict]) -> None:
    print(f"\n## {title}")
    print("key\tcount\tavgMs\tp50Ms\tp95Ms\tmaxMs\ttopChanged\ttopChangedRate")
    for key, summary in rows.items():
        print(
            f"{key}\t{summary['count']}\t{summary['avgMs']}\t{summary['p50Ms']}\t"
            f"{summary['p95Ms']}\t{summary['maxMs']}\t{summary['topChanged']}\t{summary['topChangedRate']}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Aggregate SwiftyGyaim fast-context-rerank dogfood logs.")
    parser.add_argument("paths", nargs="*", type=Path, help="Log files. Defaults to ~/.gyaim/gyaim.log(.1).")
    parser.add_argument("--last-minutes", type=int, default=None, help="Summarize only the last N minutes in the log.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a text table.")
    parser.add_argument("--slow", type=int, default=10, help="Show N slowest events in text mode.")
    parser.add_argument("--examples", type=int, default=5, help="Show N examples per outcome in JSON output.")
    args = parser.parse_args()

    paths = args.paths or [Path.home() / ".gyaim/gyaim.log.1", Path.home() / ".gyaim/gyaim.log"]
    lines = list(iter_lines(paths))
    parsed_events = [event for line in lines if (event := parse_fast_context_line(line)) is not None]
    cutoff = cutoff_for_events(parsed_events, args.last_minutes)
    events = filter_since(parsed_events, cutoff)

    result = {
        "paths": [str(path) for path in paths],
        "total": summarize(events),
        "byOutcome": group_by(events, lambda e: e.outcome),
        "byInputLength": group_by(events, lambda e: e.input_length),
        "byCandidateBucket": group_by(events, lambda e: e.candidate_bucket),
        "reviewEvents": collect_review_events(lines, cutoff),
        "acceptedRanks": collect_accepted_events(lines, cutoff),
        "slowest": [asdict(e) for e in sorted(events, key=lambda e: e.latency_ms, reverse=True)[: args.slow]],
        "examplesByOutcome": {
            outcome: [asdict(e) for e in grouped[: args.examples]]
            for outcome, grouped in _examples_by_outcome(events).items()
        },
    }

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    print(json.dumps(result["total"], ensure_ascii=False))
    print_table("by outcome", result["byOutcome"])
    print_table("by input length", result["byInputLength"])
    print_table("by candidate bucket", result["byCandidateBucket"])
    print("\n## review events")
    print(json.dumps(result["reviewEvents"], ensure_ascii=False, indent=2))
    print("\n## accepted ranks")
    print(json.dumps(result["acceptedRanks"], ensure_ascii=False, indent=2))
    print("\n## slowest")
    for event in result["slowest"]:
        print(
            f"{event['timestamp']} input={event['input']} outcome={event['outcome']} "
            f"latency={event['latency_ms']}ms topChanged={event['top_changed']} "
            f"before={event['before_top']} after={event['after_top']}"
        )
    return 0


def _examples_by_outcome(events: list[FastContextEvent]) -> dict[str, list[FastContextEvent]]:
    grouped: dict[str, list[FastContextEvent]] = defaultdict(list)
    for event in events:
        grouped[event.outcome].append(event)
    return dict(sorted(grouped.items()))


if __name__ == "__main__":
    raise SystemExit(main())
