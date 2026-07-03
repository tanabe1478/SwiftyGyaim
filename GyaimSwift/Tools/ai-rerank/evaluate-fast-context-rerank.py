#!/usr/bin/env python3
"""Evaluate fast-context-rerank fixtures offline.

The default backend is a dependency-free Python port of AIReranker.localRerank.
It is intentionally lightweight so it can run in CI and during dogfooding without
loading the bundled Zenz GGUF.

A command backend is also provided as an opt-in integration point for heavier
model experiments. The command receives an AIRerankRequest JSON on stdin and must
print an AIRerankResponse JSON on stdout.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import time
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from statistics import mean, median
from typing import Any

GYAIM_SWIFT_DIR = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = GYAIM_SWIFT_DIR / "Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl"
VALIDATOR_PATH = Path(__file__).with_name("validate-fast-context-eval-cases.py")
PROTECTED_EXACT_KINDS = {"exact", "compound"}


class EvaluationError(Exception):
    pass


@dataclass(frozen=True)
class CandidateScore:
    index: int
    text: str
    score: float


@dataclass(frozen=True)
class CaseResult:
    id: str
    inputPat: str
    expectedTop: str
    predictedTop: str | None
    expectedIndex: int | None
    predictedIndex: int | None
    order: list[int]
    top1: bool
    top3: bool
    unsafeTop: bool
    exactDemotion: bool
    outcome: str
    latencyMs: float
    scores: dict[str, float] | None
    featureBreakdown: dict[str, Any] | None
    tags: list[str]
    reason: str


def load_and_validate(path: Path) -> list[dict[str, Any]]:
    spec = importlib.util.spec_from_file_location("fast_context_eval_validator", VALIDATOR_PATH)
    if spec is None or spec.loader is None:
        raise EvaluationError(f"failed to load validator: {VALIDATOR_PATH}")
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    records = validator.load_jsonl(path)
    validator.validate(records)
    return records


def make_request(record: dict[str, Any], *, context_mode: str) -> dict[str, Any]:
    context = record["context"] if context_mode == "fixture" else ""
    return {
        "version": 1,
        "mode": "fast-context-rerank",
        "inputPat": record["inputPat"],
        "hiragana": record["inputKana"],
        "context": context or None,
        "candidates": [
            {
                "index": index,
                "text": candidate["text"],
                "reading": candidate.get("reading"),
                "source": candidate["source"],
                "kind": candidate["kind"],
                "contextAffinity": candidate.get("contextAffinity"),
                "studyFrequency": candidate.get("studyFrequency"),
            }
            for index, candidate in enumerate(record["candidates"])
        ],
    }


def expected_top(record: dict[str, Any], *, context_mode: str) -> str:
    if context_mode == "none" and record.get("expectedTopWithoutContext"):
        return record["expectedTopWithoutContext"]
    return record["expectedTop"]


def run_heuristic_backend(request: dict[str, Any], feature_weights: dict[str, float] | None = None) -> dict[str, Any]:
    scores: dict[str, float] = {}
    features: dict[str, dict[str, Any]] = {}
    scored: list[CandidateScore] = []
    for candidate in request["candidates"]:
        contributions = local_score_breakdown(candidate, request, feature_weights=feature_weights)
        score = sum(contributions.values())
        index = int(candidate["index"])
        scores[str(index)] = score
        features[str(index)] = {
            "text": candidate["text"],
            "total": round(score, 6),
            "contributions": {key: round(value, 6) for key, value in contributions.items() if value != 0},
        }
        scored.append(CandidateScore(index=index, text=candidate["text"], score=score))
    order = [item.index for item in sorted(scored, key=lambda item: (-item.score, item.index))]
    return {"order": order, "scores": scores, "features": features, "model": "python-swift-local-heuristic"}


def run_command_backend(request: dict[str, Any], command: str, timeout_ms: int) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            ["/bin/zsh", "-lc", command],
            input=json.dumps(request, ensure_ascii=False).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_ms / 1000.0,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise EvaluationError(f"command backend timed out after {timeout_ms}ms") from exc
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        raise EvaluationError(f"command backend failed with status {completed.returncode}: {stderr}")
    try:
        response = json.loads(completed.stdout.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise EvaluationError(f"command backend returned invalid JSON: {exc}") from exc
    if not isinstance(response, dict) or not isinstance(response.get("order"), list):
        raise EvaluationError("command backend response must contain an order array")
    return response


def validated_order(proposed_order: list[Any], candidate_count: int) -> list[int]:
    seen: set[int] = set()
    result: list[int] = []
    for raw_index in proposed_order:
        if not isinstance(raw_index, int):
            continue
        if 0 <= raw_index < candidate_count and raw_index not in seen:
            seen.add(raw_index)
            result.append(raw_index)
    for index in range(candidate_count):
        if index not in seen:
            result.append(index)
    return result


def evaluate_record(
    record: dict[str, Any],
    *,
    backend: str,
    command: str | None,
    timeout_ms: int,
    context_mode: str,
    feature_weights: dict[str, float] | None = None,
) -> CaseResult:
    request = make_request(record, context_mode=context_mode)
    start = time.perf_counter()
    if backend == "heuristic":
        response = run_heuristic_backend(request, feature_weights=feature_weights)
    elif backend == "command":
        if not command:
            raise EvaluationError("command backend requires --command or GYAIM_FAST_CONTEXT_EVAL_COMMAND")
        response = run_command_backend(request, command, timeout_ms)
    else:
        raise EvaluationError(f"unknown backend: {backend}")
    latency_ms = (time.perf_counter() - start) * 1000.0

    order = validated_order(response.get("order", []), len(record["candidates"]))
    predicted_index = order[0] if order else None
    predicted_top = record["candidates"][predicted_index]["text"] if predicted_index is not None else None
    expected = expected_top(record, context_mode=context_mode)
    expected_index = next(
        (index for index, candidate in enumerate(record["candidates"]) if candidate["text"] == expected),
        None,
    )
    top3_texts = [record["candidates"][index]["text"] for index in order[:3]]
    unsafe_top = predicted_top in set(record["mustNotTop"])
    exact_demotion = is_expected_protected_exact(record, expected) and predicted_top != expected
    return CaseResult(
        id=record["id"],
        inputPat=record["inputPat"],
        expectedTop=expected,
        predictedTop=predicted_top,
        expectedIndex=expected_index,
        predictedIndex=predicted_index,
        order=order,
        top1=predicted_top == expected,
        top3=expected in top3_texts,
        unsafeTop=unsafe_top,
        exactDemotion=exact_demotion,
        outcome=infer_outcome(response.get("model")),
        latencyMs=latency_ms,
        scores=response.get("scores"),
        featureBreakdown=response.get("features"),
        tags=record["tags"],
        reason=record["reason"],
    )


def is_expected_protected_exact(record: dict[str, Any], expected: str) -> bool:
    for candidate in record["candidates"]:
        if candidate["text"] == expected:
            return candidate.get("reading") == record["inputPat"] and candidate.get("kind") in PROTECTED_EXACT_KINDS
    return False


def infer_outcome(model: Any) -> str:
    value = str(model or "unknown")
    if "review-skipped" in value:
        return "protected-exact-skip"
    if "review-exact-homophone-unavailable" in value:
        return "exact-homophone-unavailable"
    if "review-exact-homophone-fixed" in value:
        return "exact-homophone-fixed"
    if "review-exact-homophone-kept-local" in value:
        return "exact-homophone-kept-local"
    if "review-exact-homophone-passed" in value:
        return "exact-homophone-passed"
    if "review-unavailable" in value:
        return "review-unavailable"
    if "review-fixed" in value:
        return "review-fixed"
    if "review-kept-local" in value:
        return "review-kept-local"
    if "review-passed" in value:
        return "review-passed"
    if "review" in value:
        return "review-applied"
    if "heuristic" in value:
        return "heuristic"
    return "fallback"


def local_score(candidate: dict[str, Any], request: dict[str, Any]) -> float:
    return sum(local_score_breakdown(candidate, request).values())


def local_score_breakdown(
    candidate: dict[str, Any],
    request: dict[str, Any],
    *,
    feature_weights: dict[str, float] | None = None,
) -> dict[str, float]:
    contributions: dict[str, float] = {
        "positionPenalty": -float(candidate["index"]) * 0.03,
        "sourceBias": source_bias(candidate["source"]),
        "kindBias": kind_bias(candidate["kind"]),
    }
    if candidate.get("reading") == request["inputPat"]:
        contributions["exactReadingMatchBonus"] = 0.20
        if candidate["kind"] == "exact":
            contributions["exactReadingKindBonus"] = exact_reading_bonus(candidate["text"])
    else:
        contributions["prefixPredictionPenalty"] = -prefix_prediction_penalty(candidate, request["inputPat"])
    contributions["contextPredictionBonus"] = context_prediction_bonus(candidate, request)
    affinity = candidate.get("contextAffinity")
    if isinstance(affinity, (int, float)) and affinity > 0:
        contributions["contextAffinityBonus"] = min(float(affinity), 1.0) * 1.50
    study_frequency = candidate.get("studyFrequency")
    if candidate["source"] == "study" and isinstance(study_frequency, int) and study_frequency > 1:
        contributions["studyFrequencyBonus"] = min(0.30, math.log2(float(study_frequency)) * 0.10)
    contributions["politeNegativePredictionPenalty"] = -polite_negative_prediction_penalty(candidate, request)
    if any(is_kanji(ch) for ch in candidate["text"]):
        contributions["kanjiBonus"] = 0.10
    contributions["naturalFunctionWordPhraseBonus"] = natural_function_word_phrase_bonus(candidate["text"])
    contributions["punctuationSuffixPenalty"] = -punctuation_suffix_penalty(candidate["text"])
    contributions["punctuatedInputMismatchPenalty"] = -punctuated_input_mismatch_penalty(candidate, request)
    contributions["incompleteStemPenalty"] = -incomplete_stem_penalty(candidate, request)
    if candidate["kind"] == "zenz" and is_all_kanji_word(candidate["text"]):
        contributions["zenzKanjiBonus"] = 0.50
    if candidate["text"] == request["inputPat"] and candidate["text"].isascii():
        contributions["rawAsciiPenalty"] = -8.0
    contributions["scriptTransitionPenalty"] = -unnatural_script_transition_penalty(candidate["text"])
    return apply_feature_weights(contributions, feature_weights)


def apply_feature_weights(contributions: dict[str, float], feature_weights: dict[str, float] | None) -> dict[str, float]:
    if not feature_weights:
        return contributions
    return {
        feature: value * feature_weights.get(feature, 1.0)
        for feature, value in contributions.items()
    }


def exact_reading_bonus(text: str) -> float:
    return 2.00 if len(text) >= 5 else 0.50


def prefix_prediction_penalty(candidate: dict[str, Any], input_pat: str) -> float:
    reading = candidate.get("reading")
    if candidate["kind"] != "prefix" or not isinstance(reading, str):
        return 0.0
    if not reading.startswith(input_pat) or reading == input_pat:
        return 0.0
    return min(1.50, float(len(reading) - len(input_pat)) * 0.35)


def context_prediction_bonus(candidate: dict[str, Any], request: dict[str, Any]) -> float:
    reading = candidate.get("reading")
    context = request.get("context")
    if candidate["kind"] != "prefix" or not isinstance(reading, str) or not isinstance(context, str):
        return 0.0
    if not reading.startswith(request["inputPat"]) or reading == request["inputPat"]:
        return 0.0
    trimmed = context.strip()
    if not trimmed:
        return 0.0
    score = 0.0
    if candidate["text"].endswith("な") and has_strong_negative_imperative_cue(trimmed):
        score += 2.00
    return score


def has_strong_negative_imperative_cue(context: str) -> bool:
    return any(cue in context for cue in ["決して", "絶対に", "してはいけ", "してはなら", "禁止", "だめ", "ダメ", "ないで"])


def polite_negative_prediction_penalty(candidate: dict[str, Any], request: dict[str, Any]) -> float:
    if not is_polite_negative_prediction(candidate["text"]):
        return 0.0
    if input_explicitly_requests_polite_negative(request["inputPat"]):
        return 0.0
    context = request.get("context")
    if isinstance(context, str) and has_polite_negative_context_cue(context.strip()):
        return 0.0
    return 4.0


def is_polite_negative_prediction(text: str) -> bool:
    return text.endswith(("ません", "ませんか", "ません？", "ませんか？"))


def input_explicitly_requests_polite_negative(input_pat: str) -> bool:
    return "masen" in input_pat or "masenn" in input_pat


def has_polite_negative_context_cue(context: str) -> bool:
    return bool(context) and any(cue in context for cue in ["ない", "ません", "ではなく", "じゃなく", "しない", "できない", "不要", "禁止"])


def natural_function_word_phrase_bonus(text: str) -> float:
    score = 0.0
    if re.search(r"[一-龯]の[一-龯]", text):
        score += 1.40
    if text.endswith(("では", "には", "とは")):
        score += 0.70
    return score


def punctuation_suffix_penalty(text: str) -> float:
    return 0.10 if text.endswith(("？", "！")) else 0.0


def punctuated_input_mismatch_penalty(candidate: dict[str, Any], request: dict[str, Any]) -> float:
    input_pat = request["inputPat"]
    if input_pat.endswith("?"):
        expected = ("?", "？")
    elif input_pat.endswith("!"):
        expected = ("!", "！")
    else:
        return 0.0
    return 0.0 if any(mark in candidate["text"] for mark in expected) else 3.0


def incomplete_stem_penalty(candidate: dict[str, Any], request: dict[str, Any]) -> float:
    text = candidate["text"]
    if not is_potential_incomplete_stem(text):
        return 0.0
    for other in request["candidates"]:
        if other["index"] != candidate["index"] and is_incomplete_stem_completion(text, other["text"]):
            return 4.0
    return 0.0


def is_potential_incomplete_stem(text: str) -> bool:
    return bool(text) and not all(is_kanji(ch) for ch in text) and any("\u3041" <= ch <= "\u3096" for ch in text)


def is_incomplete_stem_completion(stem: str, completed: str) -> bool:
    if completed == stem or not completed.startswith(stem) or len(completed) != len(stem) + 1:
        return False
    if completed[-1] == "い":
        return True
    return stem.endswith("っ")


def source_bias(source: str) -> float:
    return {
        "study": 0.40,
        "local": 0.30,
        "connection": 0.10,
        "google": 0.60,
        "external": -0.10,
        "synthetic": -0.30,
    }.get(source, 0.0)


def kind_bias(kind: str) -> float:
    return {
        "google": 0.35,
        "exact": 0.25,
        "zenz": 0.40,
        "lattice": 0.30,
        "compound": 0.20,
        "prefix": -0.10,
        "completion": -0.20,
        "kana": -0.25,
        "raw": -1.00,
    }.get(kind, 0.0)


def unnatural_script_transition_penalty(text: str) -> float:
    penalty = 0.0
    chars = list(text)
    for previous, current in zip(chars, chars[1:]):
        if is_hiragana(previous) and is_kanji(current):
            penalty += 1.50
        if is_katakana(previous) and is_hiragana(current):
            penalty += 1.00
    return penalty


def is_hiragana(ch: str) -> bool:
    return all(0x3040 <= ord(scalar) <= 0x309F for scalar in ch)


def is_katakana(ch: str) -> bool:
    return all(0x30A0 <= ord(scalar) <= 0x30FF for scalar in ch)


def is_kanji(ch: str) -> bool:
    return all(0x4E00 <= ord(scalar) <= 0x9FFF for scalar in ch)


def is_all_kanji_word(text: str) -> bool:
    return len(text) >= 2 and all(is_kanji(ch) for ch in text)


def latency_summary(results: list[CaseResult]) -> dict[str, float | int | None]:
    values = [result.latencyMs for result in results]
    if not values:
        return {"count": 0, "avgMs": None, "p50Ms": None, "p95Ms": None, "maxMs": None}
    ordered = sorted(values)
    p95_index = max(0, min(len(ordered) - 1, int((len(ordered) * 0.95) + 0.999999) - 1))
    return {
        "count": len(values),
        "avgMs": round(mean(values), 3),
        "p50Ms": round(median(values), 3),
        "p95Ms": round(ordered[p95_index], 3),
        "maxMs": round(max(values), 3),
    }


def summarize(results: list[CaseResult]) -> dict[str, Any]:
    total = len(results)
    top1 = sum(result.top1 for result in results)
    top3 = sum(result.top3 for result in results)
    unsafe = sum(result.unsafeTop for result in results)
    exact_demotions = sum(result.exactDemotion for result in results)
    return {
        "total": total,
        "top1Accuracy": round(top1 / total, 4) if total else None,
        "top3Accuracy": round(top3 / total, 4) if total else None,
        "top1Correct": top1,
        "top3Correct": top3,
        "unsafeTopCount": unsafe,
        "exactDemotionCount": exact_demotions,
        "latency": latency_summary(results),
        "outcomes": dict(sorted(Counter(result.outcome for result in results).items())),
        "byTag": summarize_by_tag(results),
    }


def summarize_by_tag(results: list[CaseResult]) -> dict[str, dict[str, Any]]:
    tags = sorted({tag for result in results for tag in result.tags})
    output: dict[str, dict[str, Any]] = {}
    for tag in tags:
        tagged = [result for result in results if tag in result.tags]
        count = len(tagged)
        output[tag] = {
            "count": count,
            "top1Accuracy": round(sum(result.top1 for result in tagged) / count, 4) if count else None,
            "unsafeTopCount": sum(result.unsafeTop for result in tagged),
            "exactDemotionCount": sum(result.exactDemotion for result in tagged),
        }
    return output


def print_text_report(summary: dict[str, Any], results: list[CaseResult], *, show_all: bool, show_features: bool) -> None:
    print("# fast-context eval")
    print(json.dumps({key: value for key, value in summary.items() if key != "byTag"}, ensure_ascii=False, indent=2))
    print("\n## by tag")
    print("tag\tcount\ttop1Accuracy\tunsafeTop\texactDemotion")
    for tag, values in summary["byTag"].items():
        print(
            f"{tag}\t{values['count']}\t{values['top1Accuracy']}\t"
            f"{values['unsafeTopCount']}\t{values['exactDemotionCount']}"
        )
    interesting = [result for result in results if show_all or not result.top1 or result.unsafeTop or result.exactDemotion]
    print("\n## cases")
    for result in interesting:
        marker = "OK" if result.top1 and not result.unsafeTop and not result.exactDemotion else "NG"
        print(
            f"{marker}\t{result.id}\texpected={result.expectedTop}\tpredicted={result.predictedTop}\t"
            f"top3={result.top3}\tunsafe={result.unsafeTop}\texactDemotion={result.exactDemotion}\t"
            f"latency={result.latencyMs:.3f}ms"
        )
        if show_features and result.featureBreakdown:
            print_feature_breakdown(result)


def print_feature_breakdown(result: CaseResult) -> None:
    indexes = []
    for index in [result.predictedIndex, result.expectedIndex]:
        if index is not None and index not in indexes:
            indexes.append(index)
    for index in indexes:
        item = result.featureBreakdown.get(str(index)) if result.featureBreakdown else None
        if not item:
            continue
        contributions = item.get("contributions", {})
        ordered = sorted(contributions.items(), key=lambda pair: abs(pair[1]), reverse=True)
        formatted = ", ".join(f"{key}={value:+.2f}" for key, value in ordered)
        role = []
        if index == result.predictedIndex:
            role.append("predicted")
        if index == result.expectedIndex:
            role.append("expected")
        print(f"  features[{index}] {item.get('text')} ({'/'.join(role)}) total={item.get('total'):+.2f}: {formatted}")


def parse_feature_weights(values: list[str]) -> dict[str, float]:
    weights: dict[str, float] = {}
    for value in values:
        if "=" not in value:
            raise EvaluationError(f"feature weight must be FEATURE=MULTIPLIER: {value}")
        feature, raw_multiplier = value.split("=", 1)
        feature = feature.strip()
        if not feature:
            raise EvaluationError(f"feature weight name must not be empty: {value}")
        try:
            multiplier = float(raw_multiplier)
        except ValueError as exc:
            raise EvaluationError(f"feature weight multiplier must be numeric: {value}") from exc
        weights[feature] = multiplier
    return weights


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate fast-context rerank fixtures offline.")
    parser.add_argument("fixture", nargs="?", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--backend", choices=["heuristic", "command"], default=None)
    parser.add_argument("--command", default=os.environ.get("GYAIM_FAST_CONTEXT_EVAL_COMMAND"))
    parser.add_argument("--timeout-ms", type=int, default=1200)
    parser.add_argument("--context-mode", choices=["fixture", "none"], default="fixture")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--show-all", action="store_true")
    parser.add_argument("--show-features", action="store_true", help="Print heuristic feature contributions for shown cases.")
    parser.add_argument(
        "--feature-weight",
        action="append",
        default=[],
        metavar="FEATURE=MULTIPLIER",
        help="Scale a heuristic feature contribution in lightweight mode. Can be repeated.",
    )
    args = parser.parse_args()

    run_zenz = os.environ.get("RUN_ZENZ") == "1"
    backend = args.backend or ("command" if run_zenz else "heuristic")
    feature_weights = parse_feature_weights(args.feature_weight)
    records = load_and_validate(args.fixture)
    results = [
        evaluate_record(
            record,
            backend=backend,
            command=args.command,
            timeout_ms=args.timeout_ms,
            context_mode=args.context_mode,
            feature_weights=feature_weights,
        )
        for record in records
    ]
    summary = summarize(results)
    output = {
        "fixture": str(args.fixture),
        "backend": backend,
        "contextMode": args.context_mode,
        "featureWeights": feature_weights,
        "summary": summary,
        "failures": [asdict(result) for result in results if not result.top1 or result.unsafeTop or result.exactDemotion],
        "cases": [asdict(result) for result in results] if args.show_all else None,
    }

    if args.json:
        print(json.dumps(output, ensure_ascii=False, indent=2))
    else:
        print_text_report(summary, results, show_all=args.show_all, show_features=args.show_features)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EvaluationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
