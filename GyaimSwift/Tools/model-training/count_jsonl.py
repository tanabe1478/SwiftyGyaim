#!/usr/bin/env python3
"""Count large JSONL files without loading them into memory."""

from __future__ import annotations

import argparse
import math
from pathlib import Path

CHUNK_SIZE = 64 * 1024 * 1024


def count_lines(path: Path) -> int:
    count = 0
    last_byte = b""
    with open(path, "rb") as file:
        while chunk := file.read(CHUNK_SIZE):
            count += chunk.count(b"\n")
            last_byte = chunk[-1:]
    if path.stat().st_size and last_byte != b"\n":
        count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", type=Path, nargs="+")
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--grad-accum", type=int, default=1)
    args = parser.parse_args()

    if args.batch_size <= 0 or args.grad_accum <= 0:
        parser.error("--batch-size and --grad-accum must be positive")
    missing = [path for path in args.paths if not path.is_file()]
    if missing:
        parser.error("input file not found: " + ", ".join(map(str, missing)))

    total = 0
    for path in args.paths:
        lines = count_lines(path)
        total += lines
        print(f"{path}: {lines:,} rows")
    examples_per_step = args.batch_size * args.grad_accum
    max_steps = math.ceil(total / examples_per_step)
    print(f"total: {total:,} rows")
    print(f"examples per optimizer step: {examples_per_step:,}")
    print(f"max_steps for one pass: {max_steps:,}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
