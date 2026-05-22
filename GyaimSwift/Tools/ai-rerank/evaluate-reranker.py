#!/usr/bin/env python3
"""Evaluate an AIRerank server/client against extracted SwiftyGyaim logs."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path
from urllib import request as urlrequest
from typing import Any


def load_records(path: Path, limit: int | None) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            if line.strip():
                records.append(json.loads(line))
                if limit and len(records) >= limit:
                    break
    return records


_ROMA_KANA = {
    "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ", "sha": "しゃ", "shu": "しゅ", "sho": "しょ",
    "sya": "しゃ", "syu": "しゅ", "syo": "しょ", "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ",
    "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ", "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
    "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ", "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
    "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ", "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
    "ja": "じゃ", "ju": "じゅ", "jo": "じょ", "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
    "bya": "びゃ", "byu": "びゅ", "byo": "びょ", "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
    "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ", "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
    "xtsu": "っ", "ltsu": "っ", "shi": "し", "chi": "ち", "tsu": "つ", "fu": "ふ",
    "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ", "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
    "ta": "た", "ti": "ち", "tu": "つ", "te": "て", "to": "と", "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
    "ha": "は", "hi": "ひ", "hu": "ふ", "he": "へ", "ho": "ほ", "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
    "ya": "や", "yu": "ゆ", "yo": "よ", "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ", "wa": "わ", "wo": "を",
    "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご", "za": "ざ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
    "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど", "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
    "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ", "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お", "n": "ん", "-": "ー",
}


def roma_to_hiragana(text: str) -> str:
    src = text.lower()
    out: list[str] = []
    i = 0
    while i < len(src):
        if i + 1 < len(src) and src[i] == src[i + 1] and src[i] not in "aeioun":
            out.append("っ")
            i += 1
            continue
        if src[i] == "n" and (i + 1 == len(src) or src[i + 1] not in "aiueoyn"):
            out.append("ん")
            i += 1
            continue
        for width in (4, 3, 2, 1):
            piece = src[i:i + width]
            if piece in _ROMA_KANA:
                out.append(_ROMA_KANA[piece])
                i += width
                break
        else:
            out.append(src[i])
            i += 1
    return "".join(out)

def request_for(record: dict[str, Any], top_n: int | None = None) -> dict[str, Any]:
    candidates = record["candidates"]
    if top_n:
        candidates = candidates[:top_n]
    return {
        "version": 1,
        "mode": "rerank",
        "inputPat": record["inputPat"],
        "hiragana": record.get("hiragana") or roma_to_hiragana(record["inputPat"]),
        "candidates": [
            {"index": i, "text": text, "reading": record["inputPat"], "source": "unknown"}
            for i, text in enumerate(candidates)
        ],
    }


def call_client(command: str, request: dict[str, Any], timeout: float) -> tuple[list[int] | None, float, str | None]:
    start = time.perf_counter()
    proc = subprocess.run(
        command,
        input=json.dumps(request, ensure_ascii=False).encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=True,
        timeout=timeout,
    )
    elapsed_ms = (time.perf_counter() - start) * 1000
    if proc.returncode != 0:
        return None, elapsed_ms, proc.stderr.decode("utf-8", errors="replace")
    try:
        payload = json.loads(proc.stdout.decode("utf-8"))
        return payload.get("order"), elapsed_ms, None
    except Exception as exc:
        return None, elapsed_ms, str(exc)

def call_http(server_url: str, request: dict[str, Any], timeout: float) -> tuple[list[int] | None, float, str | None]:
    body = json.dumps(request, ensure_ascii=False).encode("utf-8")
    http_request = urlrequest.Request(
        server_url,
        data=body,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    start = time.perf_counter()
    try:
        with urlrequest.urlopen(http_request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
        elapsed_ms = (time.perf_counter() - start) * 1000
        return payload.get("order"), elapsed_ms, None
    except Exception as exc:
        elapsed_ms = (time.perf_counter() - start) * 1000
        return None, elapsed_ms, str(exc)


def rank_of(order: list[int], selected_index: int) -> int | None:
    try:
        return order.index(selected_index)
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("data", type=Path)
    parser.add_argument("--command", help="External reranker client command")
    parser.add_argument("--server-url", help="Direct HTTP reranker endpoint, e.g. http://127.0.0.1:8765/rerank")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--top-n", type=int, default=10)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if not args.command and not args.server_url:
        parser.error("one of --command or --server-url is required")

    records = load_records(args.data, args.limit)
    if not records:
        print("No records", file=sys.stderr)
        return 1

    baseline_top1 = sum(1 for r in records if r["selectedIndex"] == 0)
    baseline_top3 = sum(1 for r in records if r["selectedIndex"] < 3)
    rerank_top1 = rerank_top3 = 0
    failures = 0
    latencies: list[float] = []
    regressions: list[dict[str, Any]] = []
    improvements: list[dict[str, Any]] = []

    for i, record in enumerate(records, 1):
        req = request_for(record, top_n=args.top_n)
        selected_index = record["selectedIndex"]
        # If the selected candidate is outside top_n, the reranker cannot promote it.
        if selected_index >= len(req["candidates"]):
            order = list(range(len(req["candidates"])))
            elapsed = 0.0
        else:
            if args.server_url:
                order, elapsed, error = call_http(args.server_url, req, args.timeout)
            else:
                order, elapsed, error = call_client(args.command, req, args.timeout)
            latencies.append(elapsed)
            if order is None:
                failures += 1
                order = list(range(len(req["candidates"])))
        pos = rank_of(order, selected_index)
        if pos == 0:
            rerank_top1 += 1
        if pos is not None and pos < 3:
            rerank_top3 += 1

        baseline_hit = selected_index == 0
        rerank_hit = pos == 0
        if baseline_hit and not rerank_hit:
            regressions.append({"record": record, "order": order, "rank": pos})
        elif not baseline_hit and rerank_hit:
            improvements.append({"record": record, "order": order})

        if i % 50 == 0:
            print(f"evaluated {i}/{len(records)}", file=sys.stderr)

    def pct(n: int) -> float:
        return n / len(records) * 100

    summary = {
        "records": len(records),
        "failures": failures,
        "baselineTop1": baseline_top1,
        "baselineTop1Pct": pct(baseline_top1),
        "baselineTop3": baseline_top3,
        "baselineTop3Pct": pct(baseline_top3),
        "rerankTop1": rerank_top1,
        "rerankTop1Pct": pct(rerank_top1),
        "rerankTop3": rerank_top3,
        "rerankTop3Pct": pct(rerank_top3),
        "latencyMsP50": statistics.median(latencies) if latencies else None,
        "latencyMsP95": statistics.quantiles(latencies, n=100)[94] if len(latencies) >= 100 else (max(latencies) if latencies else None),
        "improvements": len(improvements),
        "regressions": len(regressions),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))

    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open("w", encoding="utf-8") as f:
            f.write("# AI Reranker Evaluation\n\n")
            f.write("```json\n")
            f.write(json.dumps(summary, ensure_ascii=False, indent=2))
            f.write("\n```\n\n")
            f.write("## Improvements\n\n")
            for item in improvements[:30]:
                r = item["record"]
                f.write(f"- `{r['inputPat']}` selected `{r['selected']}` candidates={r['candidates'][:args.top_n]} order={item['order']}\n")
            f.write("\n## Regressions\n\n")
            for item in regressions[:30]:
                r = item["record"]
                f.write(f"- `{r['inputPat']}` selected `{r['selected']}` candidates={r['candidates'][:args.top_n]} order={item['order']} rank={item['rank']}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
