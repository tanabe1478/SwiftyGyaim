"""Synthetic native-trace validation and real Swift/Python format contract."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyze_native_context as analyzer


def fixture(newline=b'\n'):
    cases = [dict(time='synthetic', input='zou', context='全体', truth='像', gaps=[[0, 31]],
                  candidates=[dict(text='像', reading='zou', kind='exact', source='connection'),
                              dict(text='増', reading='zou', kind='exact', source='connection')]),
             dict(time='synthetic', input='siyou', context='確認した', truth='仕様', gaps=[[0, 30]],
                  candidates=[dict(text='仕様', reading='siyou', kind='exact', source='study', studyFrequency=1),
                              dict(text='使用', reading='siyou', kind='exact', source='connection')])]
    raw = newline.join(json.dumps(row, ensure_ascii=False).encode() for row in cases) + newline
    traces = []
    for name in ('base', 'trial'):
        header = dict(type='header', format='gyaim-native-context-trace', version=1,
                      backend='LlamaZenzContext.scoreBatch', configuration='Release', platform='synthetic',
                      casesSha256=analyzer.digest(raw), modelSha256=analyzer.digest(name.encode()),
                      dictionarySha256={'dict.txt': 'd' * 64, 'mozc-dict.txt': 'e' * 64},
                      sourceFilesSha256={'synthetic': 'c' * 64}, weights=analyzer.WEIGHTS.copy(),
                      lengths=[20], subset='all', limit=None)
        rows = []
        for index, case in enumerate(cases):
            scores = [-2., -1.] if name == 'base' else ([-4., -1.] if index == 0 else [-.5, -1.])
            offsets = [{k: 0. for k in analyzer.ADJUSTMENTS} for _ in range(2)]
            offsets[0]['compound' if index == 0 else 'study'] = 2.
            totals = [s + sum(o.values()) for s, o in zip(scores, offsets)]
            rows.append(dict(type='case', lineNumber=index + 1, caseLineSha256=analyzer.digest(raw.split(b'\n')[index]),
                             contextLength=20, truthIndex=0, requestPromptSha256='a' * 64,
                             modelScores=scores, productionScores=totals, adjustments=offsets,
                             modelOrder=analyzer.order(scores, [0, 1]), productionOrder=analyzer.order(totals, [0, 1]),
                             heuristicOrder=[0, 1], literalHiraganaIndices=[], compoundIndices=[0] if index == 0 else []))
        counts = dict(n=2)
        for prefix in ('model', 'production', 'heuristic'):
            counts[prefix + 'Top1'] = sum(row[prefix + 'Order'][0] == 0 for row in rows)
            counts[prefix + 'Top1Rate'] = counts[prefix + 'Top1'] / 2
        summary = dict(scored=2, skipped=0, configuration='Release', lengths=[20], subset='all',
                       weights=analyzer.WEIGHTS.copy(), byLength={'20': counts})
        traces.append((header, rows, summary))
    return raw, traces[0], traces[1]


class NativeContextAnalysisTests(unittest.TestCase):
    def test_model_improvement_can_hide_production_regression(self):
        report, changes = analyzer.analyze(*fixture())
        row = next(r for r in report['metrics'] if r['subset'] == 'all')
        self.assertEqual(row['model']['net'], 1)
        self.assertEqual(row['production']['net'], -1)
        self.assertEqual(row['productionChangeCategories'], {'worsened:same-reading-dictionary': 1})
        self.assertEqual(row['interactions']['worsened:base-rescued-by-production'], 1)
        change, = changes
        self.assertEqual(change['requiredModelMargin'], -2)
        self.assertEqual(change['comparisons']['base']['modelMargin'], -1)
        self.assertEqual(change['comparisons']['trial']['modelMargin'], -3)
        self.assertEqual(change['activeAdjustmentDifferences'], ['compound'])
        self.assertNotIn('review', change)
        self.assertNotIn('像', json.dumps(report, ensure_ascii=False))
        self.assertNotIn('像', json.dumps(changes, ensure_ascii=False))

    def test_native_gap_is_strictly_greater_than_30_and_crlf_hashes_are_exact(self):
        for newline in (b'\n', b'\r\n'):
            report, _ = analyzer.analyze(*fixture(newline))
            gap = next(r for r in report['metrics'] if r['subset'] == 'gap30')
            self.assertEqual(gap['count'], 1)
            self.assertEqual(gap['production']['net'], -1)

    def test_text_requires_explicit_opt_in(self):
        report, changes = analyzer.analyze(*fixture(), include_text=True)
        self.assertTrue(report['includesText'])
        self.assertEqual(changes[0]['review'], dict(input='zou', sourceContext='全体', truth='像', rival='増'))

    def test_truth_uses_swift_canonical_equivalence_and_first_matching_index(self):
        case = dict(time='synthetic', input='ga', context='', truth='が', gaps=[],
                    candidates=[dict(text='か\u3099'), dict(text='が')])
        raw = json.dumps(case, ensure_ascii=False).encode()
        cases, skipped = analyzer.source_cases(raw, 'all')
        self.assertEqual(skipped, 0)
        self.assertEqual(cases[1][1], 0)
        self.assertEqual(cases[1][2], analyzer.digest(raw))

    def test_incomplete_duplicate_and_mismatched_source_are_rejected(self):
        raw, base, trial = fixture()
        for rows in (trial[1][:-1], trial[1] + trial[1][:1]):
            with self.assertRaises(ValueError):
                analyzer.analyze(raw, base, (trial[0], rows, trial[2]))
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            analyzer.analyze(raw + b'\n', base, trial)
        trial[1][0]['caseLineSha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'identity'):
            analyzer.analyze(raw, base, trial)

    def test_summary_and_native_totals_are_checked_against_records(self):
        raw, base, trial = fixture()
        damaged = copy.deepcopy(trial)
        damaged[2]['byLength']['20']['productionTop1'] += 1
        with self.assertRaisesRegex(ValueError, 'count mismatch'):
            analyzer.analyze(raw, base, damaged)
        damaged = copy.deepcopy(trial)
        damaged[1][0]['productionScores'][0] += .1
        with self.assertRaisesRegex(ValueError, 'plus adjustments'):
            analyzer.analyze(raw, base, damaged)

    def test_unavailable_scores_are_visible_and_never_become_zero_margins(self):
        raw, base, trial = fixture()
        trial[1][0]['modelScores'][0] = None
        trial[1][0]['productionScores'][0] = None
        report, changes = analyzer.analyze(raw, base, trial)
        row = next(r for r in report['metrics'] if r['subset'] == 'all')
        self.assertEqual(row['scoreAvailability']['trialUnavailableCandidates'], 1)
        self.assertEqual(row['scoreAvailability']['trialCasesWithUnavailable'], 1)
        self.assertIsNone(changes[0]['comparisons']['trial']['modelMargin'])
        self.assertIsNone(changes[0]['comparisons']['trial']['productionMargin'])
        self.assertEqual(changes[0]['unavailableIndices']['trial'], [0])

    def test_mismatched_environment_and_limited_runs_are_rejected(self):
        raw, base, trial = fixture()
        for field, value in [('dictionarySha256', {'dict.txt': 'f'*64, 'mozc-dict.txt': 'e'*64}),
                             ('sourceFilesSha256', {'other': 'f'*64}), ('platform', 'different')]:
            damaged = copy.deepcopy(trial)
            damaged[0][field] = value
            with self.assertRaisesRegex(ValueError, 'condition mismatch'):
                analyzer.analyze(raw, base, damaged)
        for field, value in [('configuration', 'Debug'), ('limit', 1), ('weights', {**analyzer.WEIGHTS, 'study': 3})]:
            damaged = copy.deepcopy(trial)
            damaged[0][field] = value
            with self.assertRaises(ValueError):
                analyzer.analyze(raw, base, damaged)

    def test_ties_follow_heuristic_but_model_ties_follow_original_order(self):
        raw, base, trial = fixture()
        for trace in (base, trial):
            row = trace[1][0]
            row.update(modelScores=[-3., -1.], productionScores=[-1., -1.],
                       modelOrder=[1, 0], heuristicOrder=[1, 0], productionOrder=[1, 0])
            trace[2]['byLength']['20']['productionTop1'] = 1
            trace[2]['byLength']['20']['productionTop1Rate'] = .5
            trace[2]['byLength']['20']['heuristicTop1'] = 1
            trace[2]['byLength']['20']['heuristicTop1Rate'] = .5
        analyzer.analyze(raw, base, trial)
        trial[1][0]['productionOrder'] = [0, 1]
        with self.assertRaisesRegex(ValueError, 'tie-break'):
            analyzer.analyze(raw, base, trial)

    def test_categories_are_script_or_reading_diagnostics_not_pos_labels(self):
        class Converter:
            def convert(self, value): return value
        case = dict(input='kana', candidates=[dict(text='かな'), dict(text='仮名')])
        self.assertEqual(analyzer.pair_category(case, (0, 1), Converter()), 'kana-vs-kanji')
        case['candidates'][0]['text'] = '・'
        self.assertEqual(analyzer.pair_category(case, (0, 1), Converter()), 'other')
        case['candidates'] = [dict(text='仕様', kind='exact', reading='kana'), dict(text='使用', kind='exact', reading='kana')]
        self.assertEqual(analyzer.pair_category(case, (0, 1), Converter()), 'same-reading-dictionary')
        case['candidates'][1]['kind'] = 'prefix'
        self.assertEqual(analyzer.pair_category(case, (0, 1), Converter()), 'other')

    def test_partial_or_missing_footer_cannot_be_read_as_complete(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'trace.jsonl'
            path.write_text('{"type":"header"}\n{"type":"case"}\n')
            with self.assertRaises(ValueError):
                analyzer.read_trace(path)
            with self.assertRaisesRegex(ValueError, 'partial'):
                analyzer.read_trace(str(path) + '.partial')

    @unittest.skipUnless(os.environ.get('GYAIM_NATIVE_TRACE_TEST_DIR'), 'Swift contract fixture is produced by macOS test runner')
    def test_actual_swift_serialization_matches_python_contract(self):
        root = Path(os.environ['GYAIM_NATIVE_TRACE_TEST_DIR'])
        report, changes = analyzer.analyze((root / 'cases.jsonl').read_bytes(),
                                           analyzer.read_trace(root / 'base.jsonl'), analyzer.read_trace(root / 'trial.jsonl'))
        row = next(r for r in report['metrics'] if r['subset'] == 'all')
        self.assertEqual((row['model']['net'], row['production']['net']), (1, -1))
        self.assertEqual(changes[0]['adjustmentMargin']['compound'], 2.)


if __name__ == '__main__':
    unittest.main()
