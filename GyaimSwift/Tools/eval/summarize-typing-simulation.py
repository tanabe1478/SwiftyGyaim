#!/usr/bin/env python3
"""Print the per-segmentation summary and misses of a typing simulation report."""

import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"modelMapped={report['modelMapped']} epochs={report['epochs']}")
for name, result in sorted(report["segmentations"].items()):
    print(f"\n## {name}")
    for epoch, summary in sorted(result["summary"].items()):
        print(epoch, json.dumps(summary, ensure_ascii=False))
    last = max(r["epoch"] for r in result["records"])
    for r in result["records"]:
        if r["epoch"] == last and r["outcome"] not in ("prefix-top1", "kana-hiragana", "kana-katakana"):
            print(f"  {r['outcome']:<13} {r['input']:<22} 正解={r['expected']} rank={r.get('rank')} "
                  f"heuristic={r.get('heuristicRank')} model={r.get('modelOutcome')} "
                  f"scored={r.get('inScoredSet')} top={r.get('top', [])[:3]}")
