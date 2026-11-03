#!/usr/bin/env python3
"""Upload log-derived training data to a private Hugging Face dataset repo.

The files hold the user's own sentences (redacted, but still personal), so
they are not tracked in the public source repository (README). This script
puts them in a private dataset repo for the training machine to pull.

Safety:
- Creates the repo as private when missing, and refuses to upload when an
  existing repo is not private.
- Authentication comes from `hf auth login` or the HF_TOKEN environment
  variable; the token is never printed.

Usage:
  python3 push_domain_data.py                      # defaults below
  python3 push_domain_data.py --repo me/gyaim-domain-data \
      --file ~/.gyaim/eval/domain-2026-11.jsonl --file data/domain-valid.jsonl

Pull on the training machine:
  hf download <repo> --repo-type dataset --local-dir data/
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

DEFAULT_REPO = "tanabe1478/gyaim-domain-data"
DEFAULT_FILES = [
    Path.home() / ".gyaim/eval/domain-2026-11.jsonl",
    Path(__file__).parent / "data/domain-valid.jsonl",
    Path(__file__).parent / "data/rerank-valid.jsonl",
]

CARD = """---
license: other
pretty_name: SwiftyGyaim domain data (private)
---

# SwiftyGyaim domain data

Kana-kanji conversion pairs built from one user's SwiftyGyaim typing logs with
`GyaimSwift/Tools/model-training/build_sft_dataset.py` (issue #125):

- `domain-*.jsonl`: {input (katakana), output, left_context} for picked candidates
  and kana confirms, retype-corrected, context cut to the runtime's 20 characters
  with 10 / 5 / 0 character variants
- `domain-valid.jsonl`, `rerank-valid.jsonl`: held-out rows used by
  `evaluate_domain_valid.py` / `evaluate_rerank.py`

URLs, long ASCII identifiers and digit runs are removed, but the contexts are the
user's own sentences. Keep this repository private; do not redistribute.
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--file", action="append", type=Path, help="file to upload (repeatable)")
    parser.add_argument("--prefix", default="data", help="folder inside the repo")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    files = args.file or DEFAULT_FILES
    missing = [f for f in files if not f.exists()]
    if missing:
        print("missing:", *missing, file=sys.stderr)
        return 1
    if args.dry_run:
        for f in files:
            print(f"would upload {f} -> {args.repo}:{args.prefix}/{f.name} ({f.stat().st_size} bytes)")
        return 0

    from huggingface_hub import HfApi  # imported late so --dry-run works without it

    api = HfApi(token=os.environ.get("HF_TOKEN") or None)
    api.create_repo(args.repo, repo_type="dataset", private=True, exist_ok=True)
    info = api.repo_info(args.repo, repo_type="dataset")
    if not info.private:
        print(f"refusing: {args.repo} is not private", file=sys.stderr)
        return 2
    api.upload_file(path_or_fileobj=CARD.encode("utf-8"), path_in_repo="README.md",
                    repo_id=args.repo, repo_type="dataset")
    for f in files:
        api.upload_file(path_or_fileobj=str(f), path_in_repo=f"{args.prefix}/{f.name}",
                        repo_id=args.repo, repo_type="dataset")
        print(f"uploaded {f.name}")
    print(f"done: https://huggingface.co/datasets/{args.repo} (private)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
