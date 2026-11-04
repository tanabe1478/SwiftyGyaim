"""Synthetic-only regression tests for issue #125 preparation and fixed audits."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_context_training as prep
from evaluate_context_cases import case_hash, summarize, LENGTHS


class ContextTrainingTests(unittest.TestCase):
    def test_long_context_recipe_does_not_create_short_variants(self):
        rows = [dict(input='カナ', output='仮名', left_context='元の発言を連結した十分に長い文脈'),
                dict(input='カナ', output='仮名', left_context='短い'),
                dict(input='カナ', output='仮名', left_context=None)]
        train, valid, stats = prep.partition(rows, set(), .5, 125, (20,), 11)
        self.assertEqual(len(train+valid), 1)
        self.assertEqual((train+valid)[0]['left_context'], rows[0]['left_context'][-20:])
        self.assertEqual(stats['shortContextExcluded'], 2)

    def test_context_variants_share_a_split_and_exclude_every_context(self):
        rows = [dict(input=f'カナ{i}', output=f'語{i}', left_context=context)
                for i in range(50) for context in ['前の発言設定画面を開く', '別の文脈', None]]
        excluded = {prep.pair_key('カナ0', '語0')}
        train, valid, stats = prep.partition(rows, excluded, .3, 125)
        keys = lambda rs: {prep.pair_key(r['input'], r['output']) for r in rs}
        self.assertTrue(train and valid)
        self.assertFalse(keys(train) & keys(valid))
        self.assertFalse((keys(train) | keys(valid)) & excluded)
        self.assertEqual(stats['excludedRows'], 3)
        self.assertTrue(all(len(r['left_context'] or '') <= 20 for r in train+valid))
        self.assertEqual((train, valid, stats), prep.partition(rows, excluded, .3, 125))
        self.assertEqual(keys(train), keys(prep.partition(reversed(rows), excluded, .3, 125)[0]))

    def test_corrected_and_original_labels_both_excluded(self):
        class Converter:
            def convert(self, value):
                return {'zou': 'ゾウ'}.get(value)
        excluded, count = prep.context_holdout([
            dict(input='zou', chosen='増', truth='像')], Converter())
        self.assertEqual(count, 1)
        self.assertEqual(excluded, {('ゾウ', '増'), ('ゾウ', '像')})
        with self.assertRaises(ValueError):
            prep.context_holdout([dict(input='unknown', truth='像')], Converter())
        with self.assertRaises(ValueError):
            prep.context_holdout([], Converter())

    def test_normalized_pairs_and_null_context(self):
        self.assertEqual(prep.pair_key('か\u3099', 'か\u3099'), ('ガ', 'が'))
        train, valid, _ = prep.partition([dict(input='カナ', output='仮名', left_context=None)], set(), .5, 3)
        self.assertEqual(len(train+valid), 1)
        self.assertIsNone((train+valid)[0]['left_context'])

    def test_runtime_reading_matches_trailing_n_and_partial_input(self):
        converter = prep.RuntimeRomaToKata(prep.load_roma_to_kata(prep.ROMAKANA_SWIFT))
        for text, expected in [('hon', 'ホン'), ('hontou', 'ホントウ'), ('kit', 'キ'),
                               ('kitte', 'キッテ'), ('kaN', 'カン'), ('xyz', '')]:
            self.assertEqual(converter.convert(text), expected)

    def test_end_to_end_manifest_and_public_domain_isolation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def write(name, rows):
                path = root/name
                path.write_text(''.join(json.dumps(r, ensure_ascii=False)+'\n' for r in rows), encoding='utf-8')
                return path
            rows = [dict(input=f'カナ{i}', output=f'語{i}', left_context='合成した文脈') for i in range(100)]
            domain = write('domain.jsonl', rows)
            public = write('public.jsonl', [{**r, 'left_context': '異なる公開文脈'} for r in rows])
            cases = write('cases.jsonl', [dict(inputKana='カナ0', chosen='語0', truth='訂正')])
            holdout = write('holdout.jsonl', [dict(input='カナ1', chosen='語1')])
            with patch.object(prep, 'ROOT', root):
                output = root/'data/run'
                manifest = prep.prepare(domain, cases, [holdout], [public], output, .3)
                for name, expected in manifest['outputs'].items():
                    self.assertEqual(prep.digest(output/name), expected)
                train, valid = [list(prep.read_rows(output/f'{name}.jsonl')) for name in ['train', 'valid']]
                train_keys = {(r['input'], r['output']) for r in train}
                valid_keys = {(r['input'], r['output']) for r in valid}
                self.assertFalse(train_keys & valid_keys)
                self.assertNotIn(('カナ0', '語0'), train_keys | valid_keys)
                self.assertNotIn(('カナ1', '語1'), train_keys | valid_keys)
                with self.assertRaises(ValueError):
                    prep.prepare(domain, cases, [], [], root/'public-output')
                with self.assertRaises(ValueError):
                    prep.prepare(domain, cases, [], [], output)


class FixedEvaluationTests(unittest.TestCase):
    def test_native_whitespace_preserves_tags_and_fullwidth_spaces(self):
        from evaluate_context_cases import preprocess_for_scoring
        text = '\uEE02前 の\n文\u3000\uEE00カナ\uEE01'
        self.assertEqual(preprocess_for_scoring(text, 'hf'), text)
        self.assertEqual(preprocess_for_scoring(text, 'native-whitespace'),
                         '\uEE02前\u3000の文\u3000\uEE00カナ\uEE01')
        with self.assertRaises(ValueError):
            preprocess_for_scoring(text, 'unknown')

    def test_paired_comparison_requires_every_context_length_to_improve(self):
        from compare_context_runs import compare
        baseline = dict(casesSha256='same', backend='HF-proxy', model='base', records=self.records)
        trial = dict(baseline, model='trial', records=[{**r, 'scores': [-2., -1.]} for r in self.records])
        result = compare(self.cases, baseline, trial)
        self.assertFalse(result['allContextLengthsImproved'])
        first = next(r for r in result['paired'] if r['subset']=='all' and r['contextLength']==0)
        self.assertEqual(first['net'], 1)
        with self.assertRaises(ValueError):
            compare(self.cases, baseline, dict(trial, casesSha256='different'))
        with self.assertRaises(ValueError):
            compare(self.cases, baseline, dict(trial, precision='fp32'))
        with self.assertRaises(ValueError):
            compare(self.cases, baseline, dict(trial, textPreprocessing='native-whitespace'))

    def setUp(self):
        self.cases = [dict(input='zou', context='合成した全体', chosen='増', truth='像',
                           gaps=[[2, 30]], candidates=[dict(text='増'), dict(text='像')]),
                      dict(input='kana', context='', chosen='仮名', truth='仮名', gaps=[], candidates=[])]
        self.records = [dict(caseIndex=0, caseHash=case_hash(self.cases[0]), contextLength=n,
                             scores=[-1., -2.] if n == 0 else [-2., -1.]) for n in LENGTHS]

    def test_corrected_truth_gap_subset_and_four_lengths(self):
        report = summarize(self.cases, self.records, 'HF-proxy')
        self.assertEqual(report['totalCases'], 2)
        self.assertEqual(report['eligibleCases'], 1)
        self.assertEqual(len(report['metrics']), 8)
        for metric in report['metrics']:
            self.assertEqual(metric['modelTop1'], 0 if metric['contextLength'] == 0 else 1)
            self.assertIsNone(metric['productionTop1'])

    def test_missing_mismatched_duplicate_scores_fail_closed(self):
        for mutate in [lambda rs: rs.pop(), lambda rs: rs.append(rs[0]),
                       lambda rs: rs[0].update(caseHash='wrong'),
                       lambda rs: rs[0].update(scores=[1]),
                       lambda rs: rs[0].update(scores=[float('nan'), 1])]:
            records = copy.deepcopy(self.records)
            mutate(records)
            with self.assertRaises(ValueError):
                summarize(self.cases, records, 'HF-proxy')

    def test_missing_truth_is_counted_as_miss_not_filtered_out(self):
        cases = copy.deepcopy(self.cases)
        cases[0]['truth'] = '候補外'
        records = [{**r, 'caseHash': case_hash(cases[0])} for r in self.records]
        report = summarize(cases, records, 'HF-proxy')
        self.assertTrue(all(m['truthAbsent'] == 1 and m['modelHits'] == 0 for m in report['metrics']))

    def test_native_production_order_ties_and_null_scores(self):
        records = [{**r, 'scores': [None, None], 'productionScores': [0., 0.],
                    'productionOrder': [1, 0]} for r in self.records]
        report = summarize(self.cases, records, 'LlamaZenzContext.scoreBatch')
        self.assertTrue(all(m['productionTop1'] == 1 and m['unavailable'] == 1 for m in report['metrics']))
        with self.assertRaises(ValueError):
            summarize(self.cases, records, 'HF-proxy')
        records[0]['productionOrder'] = [0, 0]
        with self.assertRaises(ValueError):
            summarize(self.cases, records, 'LlamaZenzContext.scoreBatch')


if __name__ == '__main__':
    unittest.main()
