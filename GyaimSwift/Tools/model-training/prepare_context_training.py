#!/usr/bin/env python3
"""Prepare issue #125 SFT data without mixing context variants across splits.

Reads explicitly supplied local files only. Outputs contain private text and must
stay in the ignored model-training/data directory. No raw examples are printed.
The fixed context-case audit is mandatory, including when preparing a smoke run.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import unicodedata

from build_sft_dataset import RomaToKata, load_roma_to_kata, ROMAKANA_SWIFT

ROOT = Path(__file__).resolve().parent
LENGTHS = (20, 10, 5, 0)


class RuntimeRomaToKata(RomaToKata):
    """Mirror RomaKana.roma2katakana, including trailing n and partial inputs.

    The SFT extractor's strict converter intentionally rejects incomplete input;
    fixed runtime cases include it, so rejecting those would bias evaluation.
    """
    def convert(self, text):
        result, i = [], 0
        while i < len(text):
            for size in range(min(self.max_len, len(text)-i), 0, -1):
                key = text[i:i+size]
                if key in self.table:
                    result.append(self.table[key])
                    i += size
                    break
            else:
                current = text[i]
                following = text[i+1] if i+1 < len(text) else None
                if current in 'nN' and (following is None or following in 'bcdfghjklmnpqrstvwxz'):
                    result.append('ン')
                elif current in 'bcdfghjklmpqrstvwxyz' and current == following:
                    result.append('ッ')
                i += 1
        return ''.join(result)


def read_rows(path):
    with Path(path).open(encoding='utf-8') as handle:
        for number, line in enumerate(handle, 1):
            if line.strip():
                try:
                    yield json.loads(line)
                except ValueError:
                    raise ValueError(f'invalid JSON at line {number}') from None


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def normal(text):
    return unicodedata.normalize('NFC', text)


def pair_key(reading, output):
    if not isinstance(reading, str) or not reading or not isinstance(output, str) or not output:
        raise ValueError('reading and output must be nonempty strings')
    reading = normal(reading)
    reading = ''.join(chr(ord(c)+0x60) if '\u3041' <= c <= '\u3096' else c for c in reading)
    return reading, normal(output)


def context_holdout(cases, converter):
    """Exclude both corrected truth and original mistaken labels, at every length."""
    keys = set()
    count = 0
    for row in cases:
        count += 1
        reading = row.get('inputKana') or converter.convert(row['input'])
        if not reading:
            if row.get('candidates'):
                raise ValueError(f'context case {count} has an unconvertible scored reading')
            continue  # No model input and no candidate scores: not in the audit population.
        for field in ('truth', 'chosen'):
            if row.get(field):
                keys.add(pair_key(reading, row[field]))
    if not count or not keys:
        raise ValueError('fixed context holdout must not be empty')
    return keys, count


def legacy_holdout(paths):
    keys = set()
    for path in paths:
        for row in read_rows(path):
            keys.add(pair_key(row['input'], row.get('output') or row.get('chosen')))
    return keys


def partition(rows, excluded, valid_fraction, seed, lengths=LENGTHS, min_context=0):
    if not 0 < valid_fraction < 1:
        raise ValueError('valid fraction must be between zero and one')
    train, valid = [], []
    stats = Counter()
    seen = set()
    for row in rows:
        key = pair_key(row['input'], row['output'])
        if key in excluded:
            stats['excludedRows'] += 1
            continue
        context = row.get('left_context') or ''
        if not isinstance(context, str):
            raise ValueError('context must be a string or null')
        context = normal(context)[-20:]
        if len(context) < min_context:
            stats['shortContextExcluded'] += 1
            continue
        payload = json.dumps([seed, *key], ensure_ascii=False).encode('utf-8')
        bucket = int.from_bytes(hashlib.sha256(payload).digest()[:8], 'big') / 2**64
        target = valid if bucket < valid_fraction else train
        for length in lengths:
            suffix = context[-length:] if length else ''
            identity = (*key, suffix)
            if identity in seen:
                stats['duplicateVariants'] += 1
                continue
            seen.add(identity)
            target.append(dict(input=key[0], output=key[1], left_context=suffix or None))
    random.Random(seed).shuffle(train)
    random.Random(seed+1).shuffle(valid)
    return train, valid, dict(stats)


def prepare(domain, cases, holdouts, public, output, valid_fraction=.05, seed=125, oversample=1,
            context_policy='augmented'):
    output = Path(output).resolve()
    if not output.is_relative_to((ROOT/'data').resolve()):
        raise ValueError('private output must be under model-training/data/')
    if output.exists():
        raise ValueError('output already exists; use a new versioned directory')
    if oversample < 1:
        raise ValueError('oversample must be positive')
    converter = RuntimeRomaToKata(load_roma_to_kata(ROMAKANA_SWIFT))
    excluded, case_count = context_holdout(read_rows(cases), converter)
    excluded |= legacy_holdout(holdouts)
    if context_policy not in ('augmented', 'long-context'):
        raise ValueError('unknown context policy')
    lengths, min_context = ((20,), 11) if context_policy == 'long-context' else (LENGTHS, 0)
    dtrain, dvalid, dstats = partition(read_rows(domain), excluded, valid_fraction, seed, lengths, min_context)
    # The same hash routes public/domain occurrences to the same split. This
    # excludes target pairs even if their public contexts differ completely.
    public_skipped = Counter()
    def public_rows():
        for path in public:
            for row in read_rows(path):
                if not row.get('input') or not row.get('output'):
                    public_skipped['emptyInputOrOutput'] += 1
                    continue
                yield row
    ptrain, pvalid, pstats = partition(public_rows(), excluded, valid_fraction, seed, lengths, min_context)
    pstats.update(public_skipped)
    train = ptrain + dtrain * oversample
    valid = pvalid + dvalid
    if not dtrain or not dvalid:
        raise ValueError('domain train/valid is empty after holdout exclusion')
    train_keys = {pair_key(r['input'], r['output']) for r in train}
    valid_keys = {pair_key(r['input'], r['output']) for r in valid}
    assert not train_keys & valid_keys
    assert not (train_keys | valid_keys) & excluded
    random.Random(seed).shuffle(train)
    manifest = dict(schemaVersion=1, issue=125, privacy='private', seed=seed,
                    contextLengths=list(lengths), contextPolicy=context_policy, minContext=min_context,
                    splitUnit='normalized reading/output',
                    holdoutPolicy='all contexts of truth and original chosen pairs',
                    fixedCases=case_count, excludedPairs=len(excluded),
                    domainStats=dstats, publicStats=pstats, domainOversample=oversample,
                    counts=dict(train=len(train), valid=len(valid), domainTrain=len(dtrain),
                                domainValid=len(dvalid), publicTrain=len(ptrain), publicValid=len(pvalid)),
                    inputs=[dict(role=role, sha256=digest(path)) for role, path in (
                            [('domain', domain), ('contextCases', cases)] +
                            [('legacyHoldout', p) for p in holdouts] + [('public', p) for p in public])])
    output.mkdir(parents=True)
    for name, values in [('train', train), ('valid', valid), ('domain-valid', dvalid)]:
        with (output/f'{name}.jsonl').open('w', encoding='utf-8') as handle:
            for row in values:
                handle.write(json.dumps(row, ensure_ascii=False)+'\n')
    manifest['outputs'] = {name: digest(output/name) for name in ['train.jsonl', 'valid.jsonl', 'domain-valid.jsonl']}
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(manifest['counts']))
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--domain', type=Path, required=True)
    parser.add_argument('--context-cases', type=Path, required=True)
    parser.add_argument('--holdout', type=Path, action='append', default=[])
    parser.add_argument('--public', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--valid-fraction', type=float, default=.05)
    parser.add_argument('--seed', type=int, default=125)
    parser.add_argument('--domain-oversample', type=int, default=1)
    parser.add_argument('--context-policy', choices=['augmented', 'long-context'], default='augmented')
    args = parser.parse_args()
    prepare(args.domain, args.context_cases, args.holdout, args.public, args.output,
            args.valid_fraction, args.seed, args.domain_oversample, args.context_policy)
