#!/usr/bin/env python3
"""Sample a training subset from Miwa-Keita/zenz-v2.5-dataset via streaming.

Full dataset is ~190M pairs / 36.5GB. For local baseline training we stream
the head of each split through a shuffle buffer and write train/valid JSONL
in the same schema ({input, output, left_context}) that train_zenz.py reads.

Note: streaming reads from the start of each file, so the sample is biased
toward early records (Wikipedia article order / crawl order). Acceptable for
the v0 baseline; a full-shuffle sample needs the downloaded file.

Example:

    .venv/bin/python3 prepare_dataset.py --wikipedia 700000 --llm-jp 300000 \
        --valid 5000 --output data/
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

from datasets import load_dataset

DATASET = "Miwa-Keita/zenz-v2.5-dataset"
FILES = {
    "wikipedia": "train_wikipedia.jsonl",
    "llm-jp": "train_llm-jp-corpus-v3.jsonl",
}


def stream_rows(data_file: str, count: int, seed: int, buffer_size: int):
    ds = load_dataset(DATASET, data_files=data_file, split="train", streaming=True)
    ds = ds.shuffle(seed=seed, buffer_size=buffer_size)
    taken = 0
    for row in ds:
        if taken >= count:
            break
        if not row.get("input") or not row.get("output"):
            continue
        yield {
            "input": row["input"],
            "output": row["output"],
            "left_context": row.get("left_context"),
        }
        taken += 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wikipedia", type=int, default=700_000)
    parser.add_argument("--llm-jp", dest="llm_jp", type=int, default=300_000)
    parser.add_argument("--valid", type=int, default=5_000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--buffer-size", type=int, default=100_000)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "data")
    parser.add_argument("--domain", type=Path,
                        help="build_sft_dataset.py が出力したドメインJSONL")
    parser.add_argument("--domain-oversample", type=int, default=30,
                        help="ドメイン行をtrainに複製する回数")
    parser.add_argument("--domain-valid", type=int, default=60,
                        help="ドメイン行からdomain-valid.jsonlへ取り分ける件数")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, count in (("wikipedia", args.wikipedia), ("llm-jp", args.llm_jp)):
        if count <= 0:
            continue
        print(f"streaming {name}: {count} rows...")
        rows.extend(stream_rows(FILES[name], count, args.seed, args.buffer_size))
        print(f"  total so far: {len(rows)}")

    random.Random(args.seed).shuffle(rows)
    valid = rows[: args.valid]
    train = rows[args.valid :]

    domain_valid = []
    if args.domain:
        domain_rows = [json.loads(line) for line in open(args.domain, encoding="utf-8") if line.strip()]
        random.Random(args.seed).shuffle(domain_rows)
        domain_valid = domain_rows[: args.domain_valid]
        domain_train = domain_rows[args.domain_valid :]
        train.extend(domain_train * args.domain_oversample)
        random.Random(args.seed + 1).shuffle(train)
        print(f"domain: train {len(domain_train)}x{args.domain_oversample} rows, valid {len(domain_valid)} rows")

    splits = [("train", train), ("valid", valid)]
    if domain_valid:
        splits.append(("domain-valid", domain_valid))
    for split, data in splits:
        path = args.output / f"{split}.jsonl"
        with open(path, "w", encoding="utf-8") as f:
            for row in data:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        print(f"wrote {path}: {len(data)} rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
