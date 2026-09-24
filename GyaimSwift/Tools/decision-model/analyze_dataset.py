import argparse
from collections import Counter, defaultdict

from common import rows, validate, write_json


def analyze(path):
    counts = defaultdict(Counter)
    total = none = homophone = 0
    for r in rows(path):
        validate(r, True)
        total += 1
        none += r['selected'] is None
        homophone += sum(c.get('exactReadingMatch') is True and c.get('kind') in ('exact','compound') for c in r['candidates']) >= 2
        counts['candidateCount'][len(r['candidates'])] += 1
        counts['readingLength'][len(r['readingHiragana'])] += 1
        counts['noneType'][r.get('noneType') or 'present'] += 1
        if r['selected'] is not None:
            counts['goldOriginalRank'][str(r['candidates'][r['selected']].get('originalRank'))] += 1
        for c in r['candidates']:
            for k in ['source', 'kind', 'hardNegativeType']:
                counts[k][c.get(k, 'unknown')] += 1
            counts['textLength'][len(c['text'])] += 1
            for k in ['studyFrequency', 'contextAffinity', 'exactReadingMatch', 'originalRank']:
                counts['missing'][k] += c.get(k) is None
    return dict(count=total, noneRate=none/max(total,1), homophoneRate=homophone/max(total,1),
                distributions={k: dict(v) for k, v in counts.items()})


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('dataset')
    p.add_argument('--output')
    a = p.parse_args()
    report = analyze(a.dataset)
    if a.output:
        write_json(a.output, report)
    else:
        import json
        print(json.dumps(report, indent=2))
