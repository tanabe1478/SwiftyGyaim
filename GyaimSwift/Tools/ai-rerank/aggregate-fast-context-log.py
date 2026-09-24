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
    r'(?:(?:controller=(?P<controller>\S+) )?composition=(?P<composition>\d+) gen=(?P<generation>\d+) pass=(?P<pass>\S+) )?'
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
    if "heuristic-prereview" in model:
        return "heuristic-prereview"
    if "review-exact-homophone-tail-reranked" in model:
        return "exact-homophone-tail-reranked"
    if "review-affinity-skipped" in model:
        return "affinity-skip"
    if "review-length-skipped" in model:
        return "short-input-skip"
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
    if "heuristic" in model:
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
    # Old topChanged compared all eight rows; recompute true top1 changes.
    if before_top is not None and after_top is not None:
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


ACCEPTED_DETAIL_RE = re.compile(
    r"^\[(?P<timestamp>[^\]]+)\] \[input\] \[info\] "
    r'Fast context accepted detail: input="(?P<input>[^"]*)" payload=(?P<payload>\{.*\})$'
)


def collect_model_effect(lines: Iterable[str], cutoff: datetime | None) -> dict:
    """Score each commit against the heuristic-only order (model-effect metric).

    Uses the `Fast context accepted detail` payload fields written by
    GyaimController (composition / modelState / heuristicRank / proposedRank).
    A commit counts as improved when the displayed rank the user chose is
    better than its rank under the heuristic-only order, worsened when it is
    worse. Only commits where the model actually changed the display
    (modelState=applied-changed) can move either way; applied-unchanged is a
    model no-op; cancelled means the user acted before the deferred review ran
    (committedBeforeReviewRate).
    """
    by_state: dict[str, int] = defaultdict(int)
    top1_by_state: dict[str, int] = defaultdict(int)
    improved = worsened = same = 0
    scored = 0
    scheduled = before_review = 0
    seen: set[tuple[str, int, int]] = set()
    effects: dict[str, list[int]] = defaultdict(list)
    allowed_states = {"not-scheduled", "pending", "cancelled", "applied-changed",
                      "applied-unchanged", "skipped", "unavailable", "sync"}
    for line in lines:
        match = ACCEPTED_DETAIL_RE.match(line.rstrip("\n"))
        if not match:
            continue
        if cutoff is not None:
            timestamp = parse_timestamp(match.group("timestamp"))
            if timestamp is not None and timestamp < cutoff:
                continue
        try:
            payload = json.loads(match.group("payload"))
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        state = payload.get("modelState")
        chosen = payload.get("chosenRank")
        if not isinstance(state, str) or state not in allowed_states or type(chosen) is not int or chosen < 1:
            continue  # legacy/no trace, invalid ranks, and raw commits are not quality labels
        if payload.get("traceVersion") == 2:
            controller = payload.get("controller")
            composition = payload.get("composition")
            generation = payload.get("generation")
            if (not isinstance(controller, str) or not controller
                    or type(composition) is not int or composition < 0
                    or type(generation) is not int or generation < 0):
                continue
            key = (controller, composition, generation)
            if key in seen:
                continue
            seen.add(key)
        by_state[state] += 1
        # This is a rate over committed requests, NOT all scheduled keystrokes.
        if payload.get("deferred", state != "sync") is True and state != "not-scheduled":
            scheduled += 1
            before_review += state in {"pending", "cancelled"}
        if chosen == 1:
            top1_by_state[state] += 1
        heuristic_rank = payload.get("heuristicRank")
        proposed_rank = payload.get("proposedRank", chosen)
        if (state in {"applied-changed", "applied-unchanged", "sync"}
                and type(heuristic_rank) is int and heuristic_rank >= 1
                and type(proposed_rank) is int and proposed_rank == chosen):
            delta = heuristic_rank - chosen
            effects["all"].append(delta)
            outcome = payload.get("modelOutcome", "unknown")
            if isinstance(outcome, str):
                effects["outcome:" + outcome].append(delta)
            if state == "applied-changed":
                scored += 1
                improved += delta > 0
                worsened += delta < 0
                same += delta == 0
    total = sum(by_state.values())
    if total == 0:
        return {"count": 0}
    def rank_effect(deltas: list[int]) -> dict:
        return {
            "scored": len(deltas), "improved": sum(d > 0 for d in deltas),
            "worsened": sum(d < 0 for d in deltas), "same": deltas.count(0),
            "netImproved": sum((d > 0) - (d < 0) for d in deltas),
            "rankGainSum": sum(deltas),
            "meanRankGain": round(mean(deltas), 3) if deltas else None,
        }

    return {
        "count": total,
        "byModelState": dict(sorted(by_state.items())),
        "top1RateByModelState": {
            state: round(top1_by_state[state] / count, 3) for state, count in sorted(by_state.items())
        },
        "deferredCommitCount": scheduled,
        "committedBeforeReviewRate": round(before_review / scheduled, 3) if scheduled else None,
        "rankEffect": rank_effect(effects["all"]),
        "byOutcome": {key.removeprefix("outcome:"): rank_effect(value)
                      for key, value in sorted(effects.items()) if key.startswith("outcome:")},
        "appliedChanged": {
            "scored": scored,
            "improved": improved,
            "worsened": worsened,
            "same": same,
            "netImproved": improved - worsened,
        },
    }


SEARCH_RE = re.compile(r"\] \[input\] \[info\] search\((?P<input>.*), (?P<mode>prefix|exact)\): ")
GOOGLE_TRIGGER_RE = re.compile(r'\] \[input\] \[info\] Google Transliterate triggered: "')
FIXED_RE = re.compile(
    r'^\[(?P<timestamp>[^\]]+)\] \[input\] \[info\] '
    r'Fixed: "(?P<word>[^"]*)" \(reading: "(?P<reading>[^"]*)", index: (?P<index>\d+)/'
)
KANA_FIXED_RE = re.compile(
    r'^\[(?P<timestamp>[^\]]+)\] \[input\] \[info\] '
    r'Fixed as kana\((?P<script>hiragana|katakana)\): "(?P<word>[^"]*)" \(input: "(?P<input>[^"]*)"'
)
DEACTIVATION_RE = re.compile(r'\] \[input\] \[info\] Study skipped \(deactivation\): "(?P<word>[^"]*)"')

# Commit paths that mean the prefix-mode list did not offer the wanted word
# first. `kana-other` / `kana-absent` are suspected misses: the user may have
# preferred the kana spelling on purpose.
COMMIT_MISS = ("prefix-lower", "exact-escape", "kana-other", "kana-absent", "google")
COMMIT_HIT = ("prefix-top1", "kana-top1")
COMMIT_EXCLUDED = ("prefix-raw", "kana-no-dictionary", "deactivation")


def collect_commit_outcomes(lines: Iterable[str], cutoff: datetime | None, examples: int = 5) -> dict:
    """Classify every commit by how the user got the word (issue: accepted
    detail logs only cover prefix-mode picks, so escapes were invisible).

    Reconstructed from plain log lines, so it works on old logs too. Each
    commit is compared with the dictionary head (`after`, up to 8 words) of
    the most recent `Fast context rerank finished` line for the same input;
    lines carry no controller for commits, so interleaved fields can mix.
    """
    last_head: dict[str, list[str]] = {}
    mode = "prefix"
    commits: list[dict] = []

    def prefix_rank(reading: str, word: str) -> int | None:
        head = last_head.get(reading, [])
        return head.index(word) + 1 if word in head else None

    for line in lines:
        line = line.rstrip("\n")
        if (event := LOG_RE.match(line)) is not None:
            try:
                parsed = ast.literal_eval(event.group("after"))
            except Exception:
                parsed = None
            if isinstance(parsed, list):
                last_head[event.group("input")] = [str(word) for word in parsed]
            continue
        if (search := SEARCH_RE.search(line)) is not None:
            mode = search.group("mode")
            continue
        if GOOGLE_TRIGGER_RE.search(line):
            mode = "google"
            continue
        if (deactivated := DEACTIVATION_RE.search(line)) is not None:
            if commits and commits[-1]["word"] == deactivated.group("word"):
                commits[-1]["path"] = "deactivation"
            continue
        if (fixed := FIXED_RE.match(line)) is not None:
            word, reading, index = fixed.group("word"), fixed.group("reading"), int(fixed.group("index"))
            if mode == "google":
                path = "google"
            elif mode == "exact":
                path = "exact-escape"
            elif index == 0:
                path = "prefix-raw"
            else:
                path = "prefix-top1" if index == 1 else "prefix-lower"
            commits.append({"timestamp": fixed.group("timestamp"), "path": path, "input": reading,
                            "word": word, "prefixRank": prefix_rank(reading, word)})
            mode = "prefix"
            continue
        if (kana := KANA_FIXED_RE.match(line)) is not None:
            word, reading = kana.group("word"), kana.group("input")
            head = last_head.get(reading, [])
            if not head:
                path = "kana-no-dictionary"
            elif head[0] == word:
                path = "kana-top1"
            else:
                path = "kana-other" if word in head else "kana-absent"
            commits.append({"timestamp": kana.group("timestamp"), "path": path, "input": reading,
                            "word": word, "prefixRank": prefix_rank(reading, word),
                            "prefixTop": head[0] if head else None})
            mode = "prefix"

    if cutoff is not None:
        commits = [c for c in commits if (parse_timestamp(c["timestamp"]) or cutoff) >= cutoff]
    if not commits:
        return {"count": 0}
    by_path: dict[str, int] = defaultdict(int)
    for commit in commits:
        by_path[commit["path"]] += 1
    hits = sum(by_path[p] for p in COMMIT_HIT)
    strict_misses = sum(by_path[p] for p in COMMIT_MISS if not p.startswith("kana-"))
    suspected = sum(by_path[p] for p in COMMIT_MISS if p.startswith("kana-"))
    decidable = hits + strict_misses + suspected
    escapes = [c for c in commits if c["path"] == "exact-escape"]
    return {
        "count": len(commits),
        "byPath": {path: by_path[path] for path in COMMIT_HIT + COMMIT_MISS + COMMIT_EXCLUDED},
        "decidable": decidable,
        # Headline: the first dictionary candidate was the word the user wanted.
        "firstCandidateRate": round(hits / decidable, 3) if decidable else None,
        # Lower bound on misses (kana commits trusted as intentional) and the
        # upper bound (every kana commit that differed from top1 is a miss).
        "strictMissRate": round(strict_misses / decidable, 3) if decidable else None,
        "suspectedMissRate": round((strict_misses + suspected) / decidable, 3) if decidable else None,
        "exactEscapePrefixRank": {
            "inHead": sum(1 for c in escapes if c["prefixRank"] is not None),
            "notInHead": sum(1 for c in escapes if c["prefixRank"] is None),
        },
        "examples": {
            path: [{k: v for k, v in c.items() if k != "path"} for c in commits if c["path"] == path][:examples]
            for path in COMMIT_MISS
        },
    }


COMMIT_OUTCOME_RE = re.compile(
    r"^\[(?P<timestamp>[^\]]+)\] \[input\] \[info\] "
    r'Commit outcome: input="(?P<input>[^"]*)" payload=(?P<payload>\{.*\})$'
)


def _rank_bucket(rank) -> str:
    if type(rank) is not int:
        return "absent"
    if rank <= 1:
        return str(rank)
    return "2-3" if rank <= 3 else "4-8" if rank <= 8 else "9+"


def collect_commit_diagnostics(lines: Iterable[str], cutoff: datetime | None) -> dict:
    """Explain misses from `Commit outcome` lines (every commit path).

    A miss is any commit whose word was not the first prefix candidate:
    exact/google escapes, prefix rank>=2, and kana commits whose word was not
    rank 1. For misses it reports where the word sat in the prefix list and
    whether the model review scored it (`inScoredSet=false` means the model
    could not have fixed it, whatever its quality).
    """
    by_path: dict[str, int] = defaultdict(int)
    buckets: dict[str, dict[str, int]] = {
        "byPrefixRank": defaultdict(int), "byScoredSet": defaultdict(int), "byModelOutcome": defaultdict(int),
    }
    misses = 0
    for line in lines:
        match = COMMIT_OUTCOME_RE.match(line.rstrip("\n"))
        if not match:
            continue
        if cutoff is not None:
            timestamp = parse_timestamp(match.group("timestamp"))
            if timestamp is not None and timestamp < cutoff:
                continue
        try:
            payload = json.loads(match.group("payload"))
        except json.JSONDecodeError:
            continue
        path = payload.get("path")
        if not isinstance(path, str):
            continue
        by_path[path] += 1
        rank = payload.get("prefixRank")
        if path == "deactivation" or (path == "prefix" and rank in (0, 1)):
            continue
        if path.startswith("kana-") and rank == 1:
            continue
        misses += 1
        buckets["byPrefixRank"][_rank_bucket(rank)] += 1
        scored = payload.get("inScoredSet")
        buckets["byScoredSet"]["noReview" if scored is None else "scored" if scored else "notScored"] += 1
        buckets["byModelOutcome"][str(payload.get("modelOutcome") or payload.get("modelState") or "no-trace")] += 1
    if not by_path:
        return {"count": 0}
    return {
        "count": sum(by_path.values()),
        "byPath": dict(sorted(by_path.items())),
        "missCount": misses,
        "misses": {name: dict(sorted(values.items())) for name, values in buckets.items()},
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
        "modelEffect": collect_model_effect(lines, cutoff),
        "commitOutcomes": collect_commit_outcomes(lines, cutoff, examples=args.examples),
        "commitDiagnostics": collect_commit_diagnostics(lines, cutoff),
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
    print("\n## commit outcomes (all commit paths)")
    outcomes = {k: v for k, v in result["commitOutcomes"].items() if k != "examples"}
    print(json.dumps(outcomes, ensure_ascii=False, indent=2))
    print("\n## commit diagnostics (Commit outcome lines)")
    print(json.dumps(result["commitDiagnostics"], ensure_ascii=False, indent=2))
    print("\n## model effect (vs heuristic-only order)")
    print(json.dumps(result["modelEffect"], ensure_ascii=False, indent=2))
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
