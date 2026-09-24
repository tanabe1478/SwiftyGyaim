"""Stream public zenz into grouped splits, mining train-only hard negatives."""
from __future__ import annotations

import argparse
import bisect
import collections
import contextlib
import datetime
import json
import random
import re
from pathlib import Path

from common import ROOT, REPO, SPLITS, candidate, digest, hira, key, normalize, private_output, rows, validate, write_json


class Reading:
    """Reuse the source mapping table; canonical inverse chooses first mapping."""
    def __init__(self):
        text = (REPO / 'GyaimSwift/Sources/Gyaim/RomaKana.swift').read_text(encoding='utf-8')
        self.forward = {}
        self.reverse = {}
        for line in text.splitlines():
            parts = line.strip().replace('\\t', '\t').split('\t')
            if len(parts) == 3 and re.fullmatch('[a-zA-Z,./;:!?\\-]+', parts[0]):
                self.forward[parts[0]] = parts[1]
                self.reverse.setdefault(parts[1], parts[0])
        if len(self.forward) < 100:
            raise ValueError('RomaKana mapping table layout changed')
        self.rkeys = sorted(self.reverse, key=lambda x: (-len(x), x))
        self.fkeys = sorted(self.forward, key=lambda x: (-len(x), x))

    def roman(self, text):
        result = ''
        while text:
            match = next((k for k in self.rkeys if text.startswith(k)), None)
            if match:
                result += self.reverse[match]
                text = text[len(match):]
            else:
                result += text[0]
                text = text[1:]
        return result

    def kana(self, text):
        result = ''
        while text:
            match = next((k for k in self.fkeys if text.startswith(k)), None)
            if match:
                result += self.forward[match]
                text = text[len(match):]
            elif len(text) > 1 and text[0] == text[1] and text[0] in 'bcdfghjklmpqrstvwxyz':
                result += 'っ'
                text = text[1:]
            elif text[0] in 'nN' and (len(text) == 1 or text[1] in 'bcdfghjklmnpqrstvwxz'):
                result += 'ん'
                text = text[1:]
            else:
                result += text[0]
                text = text[1:]
        return result


def split_for(context, reading, seed):
    # One context cannot straddle splits; all empty-context homophones also grouped.
    group = normalize(context) if context else 'reading:' + hira(reading)
    bucket = int(key(seed, group)[:8], 16) % 1000
    return 'train' if bucket < 850 else 'validation' if bucket < 900 else 'calibration' if bucket < 950 else 'test'


def none_variant(row):
    if row['selected'] is None or len(row['candidates']) < 2:
        return None
    result = dict(row, id=row['id'] + '-none', selected=None, noneType='synthetic')
    result['candidates'] = [c for i, c in enumerate(row['candidates']) if i != row['selected']]
    return result


def fixture(row, reading):
    roman = row.get('inputPat', '')
    kana = hira(row.get('inputKana', ''))
    if not kana or re.search('[a-zA-Z]', kana):
        kana = reading.kana(roman)
    cs = []
    for i, old in enumerate(row['candidates'][:24]):
        c = candidate(old['text'], old.get('reading'), rank=i)
        c.update({k: v for k, v in old.items() if k in c})
        c['kind'] = c['kind'] if c['kind'] in ['exact', 'prefix', 'compound', 'kana', 'raw', 'completion', 'google', 'unknown'] else 'unknown'
        c['exactReadingMatch'] = c['reading'] == roman if c['reading'] is not None else None
        cs.append(c)
    selected = next((i for i, c in enumerate(cs) if c['text'] == row['expectedTop']), None)
    return validate(dict(schemaVersion=1, id=row['id'], context=row.get('context', ''), readingRoman=roman,
                         readingHiragana=kana, candidates=cs, selected=selected, tags=row.get('tags', []),
                         origin='regression', candidateRecall=selected is not None, noneType='real' if selected is None else None), True)


class Miner:
    def __init__(self, dictionary, reading):
        self.exact = collections.defaultdict(list)
        for line in Path(dictionary).read_text(encoding='utf-8').splitlines():
            p = line.split('\t')
            if len(p) < 4 or '*' in p[1] or p[1].endswith('形容詞'):
                continue
            kana = reading.kana(p[0])
            if p[1] not in self.exact[kana]:
                self.exact[kana].append(p[1])
        self.keys = sorted(self.exact)
        self.corpus = collections.defaultdict(collections.Counter)

    def generate(self, kana):
        cs = []
        seen = set()
        def add(text, kind, source, r, negative):
            if text and text not in seen and len(cs) < 24:
                seen.add(text)
                c = candidate(text, r, source, kind, len(cs), hardNegativeType=negative)
                c['exactReadingMatch'] = r == kana
                cs.append(c)
        for text in self.exact.get(kana, []):
            add(text, 'exact', 'connection', kana, 'dictionary_same_reading')
        # Corpus outputs are not added as candidates: self-mining leaks gold presence
        # and creates a different NONE prior in train vs unseen validation readings.
        start = bisect.bisect_left(self.keys, kana)
        for r in self.keys[start:start + 6]:
            if r != kana and r.startswith(kana):
                for text in self.exact[r][:2]:
                    add(text, 'prefix', 'connection', r, 'prefix')
        add(kana, 'kana', 'synthetic', kana, 'kana')
        return cs


def public(args):
    for path in args.sources:
        if 'domain' in path.name.lower() or 'private' in [part.lower() for part in path.parts]:
            raise ValueError('known private/domain source cannot enter a public dataset')
    out = args.output.resolve()
    if out.exists():
        raise ValueError('output must be a new directory')
    out.mkdir(parents=True)
    reading = Reading()
    holdout = [fixture(r, reading) for r in rows(args.fixture)]
    excluded = {hira(r['readingHiragana']) for r in holdout}
    miner = Miner(args.dictionary, reading)
    counts = collections.Counter()
    source_hashes = []
    # Spool once; bounded input scan and per-source content hashes identify exact sample.
    with (out / 'source.jsonl').open('w', encoding='utf-8') as f:
        for path in args.sources:
            import hashlib
            h = hashlib.sha256()
            scanned = 0
            with Path(path).open('rb') as source:
                for line in source:
                    if args.limit and scanned >= args.limit:
                        break
                    scanned += 1
                    h.update(line)
                    row = json.loads(line)
                    kana, gold, context = hira(row.get('input', '')), row.get('output', ''), row.get('left_context') or ''
                    if not kana or not gold or len(kana) > args.max_reading or kana in excluded:
                        counts['filtered'] += 1
                        continue
                    split = split_for(context, kana, args.seed)
                    r = dict(context=context, kana=kana, gold=gold, split=split)
                    f.write(json.dumps(r, ensure_ascii=False) + '\n')
            source_hashes.append(dict(name=Path(path).name, scanned=scanned, sha256ScannedBytes=h.hexdigest()))
    rng = random.Random(args.seed)
    seen = set()
    with contextlib.ExitStack() as stack:
        files = {s: stack.enter_context((out / f'{s}.jsonl').open('w', encoding='utf-8')) for s in SPLITS + ['regression']}
        for row in rows(out / 'source.jsonl'):
            rid = key(row['context'], row['kana'], row['gold'])
            if rid in seen:
                counts['duplicate'] += 1
                continue
            seen.add(rid)
            cs = miner.generate(row['kana'])
            if len(cs) < 2:
                counts['no_competition'] += 1
                continue
            natural = next((i for i, c in enumerate(cs) if c['text'] == row['gold']), None)
            roman = reading.roman(row['kana'])
            for c in cs:
                c['reading'] = reading.roman(c['reading'])
            r = dict(schemaVersion=1, id=rid, context=row['context'], readingRoman=roman,
                     readingHiragana=row['kana'], candidates=cs, selected=natural,
                     candidateRecall=natural is not None, origin='public-synthetic', noneType='real' if natural is None else None)
            split = row['split']
            # Never manufacture an easy gold-only set. Real missing-gold examples stay NONE.
            validate(r, True)
            files[split].write(json.dumps(r, ensure_ascii=False) + '\n')
            counts[split] += 1
            if natural is not None and len(cs) > 1 and rng.random() < args.none_rate:
                files[split].write(json.dumps(none_variant(r), ensure_ascii=False) + '\n')
                counts[split] += 1
        for r in holdout:
            files['regression'].write(json.dumps(r, ensure_ascii=False) + '\n')
    (out / 'source.jsonl').unlink()
    manifest = dict(schemaVersion=1, version=args.version, privacy='public', seed=args.seed,
                    sources=source_hashes, dictionaryHash=digest(args.dictionary), fixtureHash=digest(args.fixture),
                    counts=dict(counts), maxReading=args.max_reading, syntheticNoneRate=args.none_rate,
                    splitPolicy='context-group sha256; empty context grouped by reading; fixture readings excluded',
                    limitation='bounded prefix of each source; competitive dictionary sets only; no full connection-graph composition; recall is conditional on this selection',
                    licenses={'zenz-wikipedia': 'CC-BY-SA-4.0', 'zenz-llm-jp': 'ODC-BY; upstream terms apply'},
                    files={s: digest(out / f'{s}.jsonl') for s in SPLITS + ['regression']})
    write_json(out / 'manifest.json', manifest)
    print(json.dumps(manifest, ensure_ascii=False))


def private(args):
    out = private_output(args.output)
    if out.exists():
        raise ValueError('output must be a new directory')
    boundaries = [datetime.datetime.fromisoformat(t.replace('Z', '+00:00')) for t in args.boundaries]
    if boundaries != sorted(boundaries) or len(set(boundaries))!=3 or any(t.tzinfo is None for t in boundaries):
        raise ValueError('three increasing timezone-aware temporal boundaries required')
    out.mkdir(parents=True)
    counts = collections.Counter()
    excluded=set()
    if getattr(args,'fixture',None):
        reading=Reading()
        excluded={fixture(r,reading)['readingHiragana'] for r in rows(args.fixture)}
    with contextlib.ExitStack() as stack:
        files = {s: stack.enter_context((out / f'{s}.jsonl').open('w', encoding='utf-8')) for s in SPLITS}
        for path in args.sources:
            for r in rows(path):
                validate(r, True)
                if hira(r['readingHiragana']) in excluded:
                    counts['regression_excluded']+=1
                    continue
                timestamp = datetime.datetime.fromisoformat(r['timestamp'].replace('Z', '+00:00'))
                if timestamp.tzinfo is None:
                    raise ValueError('timestamp must include timezone')
                split = SPLITS[bisect.bisect_right(boundaries, timestamp)]
                r = dict(r, privacy='private', origin='dogfood', candidateRecall=r['selected'] is not None,
                         noneType='real' if r['selected'] is None else None)
                files[split].write(json.dumps(r, ensure_ascii=False) + '\n')
                counts[split] += 1
    write_json(out / 'manifest.json', dict(schemaVersion=1, version=args.version, privacy='private', counts=dict(counts),
               boundaries=args.boundaries, sources=[{'sha256':digest(p)} for p in args.sources],
               files={s: digest(out / f'{s}.jsonl') for s in SPLITS}))
    print(json.dumps({'privacy': 'private', 'counts': dict(counts)}))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sources', nargs='+', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--version', default='public-v1')
    p.add_argument('--limit', type=int, default=500000, help='scanned rows PER source; 0 = all')
    p.add_argument('--max-reading', type=int, default=12)
    p.add_argument('--seed', type=int, default=42)
    p.add_argument('--none-rate', type=float, default=.15)
    p.add_argument('--dictionary', type=Path, default=REPO / 'GyaimSwift/Resources/dict.txt')
    p.add_argument('--fixture', type=Path, default=REPO / 'GyaimSwift/Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl')
    p.add_argument('--private', action='store_true')
    p.add_argument('--boundaries', nargs=3, help='ISO train-end, validation-end, calibration-end')
    args = p.parse_args()
    if not 0 <= args.none_rate <= 1 or args.limit < 0:
        p.error('invalid limit/none-rate')
    if args.private and not args.boundaries:
        p.error('--private requires --boundaries')
    (private if args.private else public)(args)


if __name__ == '__main__':
    main()
