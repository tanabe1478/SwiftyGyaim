"""Mine contextual same-reading contrasts from public text and shipped dictionaries.

The corpus surface is positive; dictionary alternatives are mined negatives, NOT
observed user rejections. Same connection class is a filter, not a guarantee of
unambiguous semantics. Evaluate the resulting experiment independently.
"""
import argparse
from collections import defaultdict, Counter
import json
from pathlib import Path

from prepare_context_training import (ROOT, RuntimeRomaToKata, load_roma_to_kata, ROMAKANA_SWIFT,
                                     pair_key, read_rows, digest, context_holdout, legacy_holdout)


def dictionary_alternatives(paths, converter, min_chars=2, max_chars=6):
    classes = defaultdict(set)
    for path in paths:
        for line in path.read_text(encoding='utf-8').splitlines():
            fields = line.split('\t')
            if len(fields) < 4:
                continue
            reading, word, before, after = fields[:4]
            if not (min_chars <= len(word) <= max_chars and all('\u4e00' <= ch <= '\u9fff' for ch in word)):
                continue
            kana = (pair_key(reading, word)[0] if any('\u3040' <= ch <= '\u30ff' for ch in reading)
                    else converter.convert(reading))
            if kana:
                classes[kana, before, after].add(word)
    alternatives = defaultdict(set)
    for (reading, _, _), words in classes.items():
        for word in words:
            alternatives[reading, word].update(words-{word})
    return alternatives


def mine(rows, alternatives, excluded, max_negatives=3):
    seen, output, stats = set(), [], Counter()
    for row in rows:
        stats['sourceRows'] += 1
        if not row.get('input') or not row.get('output'):
            continue
        context = (row.get('left_context') or '').strip()[-20:]
        if len(context) < 11:
            continue
        reading, chosen = pair_key(row['input'], row['output'])
        if (reading, chosen) in excluded:
            stats['chosenHoldout'] += 1
            continue
        alternatives_here = [word for word in sorted(alternatives.get((reading, chosen), []))
                             if (reading, word) not in excluded]
        added = False
        for rejected in alternatives_here[:max_negatives]:
            key = reading, chosen, rejected, context
            if key in seen:
                continue
            seen.add(key)
            output.append(dict(input=reading, inputKana=reading, context=context,
                               chosen=chosen, rejected=rejected, source='public-corpus-dictionary-contrast'))
            added = True
        stats['positiveContexts'] += added
    stats['pairs'] = len(output)
    return output, dict(stats)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public', type=Path, required=True)
    parser.add_argument('--context-cases', type=Path, required=True)
    parser.add_argument('--holdout', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--min-chars', type=int, default=2)
    parser.add_argument('--max-chars', type=int, default=6)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT/'data').resolve()) or output.exists():
        raise ValueError('use a new directory under ignored data/')
    converter = RuntimeRomaToKata(load_roma_to_kata(ROMAKANA_SWIFT))
    dictionaries = [ROOT.parents[1]/'Resources'/name for name in ('dict.txt', 'mozc-dict.txt')]
    excluded, _ = context_holdout(read_rows(args.context_cases), converter)
    excluded |= legacy_holdout(args.holdout)
    if not 1 <= args.min_chars <= args.max_chars:
        raise ValueError('invalid surface-length bounds')
    pairs, stats = mine(read_rows(args.public), dictionary_alternatives(
        dictionaries, converter, args.min_chars, args.max_chars), excluded)
    if not pairs:
        raise ValueError('no eligible contrasts')
    output.mkdir(parents=True)
    with (output/'pairs.jsonl').open('w', encoding='utf-8') as handle:
        for row in pairs:
            handle.write(json.dumps(row, ensure_ascii=False)+'\n')
    manifest = dict(sourceKind='public corpus positives + same connection-class dictionary negatives',
                    userPreference=False, stats=stats, minChars=args.min_chars, maxChars=args.max_chars,
                    publicSha256=digest(args.public),
                    casesSha256=digest(args.context_cases), holdoutSha256=[digest(p) for p in args.holdout],
                    dictionarySha256=[digest(p) for p in dictionaries], pairsSha256=digest(output/'pairs.jsonl'),
                    caveat='mined alternatives may also be acceptable; requires quality evaluation')
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(stats))
