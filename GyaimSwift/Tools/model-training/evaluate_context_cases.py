#!/usr/bin/env python3
"""Audit fixed issue #125 cases by context length; never print private examples.

HF scores are a model-quality proxy, not LlamaZenzContext or macOS latency.
Native score exports can additionally carry productionScores produced by Swift's
llmPrimaryOrder. Missing production totals are reported as unavailable, never
approximated by silently dropping safety/compound rules.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import importlib.util
import json
import math
from pathlib import Path

from build_sft_dataset import RomaToKata, load_roma_to_kata, ROMAKANA_SWIFT
from prepare_context_training import digest, read_rows, ROOT, RuntimeRomaToKata

LENGTHS = (0, 5, 10, 20)


def eligible(case):
    return bool(case['candidates']) and bool(case.get('truth'))


def case_hash(case):
    import hashlib
    return hashlib.sha256(json.dumps(case, ensure_ascii=False, sort_keys=True,
                                     separators=(',', ':')).encode('utf-8')).hexdigest()


def validate_cases(cases):
    for index, case in enumerate(cases):
        candidates = case.get('candidates')
        if not isinstance(candidates, list) or len(candidates) > 24:
            raise ValueError(f'case {index}: candidates must contain 0..24 entries')
        if not isinstance(case.get('context', ''), str):
            raise ValueError(f'case {index}: invalid context')
        if case.get('truth') is not None and not isinstance(case['truth'], str):
            raise ValueError(f'case {index}: invalid corrected truth')
        if any(not isinstance(c.get('text'), str) or not c['text'] for c in candidates):
            raise ValueError(f'case {index}: invalid candidate text')


def preprocess_for_scoring(text, mode):
    if mode == 'hf':
        return text
    if mode == 'native-whitespace':
        # LlamaZenzContext.preprocess, after context truncation/prompt assembly.
        return text.replace(' ', '\u3000').replace('\n', '')
    raise ValueError('unknown text preprocessing mode')


def score_hf(cases, model, precision='fp16', text_preprocessing='hf'):
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    tokenizer = AutoTokenizer.from_pretrained(model)
    network = AutoModelForCausalLM.from_pretrained(model, torch_dtype=(
        torch.float16 if device == 'cuda' and precision == 'fp16' else torch.float32)).to(device).eval()
    converter = RuntimeRomaToKata(load_roma_to_kata(ROMAKANA_SWIFT))
    requests, pending = [], {}
    for index, case in enumerate(cases):
        if not eligible(case):
            continue
        kana = case.get('inputKana') or converter.convert(case['input'])
        if not kana:
            raise ValueError(f'case {index}: unconvertible reading')
        for length in LENGTHS:
            context = (case.get('context', '')[-length:] if length else '').strip()
            prompt = ('\uEE02'+context if context else '')+'\uEE00'+kana+'\uEE01'
            keys = [(prompt, c['text']) for c in case['candidates']]
            for key in keys:
                pending.setdefault(key, None)
            requests.append((index, length, keys))
    keys = list(pending)
    for start in range(0, len(keys), 32):
        batch = keys[start:start+32]
        encoded = [(tokenizer.encode(preprocess_for_scoring(p, text_preprocessing), add_special_tokens=False),
                    tokenizer.encode(preprocess_for_scoring(c, text_preprocessing), add_special_tokens=False)) for p, c in batch]
        if any(not p or not c for p, c in encoded):
            raise ValueError('empty prompt/continuation tokens')
        size = max(len(p)+len(c) for p, c in encoded)
        if size > network.config.max_position_embeddings:
            raise ValueError('case exceeds model context window; no silent truncation')
        ids = torch.full((len(batch), size), tokenizer.eos_token_id, dtype=torch.long, device=device)
        attention = torch.zeros_like(ids)
        labels = torch.full_like(ids, -100)
        for i, (p, c) in enumerate(encoded):
            ids[i, :len(p)+len(c)] = torch.tensor(p+c, device=device)
            attention[i, :len(p)+len(c)] = 1
            labels[i, len(p):len(p)+len(c)] = torch.tensor(c, device=device)
        with torch.inference_mode():
            logits = network(ids, attention_mask=attention).logits[:, :-1].float()
            targets = labels[:, 1:]
            selected = targets != -100
            logprobs = logits.log_softmax(-1).gather(-1, targets.clamp_min(0).unsqueeze(-1)).squeeze(-1)
            scores = (logprobs.masked_fill(~selected, 0).sum(1)/selected.sum(1)).tolist()
        pending.update(zip(batch, scores))
        if start % 3200 == 0:
            print(json.dumps({'scoredUnique': min(start+32, len(keys)), 'totalUnique': len(keys)}), flush=True)
    for index, length, keys in requests:
        yield dict(caseIndex=index, caseHash=case_hash(cases[index]), contextLength=length,
                   scores=[pending[key] for key in keys])


def winner(scores, candidates):
    if not isinstance(scores, list) or len(scores) != len(candidates):
        raise ValueError('score count does not match original candidate count')
    usable = []
    for index, score in enumerate(scores):
        if score is None:
            continue
        if isinstance(score, bool) or not isinstance(score, (float, int)) or not math.isfinite(score):
            raise ValueError('scores must be finite numbers or null')
        usable.append(index)
    # Native exporters must supply their heuristic tie-break order as order
    # fields. For HF/model-only scores ties retain original dictionary order.
    return max(usable, key=lambda i: scores[i]) if usable else None


def summarize(cases, records, backend):
    validate_cases(cases)
    by_key = {}
    for record in records:
        index, length = record['caseIndex'], record['contextLength']
        if type(index) is not int or not 0 <= index < len(cases) or length not in LENGTHS:
            raise ValueError('invalid score case index/context length')
        if record['caseHash'] != case_hash(cases[index]):
            raise ValueError('score export does not match fixed case content/order')
        if (index, length) in by_key:
            raise ValueError('duplicate case/length scores')
        if not eligible(cases[index]):
            raise ValueError('unexpected scores for an unscored case')
        by_key[index, length] = record
    expected = {(i, length) for i, c in enumerate(cases) if eligible(c) for length in LENGTHS}
    if set(by_key) != expected:
        raise ValueError('incomplete score export: all eligible cases and four lengths are required')
    totals = defaultdict(lambda: dict(count=0, modelHits=0, unavailable=0,
                                    productionCount=0, productionHits=0, truthAbsent=0))
    for (index, length), record in by_key.items():
        case = cases[index]
        candidates = case['candidates']
        best = winner(record['scores'], candidates)
        production = None
        if 'productionScores' in record:
            if backend != 'LlamaZenzContext.scoreBatch':
                raise ValueError('production totals require a native runtime score export')
            winner(record['productionScores'], candidates)  # validate vector
            order = record.get('productionOrder')
            if (not isinstance(order, list) or any(type(i) is not int for i in order)
                    or sorted(order) != list(range(len(candidates)))):
                raise ValueError('native productionOrder must be a complete permutation')
            production = order[0]
        subsets = ['all']
        if any(gap[1] >= 30 for gap in case.get('gaps', [])):
            subsets.append('internalGap30s')
        for subset in subsets:
            t = totals[subset, length]
            t['count'] += 1
            t['unavailable'] += best is None
            t['truthAbsent'] += not any(c['text'] == case['truth'] for c in candidates)
            t['modelHits'] += best is not None and candidates[best]['text'] == case['truth']
            if production is not None:
                t['productionCount'] += 1
                t['productionHits'] += candidates[production]['text'] == case['truth']
    results = []
    for (subset, length), t in sorted(totals.items()):
        results.append(dict(subset=subset, contextLength=length, **t,
                            modelTop1=t['modelHits']/t['count'],
                            productionTop1=(t['productionHits']/t['count']
                                            if t['productionCount'] == t['count'] else None)))
    return dict(totalCases=len(cases), eligibleCases=sum(eligible(c) for c in cases),
                unlabelledScoredCases=sum(bool(c['candidates']) and not c.get('truth') for c in cases),
                backend=backend, metrics=results,
                latencyGate='not-evaluated; requires uncached native macOS benchmark')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--hf-model')
    source.add_argument('--score-export', type=Path,
                        help='JSON: casesSha256, backend, model, records')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--precision', choices=['fp16', 'fp32'], default='fp16')
    parser.add_argument('--text-preprocessing', choices=['hf', 'native-whitespace'], default='hf',
                        help='native-whitespace matches Swift space/LF handling; still an HF proxy')
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT/'runs').resolve()):
        raise ValueError('evaluation output must stay under ignored model-training/runs/')
    if output.exists():
        raise ValueError('output exists; use a new directory')
    cases = list(read_rows(args.cases))
    validate_cases(cases)
    if not any(eligible(c) for c in cases):
        raise ValueError('no eligible fixed evaluation cases')
    sha = digest(args.cases)
    if args.hf_model:
        export = dict(casesSha256=sha, backend='HF-proxy', model=args.hf_model, precision=args.precision,
                      textPreprocessing=args.text_preprocessing,
                      records=list(score_hf(cases, args.hf_model, args.precision, args.text_preprocessing)))
    else:
        export = json.loads(args.score_export.read_text(encoding='utf-8'))
        if export['casesSha256'] != sha:
            raise ValueError('fixed evaluation file hash mismatch')
    report = summarize(cases, export['records'], export['backend'])
    report.update(casesSha256=sha, model=export['model'], precision=export.get('precision', 'fp16'),
                  textPreprocessing=export.get('textPreprocessing', 'hf'))
    output.mkdir(parents=True)
    (output/'scores.json').write_text(json.dumps(export, ensure_ascii=False)+'\n', encoding='utf-8')
    (output/'report.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
