#!/usr/bin/env python3
"""Learn fast-context heuristic feature multipliers from eval fixtures.

Pairwise logistic regression over the existing feature breakdown: for each eval
case, the expectedTop candidate should outscore every other candidate. Each
feature keeps its hand-tuned base contribution; this script learns a multiplier
per feature (initialized to 1.0, L2-regularized toward 1.0, clamped to >= 0) so
the result stays interpretable and can be applied with
`evaluate-fast-context-rerank.py --feature-weight FEATURE=MULTIPLIER` or folded
back into AIReranker.swift by hand.

Dependency-free (no numpy). Intended for the seed fixture and for preference
JSONL converted to the same schema (M6-2 pairwise reranker groundwork).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import sys
from pathlib import Path
from typing import Any

EVALUATOR_PATH = Path(__file__).with_name("evaluate-fast-context-rerank.py")
GYAIM_SWIFT_DIR = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = GYAIM_SWIFT_DIR / "Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl"


class TrainingError(Exception):
    pass


def load_evaluator():
    spec = importlib.util.spec_from_file_location("fast_context_evaluator", EVALUATOR_PATH)
    if spec is None or spec.loader is None:
        raise TrainingError(f"failed to load evaluator: {EVALUATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def build_pairs(
    evaluator,
    records: list[dict[str, Any]],
    *,
    exclude_tags: set[str],
) -> tuple[list[dict[str, float]], list[str]]:
    """Return pairwise difference vectors (expected minus rival) and case ids."""
    pairs: list[dict[str, float]] = []
    case_ids: list[str] = []
    for record in records:
        if exclude_tags & set(record["tags"]):
            continue
        request = evaluator.make_request(record, context_mode="fixture")
        expected = evaluator.expected_top(record, context_mode="fixture")
        breakdowns = [
            evaluator.local_score_breakdown(candidate, request)
            for candidate in request["candidates"]
        ]
        expected_index = next(
            (index for index, candidate in enumerate(record["candidates"]) if candidate["text"] == expected),
            None,
        )
        if expected_index is None:
            continue
        for rival_index in range(len(record["candidates"])):
            if rival_index == expected_index:
                continue
            features = set(breakdowns[expected_index]) | set(breakdowns[rival_index])
            diff = {
                feature: breakdowns[expected_index].get(feature, 0.0) - breakdowns[rival_index].get(feature, 0.0)
                for feature in features
            }
            diff = {feature: value for feature, value in diff.items() if value != 0.0}
            if diff:
                pairs.append(diff)
                case_ids.append(record["id"])
    return pairs, case_ids


def pair_score(weights: dict[str, float], diff: dict[str, float]) -> float:
    return sum(weights.get(feature, 1.0) * value for feature, value in diff.items())


def loss_and_accuracy(weights: dict[str, float], pairs: list[dict[str, float]], l2: float) -> tuple[float, float]:
    total = 0.0
    correct = 0
    for diff in pairs:
        score = pair_score(weights, diff)
        # log(1 + exp(-s)) computed stably
        total += math.log1p(math.exp(-abs(score))) + max(0.0, -score)
        if score > 0:
            correct += 1
    regularizer = l2 * sum((weight - 1.0) ** 2 for weight in weights.values())
    return total / max(1, len(pairs)) + regularizer, correct / max(1, len(pairs))


def train(
    pairs: list[dict[str, float]],
    *,
    epochs: int,
    learning_rate: float,
    l2: float,
    frozen: set[str],
) -> dict[str, float]:
    features = sorted({feature for diff in pairs for feature in diff})
    weights = {feature: 1.0 for feature in features}
    count = max(1, len(pairs))
    for _ in range(epochs):
        gradients = {feature: 0.0 for feature in features}
        for diff in pairs:
            score = pair_score(weights, diff)
            # d/dw of log(1+exp(-s)) = -sigmoid(-s) * x
            sigmoid = 1.0 / (1.0 + math.exp(min(50.0, max(-50.0, score))))
            for feature, value in diff.items():
                gradients[feature] -= sigmoid * value
        for feature in features:
            if feature in frozen:
                continue
            gradient = gradients[feature] / count + 2.0 * l2 * (weights[feature] - 1.0)
            weights[feature] = max(0.0, weights[feature] - learning_rate * gradient)
    return weights


def evaluate_top1(evaluator, records: list[dict[str, Any]], weights: dict[str, float] | None) -> dict[str, Any]:
    results = [
        evaluator.evaluate_record(
            record,
            backend="heuristic",
            command=None,
            timeout_ms=1200,
            context_mode="fixture",
            feature_weights=weights,
        )
        for record in records
    ]
    summary = evaluator.summarize(results)
    return {
        "top1Accuracy": summary["top1Accuracy"],
        "top1Correct": summary["top1Correct"],
        "unsafeTopCount": summary["unsafeTopCount"],
        "exactDemotionCount": summary["exactDemotionCount"],
        "total": summary["total"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Learn fast-context heuristic feature multipliers (pairwise).")
    parser.add_argument("fixture", nargs="?", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--learning-rate", type=float, default=0.05)
    parser.add_argument("--l2", type=float, default=0.05,
                        help="L2 strength pulling multipliers toward 1.0 (keeps hand-tuned scale).")
    parser.add_argument("--exclude-tag", action="append", default=["model-required"],
                        help="Skip cases with this tag. Default skips model-required cases "
                             "(unlearnable by heuristic features).")
    parser.add_argument("--freeze", action="append", default=[],
                        help="Feature name whose multiplier stays 1.0. Can be repeated.")
    parser.add_argument("--min-delta", type=float, default=0.01,
                        help="Only report multipliers differing from 1.0 by at least this amount.")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    evaluator = load_evaluator()
    records = evaluator.load_and_validate(args.fixture)
    exclude_tags = set(args.exclude_tag)
    pairs, _ = build_pairs(evaluator, records, exclude_tags=exclude_tags)
    if not pairs:
        raise TrainingError("no training pairs were produced from the fixture")

    baseline_weights = {feature: 1.0 for diff in pairs for feature in diff}
    initial_loss, initial_accuracy = loss_and_accuracy(baseline_weights, pairs, args.l2)
    weights = train(pairs,
                    epochs=args.epochs,
                    learning_rate=args.learning_rate,
                    l2=args.l2,
                    frozen=set(args.freeze))
    final_loss, final_accuracy = loss_and_accuracy(weights, pairs, args.l2)

    before = evaluate_top1(evaluator, records, None)
    after = evaluate_top1(evaluator, records, weights)
    changed = {
        feature: round(weight, 4)
        for feature, weight in sorted(weights.items())
        if abs(weight - 1.0) >= args.min_delta
    }
    recommendation = [f"--feature-weight {feature}={weight}" for feature, weight in changed.items()]
    output = {
        "fixture": str(args.fixture),
        "pairs": len(pairs),
        "excludedTags": sorted(exclude_tags),
        "epochs": args.epochs,
        "learningRate": args.learning_rate,
        "l2": args.l2,
        "initial": {"pairwiseLoss": round(initial_loss, 6), "pairwiseAccuracy": round(initial_accuracy, 4)},
        "final": {"pairwiseLoss": round(final_loss, 6), "pairwiseAccuracy": round(final_accuracy, 4)},
        "fixtureTop1Before": before,
        "fixtureTop1After": after,
        "weights": {feature: round(weight, 4) for feature, weight in sorted(weights.items())},
        "changedWeights": changed,
        "recommendedArgs": recommendation,
    }

    if args.json:
        print(json.dumps(output, ensure_ascii=False, indent=2))
    else:
        print("# fast-context pairwise weight training")
        for key in ["fixture", "pairs", "excludedTags", "initial", "final",
                    "fixtureTop1Before", "fixtureTop1After"]:
            print(f"{key}: {json.dumps(output[key], ensure_ascii=False)}")
        print("\n## learned multipliers (|w - 1| >= min-delta)")
        if changed:
            for feature, weight in changed.items():
                print(f"{feature}\t{weight}")
            print("\n## evaluator invocation")
            print("python3 Tools/ai-rerank/evaluate-fast-context-rerank.py " + " ".join(recommendation))
        else:
            print("(none — current hand-tuned weights already satisfy the training pairs)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except TrainingError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
