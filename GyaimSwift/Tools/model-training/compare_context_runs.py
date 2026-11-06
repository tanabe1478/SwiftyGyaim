"""Paired, aggregate-only comparison on the identical fixed context benchmark."""
import argparse
import json
from pathlib import Path

from evaluate_context_cases import summarize, winner, eligible, LENGTHS
from prepare_context_training import ROOT, read_rows, digest


def compare(cases, baseline, trial):
    if baseline['casesSha256'] != trial['casesSha256'] or baseline['backend'] != trial['backend']:
        raise ValueError('comparison requires identical cases and backend')
    if baseline.get('precision', 'fp16') != trial.get('precision', 'fp16'):
        raise ValueError('comparison requires identical precision')
    if baseline.get('textPreprocessing', 'hf') != trial.get('textPreprocessing', 'hf'):
        raise ValueError('comparison requires identical text preprocessing')
    # Also validates each fingerprint and full coverage, not just the file-level hash.
    before = summarize(cases, baseline['records'], baseline['backend'])
    after = summarize(cases, trial['records'], trial['backend'])
    maps = [{(r['caseIndex'], r['contextLength']): r for r in export['records']}
            for export in (baseline, trial)]
    paired = []
    for length in LENGTHS:
        for subset in ('all', 'internalGap30s'):
            improved = worsened = same = 0
            for i, case in enumerate(cases):
                if not eligible(case):
                    continue
                if subset == 'internalGap30s' and not any(g[1] >= 30 for g in case.get('gaps', [])):
                    continue
                correct = []
                for records in maps:
                    best = winner(records[i, length]['scores'], case['candidates'])
                    correct.append(best is not None and case['candidates'][best]['text'] == case['truth'])
                improved += not correct[0] and correct[1]
                worsened += correct[0] and not correct[1]
                same += correct[0] == correct[1]
            count = improved+worsened+same
            paired.append(dict(subset=subset, contextLength=length, count=count,
                               improved=improved, worsened=worsened, unchanged=same,
                               net=improved-worsened,
                               delta=(improved-worsened)/count if count else None))
    context_rows = [r for r in paired if r['subset'] == 'all' and r['contextLength'] in (5, 10, 20)]
    return dict(baseline=baseline['model'], trial=trial['model'],
                casesSha256=baseline['casesSha256'], backend=baseline['backend'],
                precision=baseline.get('precision', 'fp16'),
                textPreprocessing=baseline.get('textPreprocessing', 'hf'),
                before=before['metrics'], after=after['metrics'], paired=paired,
                allContextLengthsImproved=all(r['net'] > 0 for r in context_rows),
                note='Exploratory fixed benchmark; repeated use is not independent confirmation. Native macOS gate remains separate.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--trial', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT/'runs').resolve()) or output.exists():
        raise ValueError('use a new output file under ignored runs/')
    baseline, trial = [json.loads(path.read_text(encoding='utf-8')) for path in (args.baseline, args.trial)]
    if baseline['casesSha256'] != digest(args.cases):
        raise ValueError('case file hash mismatch')
    report = compare(list(read_rows(args.cases)), baseline, trial)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'allContextLengthsImproved': report['allContextLengthsImproved'], 'paired': report['paired']}))
