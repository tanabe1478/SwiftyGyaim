#!/usr/bin/env python3
"""Validate fast-context-rerank evaluation JSONL fixtures."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

GYAIM_SWIFT_DIR = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = GYAIM_SWIFT_DIR / "Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl"

REQUIRED_FIELDS = {
    "id",
    "inputPat",
    "inputKana",
    "context",
    "candidates",
    "expectedTop",
    "mustNotTop",
    "tags",
    "reason",
}

OPTIONAL_FIELDS = {"expectedTopWithoutContext"}

CANDIDATE_REQUIRED_FIELDS = {"text", "reading", "source", "kind"}

KNOWN_KINDS = {
    "raw",
    "exact",
    "prefix",
    "compound",
    "lattice",
    "completion",
    "zenz",
    "google",
    "kana",
}

KNOWN_TAGS = {
    "fast-context",
    "exact-protection",
    "prefix-promotion",
    "negative-imperative",
    "adjective-conjugation",
    "verb-conjugation",
    "connection-internal-label",
    "compound",
    "user-dict",
    "proper-noun",
    "short-input",
    "latency-sensitive",
}


class ValidationError(Exception):
    pass


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line_number, line in enumerate(f, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                value = json.loads(stripped)
            except json.JSONDecodeError as exc:
                raise ValidationError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if not isinstance(value, dict):
                raise ValidationError(f"{path}:{line_number}: record must be an object")
            value["__line"] = line_number
            records.append(value)
    return records


def require_string(record: dict[str, Any], field: str) -> None:
    if not isinstance(record.get(field), str) or not record[field]:
        raise ValidationError(f"line {record['__line']}: {field} must be a non-empty string")


def require_string_list(record: dict[str, Any], field: str, *, allow_empty: bool) -> None:
    value = record.get(field)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValidationError(f"line {record['__line']}: {field} must be a string array")
    if not allow_empty and not value:
        raise ValidationError(f"line {record['__line']}: {field} must not be empty")


def validate_candidate(record: dict[str, Any], candidate: Any, index: int) -> None:
    line = record["__line"]
    if not isinstance(candidate, dict):
        raise ValidationError(f"line {line}: candidates[{index}] must be an object")
    missing = CANDIDATE_REQUIRED_FIELDS - set(candidate)
    if missing:
        raise ValidationError(f"line {line}: candidates[{index}] missing fields: {sorted(missing)}")
    for field in CANDIDATE_REQUIRED_FIELDS:
        if not isinstance(candidate.get(field), str) or not candidate[field]:
            raise ValidationError(f"line {line}: candidates[{index}].{field} must be a non-empty string")
    if candidate["kind"] not in KNOWN_KINDS:
        raise ValidationError(f"line {line}: candidates[{index}].kind is unknown: {candidate['kind']}")


def validate_record(record: dict[str, Any], seen_ids: set[str]) -> None:
    line = record["__line"]
    fields = set(record) - {"__line"}
    missing = REQUIRED_FIELDS - fields
    extra = fields - REQUIRED_FIELDS - OPTIONAL_FIELDS
    if missing:
        raise ValidationError(f"line {line}: missing fields: {sorted(missing)}")
    if extra:
        raise ValidationError(f"line {line}: unknown fields: {sorted(extra)}")

    for field in ["id", "inputPat", "inputKana", "expectedTop", "reason"]:
        require_string(record, field)
    if not isinstance(record.get("context"), str):
        raise ValidationError(f"line {line}: context must be a string")
    require_string_list(record, "mustNotTop", allow_empty=True)
    require_string_list(record, "tags", allow_empty=False)

    if record["id"] in seen_ids:
        raise ValidationError(f"line {line}: duplicate id: {record['id']}")
    seen_ids.add(record["id"])

    candidates = record.get("candidates")
    if not isinstance(candidates, list) or len(candidates) < 2:
        raise ValidationError(f"line {line}: candidates must contain at least two candidates")
    for index, candidate in enumerate(candidates):
        validate_candidate(record, candidate, index)

    candidate_texts = [candidate["text"] for candidate in candidates]
    if record["expectedTop"] not in candidate_texts:
        raise ValidationError(f"line {line}: expectedTop is not present in candidates: {record['expectedTop']}")
    for value in record["mustNotTop"]:
        if value not in candidate_texts:
            raise ValidationError(f"line {line}: mustNotTop value is not present in candidates: {value}")
    if "expectedTopWithoutContext" in record and record["expectedTopWithoutContext"] not in candidate_texts:
        raise ValidationError(
            f"line {line}: expectedTopWithoutContext is not present in candidates: "
            f"{record['expectedTopWithoutContext']}"
        )

    unknown_tags = set(record["tags"]) - KNOWN_TAGS
    if unknown_tags:
        raise ValidationError(f"line {line}: unknown tags: {sorted(unknown_tags)}")


def validate(records: list[dict[str, Any]]) -> dict[str, Any]:
    seen_ids: set[str] = set()
    for record in records:
        validate_record(record, seen_ids)
    tags = Counter(tag for record in records for tag in record["tags"])
    kinds = Counter(candidate["kind"] for record in records for candidate in record["candidates"])
    return {
        "records": len(records),
        "tags": dict(sorted(tags.items())),
        "candidateKinds": dict(sorted(kinds.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate fast-context eval JSONL fixtures.")
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        default=[DEFAULT_FIXTURE],
    )
    args = parser.parse_args()

    all_records: list[dict[str, Any]] = []
    for path in args.paths:
        all_records.extend(load_jsonl(path))
    summary = validate(all_records)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
