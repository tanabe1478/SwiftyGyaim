#!/usr/bin/env python3
"""Tiny SwiftyGyaim AI rerank client for the resident GPT-2 char server.

Set this script as GYAIM_AI_RERANK_COMMAND / aiRerankCommand.  It forwards stdin
JSON to the resident server and prints the response JSON to stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_URL = os.environ.get("GYAIM_GPT2_RERANK_SERVER", "http://127.0.0.1:8765/rerank")
DEFAULT_TIMEOUT = float(os.environ.get("GYAIM_GPT2_RERANK_CLIENT_TIMEOUT", "0.75"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    args = parser.parse_args()

    payload = sys.stdin.buffer.read()
    # Validate locally so configuration problems produce clear stderr.
    json.loads(payload.decode("utf-8"))

    request = urllib.request.Request(
        args.url,
        data=payload,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            sys.stdout.buffer.write(response.read())
            sys.stdout.write("\n")
        return 0
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print(f"AI rerank server HTTP {exc.code}: {body}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"AI rerank server request failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
