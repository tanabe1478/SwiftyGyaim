#!/usr/bin/env python3
"""Sweep lightweight fast-context heuristic feature multipliers.

This is a small offline helper for exploring how much room exists before model
fine-tuning. It reuses evaluate-fast-context-rerank.py and only changes feature
multipliers in the Python lightweight evaluator; it does not change Swift runtime
weights by itself.
"""

from __future__ import annotations

import argparse
import importlib.util
import itertools
import json
import sys
from pathlib import Path
from typing import Any

GYAIM_SWIFT_DIR = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = GYAIM_SWIFT_DIR / "Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl"
EVALUATOR_PATH = Path(__file__).with_name("evaluate-fast-context-rerank.py")
DEFAULT_SWEEP = {
    "contextPredictionBonus": [0.75, 1.0, 1.25, 1.5],
    "prefixPredictionPenalty": [0.75, 1.0, 1.25],
    "punctuationSuffixPenalty": [0.5, 1.0, 1.5],
}


class SweepError(Exception):
    pass


def load_evaluator():
    spec = importlib.util.spec_from_file_location("fast_context_evaluator", EVALUATOR_PATH)
    if spec is None or spec.loader is None:
        raise SweepError(f"failed to load evaluator: {EVALUATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def parse_sweep(values: list[str]) -> dict[str, list[float]]:
    if not values:
        return DEFAULT_SWEEP
    result: dict[str, list[float]] = {}
    for value in values:
        if "=" not in value:
            raise SweepError(f"sweep must be FEATURE=v1,v2,...: {value}")
        feature, raw_values = value.split("=", 1)
        feature = feature.strip()
        if not feature:
            raise SweepError(f"feature name must not be empty: {value}")
        try:
            multipliers = [float(item) for item in raw_values.split(",") if item.strip()]
        except ValueError as exc:
            raise SweepError(f"sweep values must be numeric: {value}") from exc
        if not multipliers:
            raise SweepError(f"sweep must include at least one multiplier: {value}")
        result[feature] = multipliers
    return result


def iter_weight_sets(sweep: dict[str, list[float]]):
    features = sorted(sweep)
    for values in itertools.product(*(sweep[feature] for feature in features)):
        yield dict(zip(features, values))


def evaluate(evaluator, records: list[dict[str, Any]], weights: dict[str, float], context_mode: str) -> dict[str, Any]:
    results = [
        evaluator.evaluate_record(
            record,
            backend="heuristic",
            command=None,
            timeout_ms=1200,
            context_mode=context_mode,
            feature_weights=weights,
        )
        for record in records
    ]
    summary = evaluator.summarize(results)
    return {
        "weights": weights,
        "summary": {
            "top1Accuracy": summary["top1Accuracy"],
            "top1Correct": summary["top1Correct"],
            "top3Accuracy": summary["top3Accuracy"],
            "unsafeTopCount": summary["unsafeTopCount"],
            "exactDemotionCount": summary["exactDemotionCount"],
        },
        "failures": [
            {
                "id": result.id,
                "expectedTop": result.expectedTop,
                "predictedTop": result.predictedTop,
                "unsafeTop": result.unsafeTop,
                "exactDemotion": result.exactDemotion,
            }
            for result in results
            if not result.top1 or result.unsafeTop or result.exactDemotion
        ],
    }


def sort_key(item: dict[str, Any]) -> tuple:
    summary = item["summary"]
    return (
        summary["unsafeTopCount"],
        summary["exactDemotionCount"],
        -summary["top1Correct"],
        json.dumps(item["weights"], sort_keys=True),
    )


def print_text(items: list[dict[str, Any]], *, limit: int) -> None:
    print("# fast-context feature weight sweep")
    print("rank\ttop1\ttop3\tunsafe\texactDemotion\tweights")
    for rank, item in enumerate(items[:limit], start=1):
        summary = item["summary"]
        print(
            f"{rank}\t{summary['top1Correct']}\t{summary['top3Accuracy']}\t"
            f"{summary['unsafeTopCount']}\t{summary['exactDemotionCount']}\t"
            f"{json.dumps(item['weights'], ensure_ascii=False, sort_keys=True)}"
        )
        if item["failures"]:
            for failure in item["failures"][:3]:
                print(f"  - {failure['id']}: expected={failure['expectedTop']} predicted={failure['predictedTop']}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Sweep fast-context lightweight heuristic feature multipliers.")
    parser.add_argument("fixture", nargs="?", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument(
        "--sweep",
        action="append",
        default=[],
        metavar="FEATURE=v1,v2,...",
        help="Feature multipliers to sweep. Can be repeated. Defaults to a small built-in grid.",
    )
    parser.add_argument("--context-mode", choices=["fixture", "none"], default="fixture")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    evaluator = load_evaluator()
    records = evaluator.load_and_validate(args.fixture)
    sweep = parse_sweep(args.sweep)
    items = sorted(
        (evaluate(evaluator, records, weights, args.context_mode) for weights in iter_weight_sets(sweep)),
        key=sort_key,
    )

    if args.json:
        print(json.dumps({"fixture": str(args.fixture), "sweep": sweep, "results": items}, ensure_ascii=False, indent=2))
    else:
        print_text(items, limit=args.limit)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SweepError as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
