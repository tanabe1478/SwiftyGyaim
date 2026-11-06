"""Compare native case traces without rescoring, training, or changing ranking.

Requires original private JSONL and complete Release exports from the same
runtime/dictionaries/settings. Default reports omit text; --include-text writes
private review examples under ignored runs/ only. This is not a training exporter.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import re
import unicodedata

from prepare_context_training import ROOT, RuntimeRomaToKata, load_roma_to_kata, ROMAKANA_SWIFT

ADJUSTMENTS = {'study', 'context', 'compound', 'rawHiragana', 'incompleteStemPenalty',
               'politeNegativePredictionPenalty', 'punctuatedInputMismatchPenalty', 'rawAsciiPenalty'}
SHA = re.compile(r'[0-9a-f]{64}')
WEIGHTS = dict(study=2., context=2., rawHiragana=1., compound=2.)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def close(left, right):
    return finite(left) and finite(right) and math.isclose(left, right, abs_tol=1e-8, rel_tol=1e-10)


def parse_json(data):
    def reject(_):
        raise ValueError('non-finite JSON constant')
    return json.loads(data, parse_constant=reject)


def decoded_case(line):
    """Mirror the native Decodable fields; rejected lines count as skipped."""
    try:
        row = parse_json(line)
    except (ValueError, UnicodeError):
        return None
    if not isinstance(row, dict) or any(not isinstance(row.get(k), str) for k in ('time', 'input', 'context')):
        return None
    if any(row.get(k) is not None and not isinstance(row[k], str)
           for k in ('chosen', 'truth', 'prevWord', 'prevReading')):
        return None
    gaps, candidates = row.get('gaps'), row.get('candidates')
    if not isinstance(gaps, list) or any(not isinstance(g, list) or not all(finite(x) for x in g) for g in gaps):
        return None
    if not isinstance(candidates, list):
        return None
    for candidate in candidates:
        if not isinstance(candidate, dict) or not isinstance(candidate.get('text'), str):
            return None
        if any(candidate.get(k) is not None and not isinstance(candidate[k], str) for k in ('source', 'kind', 'reading')):
            return None
        if candidate.get('contextAffinity') is not None and not finite(candidate['contextAffinity']):
            return None
        if candidate.get('studyFrequency') is not None and type(candidate['studyFrequency']) is not int:
            return None
    return row


def is_gap30(case):
    return any(len(gap) == 2 and gap[1] > 30 for gap in case['gaps'])


def source_cases(raw, subset):
    selected, skipped = {}, 0
    for number, line in enumerate(raw.split(b'\n'), 1):
        if not line:
            continue
        row = decoded_case(line)
        truth = (row.get('truth') if row.get('truth') is not None else row.get('chosen')) if row else None
        # Swift String equality uses canonical equivalence; hashes stay byte-exact.
        truth = unicodedata.normalize('NFC', truth) if truth is not None else None
        texts = [unicodedata.normalize('NFC', c['text']) for c in row['candidates']] if row else []
        if row is None or truth is None or truth not in texts:
            skipped += 1
            continue
        if subset == 'gap30' and not is_gap30(row):
            continue
        selected[number] = (row, texts.index(truth), digest(line))
    return selected, skipped


def read_trace(path):
    require(not str(path).endswith('.partial'), 'partial trace is not complete')
    rows = [parse_json(line) for line in Path(path).read_bytes().splitlines() if line]
    require(len(rows) >= 3 and rows[0].get('type') == 'header' and rows[-1].get('type') == 'summary',
            'trace requires header, cases and terminal summary')
    require(all(row.get('type') == 'case' for row in rows[1:-1]), 'unexpected trace record type')
    return rows[0], rows[1:-1], rows[-1]['report']


def order(scores, fallback):
    rank = {index: position for position, index in enumerate(fallback)}
    return sorted(range(len(scores)), key=lambda i: (scores[i] is None, -(scores[i] or 0), rank[i]))


def validate_record(record, source, length):
    case, truth, line_hash = source
    candidates = case['candidates']
    count = len(candidates)
    require(record['caseLineSha256'] == line_hash and record['truthIndex'] == truth, 'case identity/truth mismatch')
    require(type(record['truthIndex']) is int and record['contextLength'] == length, 'invalid truth/length')
    require(isinstance(record.get('requestPromptSha256'), str) and SHA.fullmatch(record['requestPromptSha256']),
            'prompt fingerprint required')
    for field in ('modelOrder', 'productionOrder', 'heuristicOrder'):
        values = record[field]
        require(isinstance(values, list) and all(type(v) is int for v in values)
                and sorted(values) == list(range(count)), 'invalid ' + field)
    for field in ('literalHiraganaIndices', 'compoundIndices'):
        values = record[field]
        require(isinstance(values, list) and all(type(v) is int and 0 <= v < count for v in values)
                and len(set(values)) == len(values), 'invalid ' + field)
    for field in ('modelScores', 'productionScores'):
        values = record[field]
        require(isinstance(values, list) and len(values) == count
                and all(v is None or finite(v) for v in values), 'invalid ' + field)
    offsets = record['adjustments']
    require(isinstance(offsets, list) and len(offsets) == count, 'invalid adjustments length')
    for index, (candidate, offset) in enumerate(zip(candidates, offsets)):
        require(isinstance(offset, dict) and set(offset) == ADJUSTMENTS and all(finite(v) for v in offset.values()),
                'invalid adjustment components')
        frequency = (candidate.get('studyFrequency') or 0) if candidate.get('source') == 'study' else 0
        require(frequency >= 0, 'negative study frequency is unsupported')
        expected = dict(study=2 * math.log2(1 + frequency), context=2 * min(candidate.get('contextAffinity') or 0, 1),
                        rawHiragana=-1. if index in record['literalHiraganaIndices'] else 0.,
                        compound=2. if index in record['compoundIndices'] else 0.)
        require(all(close(offset[k], v) for k, v in expected.items()), 'source metadata/adjustment mismatch')
        score, total = record['modelScores'][index], record['productionScores'][index]
        require((score is None and total is None) or (score is not None and close(score + sum(offset.values()), total)),
                'production score does not equal native model score plus adjustments')
    require(record['modelOrder'] == order(record['modelScores'], list(range(count))), 'model ordering mismatch')
    require(record['productionOrder'] == order(record['productionScores'], record['heuristicOrder']),
            'production ordering/tie-break mismatch')


def validate_trace(raw, trace):
    header, rows, summary = trace
    require(header.get('format') == 'gyaim-native-context-trace' and type(header.get('version')) is int
            and header['version'] == 1, 'unsupported native trace schema')
    require(header['backend'] == 'LlamaZenzContext.scoreBatch' and header['configuration'] == 'Release',
            'native Release traces required')
    require(header['casesSha256'] == digest(raw), 'case file SHA256 mismatch')
    require(isinstance(header.get('modelSha256'), str) and SHA.fullmatch(header['modelSha256']), 'model SHA256 required')
    require(header.get('limit') is None, 'limited traces cannot establish full coverage')
    require(header['weights'] == WEIGHTS and all(finite(v) for v in header['weights'].values()),
            'unexpected production weights')
    require(header['subset'] in ('all', 'gap30'), 'unsupported subset')
    lengths = header['lengths']
    require(isinstance(lengths, list) and lengths and all(type(v) is int and v in (0, 5, 10, 20) for v in lengths)
            and len(set(lengths)) == len(lengths), 'invalid context lengths')
    for field in ('dictionarySha256', 'sourceFilesSha256'):
        hashes = header[field]
        require(isinstance(hashes, dict) and hashes and all(isinstance(v, str) and SHA.fullmatch(v) for v in hashes.values()),
                'missing provenance: ' + field)
    require(set(header['dictionarySha256']) == {'dict.txt', 'mozc-dict.txt'}, 'both native dictionaries required')
    selected, skipped = source_cases(raw, header['subset'])
    require(selected, 'no eligible cases')
    records, totals = {}, {str(length): Counter(n=0, modelTop1=0, productionTop1=0, heuristicTop1=0) for length in lengths}
    for record in rows:
        number, length = record['lineNumber'], record['contextLength']
        require(type(number) is int and type(length) is int and number in selected and length in lengths,
                'unexpected case line/context length')
        key = number, length
        require(key not in records, 'duplicate case line/context length')
        validate_record(record, selected[number], length)
        records[key] = record
        entry = totals[str(length)]
        entry['n'] += 1
        for prefix in ('model', 'production', 'heuristic'):
            entry[prefix + 'Top1'] += record[prefix + 'Order'][0] == record['truthIndex']
    require(set(records) == {(number, length) for number in selected for length in lengths}, 'incomplete case coverage')
    require(summary['scored'] == len(selected) and summary['skipped'] == skipped, 'summary coverage mismatch')
    for field in ('configuration', 'lengths', 'subset', 'weights'):
        require(summary[field] == header[field], 'summary condition mismatch: ' + field)
    require(set(summary['byLength']) == set(totals), 'summary lengths mismatch')
    for length, expected in totals.items():
        actual = summary['byLength'][length]
        require(all(type(actual[k]) is int and actual[k] == v for k, v in expected.items()), 'summary count mismatch')
        for prefix in ('model', 'production', 'heuristic'):
            require(close(actual[prefix + 'Top1Rate'], expected[prefix + 'Top1'] / expected['n']), 'summary rate mismatch')
    return selected, records


def outcome(before, after):
    if before and not after:
        return 'worsened'
    if after and not before:
        return 'improved'
    return 'bothCorrect' if before else 'bothWrong'


def pair_category(case, indices, converter):
    candidates = [case['candidates'][i] for i in indices]
    texts = [c['text'] for c in candidates]
    kana = lambda text: bool(re.fullmatch(r'[\u3041-\u3096\u3099-\u309f\u30a1-\u30fa\u30fc-\u30ff\uff66-\uff9f]+', text))
    kanji = lambda text: any('\u3400' <= c <= '\u9fff' or '\U00020000' <= c <= '\U0002ffff' for c in text)
    if (kana(texts[0]) and kanji(texts[1])) or (kana(texts[1]) and kanji(texts[0])):
        return 'kana-vs-kanji'
    reading = converter.convert(case['input'])
    if reading and all(c.get('kind', 'exact') in ('exact', 'compound') and c.get('reading')
                       and converter.convert(c['reading']) == reading for c in candidates):
        return 'same-reading-dictionary'  # POS/sense is not known; manual review required.
    return 'other'


def margin(values, truth, rival):
    return values[truth] - values[rival] if values[truth] is not None and values[rival] is not None else None


def analyze(raw, baseline, trial, include_text=False):
    cases, left = validate_trace(raw, baseline)
    other_cases, right = validate_trace(raw, trial)
    for field in ('casesSha256', 'backend', 'configuration', 'lengths', 'subset', 'limit', 'weights',
                  'dictionarySha256', 'sourceFilesSha256', 'platform'):
        require(baseline[0][field] == trial[0][field], 'comparison condition mismatch: ' + field)
    require(set(cases) == set(other_cases) and set(left) == set(right), 'comparison coverage mismatch')
    converter = RuntimeRomaToKata(load_roma_to_kata(ROMAKANA_SWIFT))
    tallies, categories, interactions, details = defaultdict(Counter), defaultdict(Counter), defaultdict(Counter), []
    for key in sorted(left):
        before, after = left[key], right[key]
        number, length = key
        case, truth, _ = cases[number]
        for field in ('truthIndex', 'requestPromptSha256', 'heuristicOrder', 'literalHiraganaIndices', 'compoundIndices'):
            require(before[field] == after[field], 'non-model record condition mismatch: ' + field)
        require(all(all(close(a[k], b[k]) for k in ADJUSTMENTS)
                    for a, b in zip(before['adjustments'], after['adjustments'])), 'production adjustment drift')
        statuses = {p: outcome(before[p + 'Order'][0] == truth, after[p + 'Order'][0] == truth)
                    for p in ('model', 'production')}
        subsets = [baseline[0]['subset']]
        if baseline[0]['subset'] == 'all' and is_gap30(case):
            subsets.append('gap30')
        for subset in subsets:
            tally = tallies[subset, length]
            tally['count'] += 1
            for name, record in [('base', before), ('trial', after)]:
                missing = sum(score is None for score in record['modelScores'])
                tally[name + 'UnavailableCandidates'] += missing
                tally[name + 'CasesWithUnavailable'] += missing > 0
            for prefix in ('model', 'production'):
                tally[prefix + ':' + statuses[prefix]] += 1
        if statuses['production'] not in ('improved', 'worsened'):
            continue
        rival = (after if statuses['production'] == 'worsened' else before)['productionOrder'][0]
        category = pair_category(case, (truth, rival), converter)
        adjustment_margin = {name: before['adjustments'][truth][name] - before['adjustments'][rival][name]
                             for name in sorted(ADJUSTMENTS)}
        offsets = sum(adjustment_margin.values())
        comparisons = {name: dict(modelMargin=margin(record['modelScores'], truth, rival),
                                  productionMargin=margin(record['productionScores'], truth, rival),
                                  modelTop=record['modelOrder'][0], productionTop=record['productionOrder'][0])
                       for name, record in [('base', before), ('trial', after)]}
        rescue = before['modelOrder'][0] != truth and before['productionOrder'][0] == truth
        for subset in subsets:
            categories[subset, length][statuses['production'] + ':' + category] += 1
            interaction = interactions[subset, length]
            interaction[statuses['production'] + ':model-' + statuses['model']] += 1
            if rescue:
                interaction[statuses['production'] + ':base-rescued-by-production'] += 1
            if before['heuristicOrder'][0] == truth:
                interaction[statuses['production'] + ':heuristic-correct'] += 1
        detail = dict(lineNumber=number, caseLineSha256=before['caseLineSha256'], contextLength=length,
                      gap30=is_gap30(case), outcome=statuses['production'], modelOutcome=statuses['model'],
                      category=category, truthIndex=truth, rivalIndex=rival, comparisons=comparisons,
                      adjustmentMargin=adjustment_margin, requiredModelMargin=-offsets,
                      unavailableIndices={name: [i for i, score in enumerate(record['modelScores']) if score is None]
                                          for name, record in [('base', before), ('trial', after)]},
                      tieFavoursTruth=before['heuristicOrder'].index(truth) < before['heuristicOrder'].index(rival),
                      activeAdjustmentDifferences=[k for k, v in adjustment_margin.items() if abs(v) > 1e-12])
        if include_text:
            detail['review'] = dict(input=case['input'], sourceContext=case['context'],
                                    truth=case['candidates'][truth]['text'], rival=case['candidates'][rival]['text'])
        details.append(detail)
    metrics = []
    for (subset, length), tally in sorted(tallies.items()):
        row = dict(subset=subset, contextLength=length, count=tally['count'])
        row['scoreAvailability'] = {name + metric: tally[name + metric] for name in ('base', 'trial')
                                    for metric in ('UnavailableCandidates', 'CasesWithUnavailable')}
        for prefix in ('model', 'production'):
            counts = {name: tally[prefix + ':' + name] for name in ('improved', 'worsened', 'bothCorrect', 'bothWrong')}
            counts['baseHits'] = counts['bothCorrect'] + counts['worsened']
            counts['trialHits'] = counts['bothCorrect'] + counts['improved']
            counts['net'] = counts['improved'] - counts['worsened']
            row[prefix] = counts
        row['productionChangeCategories'] = dict(categories[subset, length])
        row['interactions'] = dict(interactions[subset, length])
        metrics.append(row)
    report = dict(format='gyaim-native-context-analysis', version=1, casesSha256=digest(raw),
                  baseModelSha256=baseline[0]['modelSha256'], trialModelSha256=trial[0]['modelSha256'],
                  metrics=metrics, changeRows=len(details), includesText=include_text,
                  limitations=['Diagnostic only; no training examples are emitted.',
                               'Categories describe script/reading, not semantic correctness or POS.',
                               'Adjustment contributions are algebraic; they do not establish causal error attribution.',
                               'Repeated fixed evaluation is not independent confirmation; trace timing is diagnostic.'])
    return report, details


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path, required=True)
    parser.add_argument('--baseline-trace', type=Path, required=True)
    parser.add_argument('--trial-trace', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--include-text', action='store_true', help='private review text under ignored runs/ only')
    args = parser.parse_args()
    output = args.output.resolve()
    require(output.is_relative_to((ROOT / 'runs').resolve()) and not output.exists(), 'use a new directory under ignored runs/')
    report, details = analyze(args.cases.read_bytes(), read_trace(args.baseline_trace), read_trace(args.trial_trace), args.include_text)
    report['traceSha256'] = {key: digest(path.read_bytes()) for key, path in
                            [('base', args.baseline_trace), ('trial', args.trial_trace)]}
    output.mkdir(parents=True)
    (output / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (output / 'changes.jsonl').write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in details), encoding='utf-8')
    print(json.dumps(dict(metrics=report['metrics'], changeRows=report['changeRows']), ensure_ascii=False))


if __name__ == '__main__':
    main()
