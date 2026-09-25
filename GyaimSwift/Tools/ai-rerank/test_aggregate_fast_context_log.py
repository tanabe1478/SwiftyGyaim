import importlib.util
import json
from datetime import datetime
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("aggregate-fast-context-log.py")
SPEC = importlib.util.spec_from_file_location("aggregate_fast_context_log", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
# The module defines @dataclass types, which resolve their annotations through
# sys.modules[__module__]; register it before executing.
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def detail(ts, payload):
    return f'[{ts}] [input] [info] Fast context accepted detail: input="x" payload={payload}'


class ModelEffectTests(unittest.TestCase):
    def test_scores_applied_changed_commits_against_heuristic_rank(self):
        lines = [
            # model moved the chosen word up (heuristic 2 -> displayed 1)
            detail("2026-09-13 10:00:00", '{"chosenRank":1,"heuristicRank":2,"modelState":"applied-changed","top":[]}'),
            # model moved the chosen word down (heuristic 1 -> displayed 3)
            detail("2026-09-13 10:00:01", '{"chosenRank":3,"heuristicRank":1,"modelState":"applied-changed","top":[]}'),
            # model changed other rows only
            detail("2026-09-13 10:00:02", '{"chosenRank":1,"heuristicRank":1,"modelState":"applied-changed","top":[]}'),
            detail("2026-09-13 10:00:03", '{"chosenRank":1,"heuristicRank":1,"modelState":"applied-unchanged","top":[]}'),
            detail("2026-09-13 10:00:04", '{"chosenRank":2,"heuristicRank":2,"modelState":"cancelled","top":[]}'),
            detail("2026-09-13 10:00:05", '{"chosenRank":1,"modelState":"not-scheduled","top":[]}'),
            # pre-trace line without modelState is ignored
            detail("2026-09-13 10:00:06", '{"chosenRank":1,"top":[]}'),
        ]
        result = MODULE.collect_model_effect(lines, cutoff=None)

        self.assertEqual(result["count"], 6)
        self.assertEqual(result["byModelState"], {
            "applied-changed": 3, "applied-unchanged": 1, "cancelled": 1, "not-scheduled": 1,
        })
        self.assertEqual(result["appliedChanged"], {
            "scored": 3, "improved": 1, "worsened": 1, "same": 1, "netImproved": 0,
        })
        # cancelled 1 out of (applied 4 + cancelled 1) scheduled reviews
        self.assertEqual(result["committedBeforeReviewRate"], 0.2)
        self.assertEqual(result["top1RateByModelState"]["cancelled"], 0.0)

    def test_tail_rank_gain_and_harm_are_measured_even_with_same_top(self):
        rows = [
            {"chosenRank": 2, "heuristicRank": 3, "proposedRank": 2},
            {"chosenRank": 3, "heuristicRank": 2, "proposedRank": 3},
            {"chosenRank": 1, "heuristicRank": 1, "proposedRank": 1},
        ]
        lines = [detail("2026-09-13 10:00:00", json.dumps(dict(row, modelState="applied-changed",
                                                            modelOutcome="exact-homophone-tail-reranked"))) for row in rows]
        result = MODULE.collect_model_effect(lines, None)
        self.assertEqual(result["rankEffect"]["improved"], 1)
        self.assertEqual(result["rankEffect"]["worsened"], 1)
        self.assertEqual(result["rankEffect"]["same"], 1)
        self.assertEqual(result["rankEffect"]["meanRankGain"], 0)
        self.assertEqual(result["byOutcome"]["exact-homophone-tail-reranked"]["scored"], 3)

    def test_sync_skip_failure_and_cancelled_have_distinct_denominators(self):
        rows = [
            {"modelState": "applied-changed", "deferred": False, "heuristicRank": 3},
            {"modelState": "applied-unchanged", "deferred": True, "heuristicRank": 1},
            {"modelState": "skipped", "deferred": True},
            {"modelState": "unavailable", "deferred": True},
            {"modelState": "cancelled", "deferred": True},
            {"modelState": "not-scheduled", "deferred": False},
        ]
        result = MODULE.collect_model_effect([detail("2026-09-13 10:00:00", json.dumps(dict(row, chosenRank=1))) for row in rows], None)
        self.assertEqual(result["deferredCommitCount"], 4)
        self.assertEqual(result["committedBeforeReviewRate"], 0.25)
        self.assertEqual(result["rankEffect"]["scored"], 2)
        self.assertEqual(result["rankEffect"]["rankGainSum"], 2)

    def test_v2_identity_cutoff_and_duplicate_rotation_lines(self):
        row = dict(traceVersion=2, controller="a", composition=1, generation=4,
                   chosenRank=2, heuristicRank=3, proposedRank=2, modelState="applied-changed")
        line = detail("2026-09-13 10:00:00", json.dumps(row))
        other_controller = detail("2026-09-13 10:00:01", json.dumps(dict(row, controller="b")))
        old = detail("2026-09-12 10:00:00", json.dumps(dict(row, controller="c")))
        result = MODULE.collect_model_effect([old, line, line, other_controller], datetime(2026, 9, 13))
        self.assertEqual(result["count"], 2)
        self.assertEqual(result["rankEffect"]["netImproved"], 2)

    def test_malformed_payload_raw_and_inconsistent_display_are_not_scored(self):
        rows = [{}, {"modelState": []}, {"modelState": "unknown"},
                {"modelState": "applied-changed", "chosenRank": True},
                {"modelState": "applied-changed", "chosenRank": 0, "heuristicRank": 1},
                {"modelState": "applied-changed", "chosenRank": 1, "heuristicRank": -1},
                {"modelState": "applied-changed", "chosenRank": 1, "heuristicRank": True},
                {"modelState": "applied-changed", "chosenRank": 1, "heuristicRank": 2, "proposedRank": True},
                {"modelState": "applied-changed", "chosenRank": 1, "heuristicRank": 3, "proposedRank": 2}]
        result = MODULE.collect_model_effect([detail("2026-09-13 10:00:00", json.dumps(row)) for row in rows]
                                             + [detail("2026-09-13 10:00:00", '{broken}')], None)
        self.assertEqual(result["rankEffect"]["scored"], 0)

    def test_empty_when_no_detail_lines(self):
        self.assertEqual(MODULE.collect_model_effect(["noise"], cutoff=None), {"count": 0})


class RerankParsingTests(unittest.TestCase):
    def test_legacy_and_tagged_logs_recompute_actual_top_change(self):
        for tag in ["", "composition=1 gen=4 pass=prereview ",
                    "controller=uuid composition=1 gen=4 pass=review "]:
            line = ('[2026-09-13 10:00:00] [input] [info] Fast context rerank finished: input="kou" '
                    + tag + 'model=swift-fast-context-heuristic-prereview topChanged=true '
                    'candidates=3/3 context=present order=[0, 2, 1] before=["甲", "公", "校"] '
                    'after=["甲", "校", "公"] latency=0.5ms')
            event = MODULE.parse_fast_context_line(line)
            self.assertIsNotNone(event)
            self.assertFalse(event.top_changed)
            self.assertEqual(event.outcome, "heuristic-prereview")
            # The manual-review extractor must accept exactly the same format.
            spec = importlib.util.spec_from_file_location("review_cases", MODULE_PATH.with_name("extract-fast-context-review-cases.py"))
            extractor = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = extractor
            spec.loader.exec_module(extractor)
            case = extractor.parse_case(line, 1)
            self.assertIsNotNone(case)
            self.assertFalse(case.topChanged)

    def test_tail_outcome_is_not_generic_review(self):
        self.assertEqual(MODULE.infer_outcome("x-review-exact-homophone-tail-reranked+swift-local-heuristic"),
                         "exact-homophone-tail-reranked")


def rerank(ts, inp, after):
    return (f'[{ts}] [input] [info] Fast context rerank finished: input="{inp}" controller=C composition=1 gen=1 '
            f'pass=review model=m outcome=heuristic topChanged=true candidates=2/2 context=present order=[0, 1] '
            f'before={json.dumps(after, ensure_ascii=False)} after={json.dumps(after, ensure_ascii=False)} latency=0.1ms')


def info(ts, text):
    return f"[{ts}] [input] [info] {text}"


class CommitOutcomeTests(unittest.TestCase):
    def test_classifies_every_commit_path(self):
        lines = [
            # prefix top1 / lower / raw
            info("2026-09-24 10:00:00", "search(ki, prefix): 1.0ms"),
            rerank("2026-09-24 10:00:00", "ki", ["木", "気"]),
            info("2026-09-24 10:00:01", 'Fixed: "木" (reading: "ki", index: 1/3, candidates: ["ki", "木", "気"])'),
            info("2026-09-24 10:00:02", "search(ki, prefix): 1.0ms"),
            info("2026-09-24 10:00:03", 'Fixed: "気" (reading: "ki", index: 2/3, candidates: ["ki", "木", "気"])'),
            info("2026-09-24 10:00:04", "search(2, prefix): 1.0ms"),
            info("2026-09-24 10:00:05", 'Fixed: "2" (reading: "2", index: 0/1, candidates: ["2"])'),
            # exact escape: prefix head demoted 見た out of the top 8 (the 見た/見たい case)
            info("2026-09-24 10:00:06", "search(mita, prefix): 1.0ms"),
            rerank("2026-09-24 10:00:06", "mita", ["満た", "観た"]),
            info("2026-09-24 10:00:07", "search(mita, exact): 1.0ms"),
            info("2026-09-24 10:00:08", 'Fixed: "見た" (reading: "mita", index: 4/7, candidates: ["みた", "見た"])'),
            # kana commits
            rerank("2026-09-24 10:00:09", "site", ["して", "指摘"]),
            info("2026-09-24 10:00:10", 'Fixed as kana(hiragana): "して" (input: "site", candidates: 3)'),
            # sita is also converted to kanji elsewhere, so its kana commit is suspected
            info("2026-09-24 09:59:00", 'Fixed: "下" (reading: "sita", index: 1/3, candidates: ["sita", "下"])'),
            rerank("2026-09-24 10:00:11", "sita", ["下", "した"]),
            info("2026-09-24 10:00:12", 'Fixed as kana(hiragana): "した" (input: "sita", candidates: 3)'),
            info("2026-09-24 09:59:01", 'Fixed: "時" (reading: "to", index: 1/3, candidates: ["to", "時"])'),
            rerank("2026-09-24 10:00:13", "to", ["時", "等"]),
            info("2026-09-24 10:00:14", 'Fixed as kana(hiragana): "と" (input: "to", candidates: 3)'),
            info("2026-09-24 10:00:15", 'Fixed as kana(hiragana): "おきましたよ" (input: "okimasitayo", candidates: 2)'),
            # particle never converted to kanji: kana key on purpose
            rerank("2026-09-24 10:00:15", "no", ["能", "野"]),
            info("2026-09-24 10:00:15", 'Fixed as kana(hiragana): "の" (input: "no", candidates: 3)'),
            # Enter on the raw input for a word the prefix list already ranked first
            info("2026-09-24 10:00:15", "search(de, prefix): 1.0ms"),
            rerank("2026-09-24 10:00:15", "de", ["出", "手"]),
            info("2026-09-24 10:00:15", "search(de, exact): 1.0ms"),
            info("2026-09-24 10:00:15", 'Fixed: "出" (reading: "de", index: 2/3, candidates: ["で", "デ", "出"])'),
            # google for a word the prefix list already ranked first
            rerank("2026-09-24 10:00:15", "youkakuninn", ["要確認"]),
            info("2026-09-24 10:00:15", 'Google Transliterate triggered: "youkakuninn"'),
            info("2026-09-24 10:00:15", 'Fixed: "要確認" (reading: "youkakuninn", index: 1/2, candidates: ["youkakuninn", "要確認"])'),
            # google
            info("2026-09-24 10:00:16", 'Google Transliterate triggered: "toriniku"'),
            info("2026-09-24 10:00:17", 'Fixed: "鶏肉" (reading: "toriniku", index: 1/3, candidates: ["toriniku", "鶏肉"])'),
            # deactivation
            info("2026-09-24 10:00:18", "search(ki, prefix): 1.0ms"),
            info("2026-09-24 10:00:19", 'Fixed: "木" (reading: "ki", index: 1/3, candidates: ["ki", "木", "気"])'),
            info("2026-09-24 10:00:19", 'Study skipped (deactivation): "木" (reading: "ki")'),
        ]
        result = MODULE.collect_commit_outcomes(lines, cutoff=None)

        self.assertEqual(result["count"], 15)
        self.assertEqual(result["byPath"], {
            "prefix-top1": 3, "kana-top1": 1, "exact-top1": 1, "google-top1": 1,
            "prefix-lower": 1, "exact-escape": 1, "kana-other": 1, "kana-absent": 1, "google": 1,
            "prefix-raw": 1, "kana-no-dictionary": 1, "kana-intended": 1, "deactivation": 1,
        })
        self.assertEqual(result["decidable"], 11)
        self.assertEqual(result["firstCandidateRate"], round(6 / 11, 3))
        self.assertEqual(result["strictMissRate"], round(3 / 11, 3))
        self.assertEqual(result["suspectedMissRate"], round(5 / 11, 3))
        self.assertEqual(result["exactEscapePrefixRank"], {"inHead": 0, "notInHead": 1})
        self.assertEqual(result["examples"]["exact-escape"][0]["word"], "見た")

    def test_cutoff_drops_older_commits(self):
        lines = [
            info("2026-09-24 09:00:00", 'Fixed: "木" (reading: "ki", index: 1/3, candidates: [])'),
            info("2026-09-24 10:00:00", 'Fixed: "気" (reading: "ki", index: 2/3, candidates: [])'),
        ]
        result = MODULE.collect_commit_outcomes(lines, cutoff=datetime(2026, 9, 24, 9, 30))
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["byPath"]["prefix-lower"], 1)



class CommitDiagnosticsTests(unittest.TestCase):
    def test_misses_are_split_by_prefix_rank_and_scored_set(self):
        def outcome(payload):
            return info("2026-09-24 10:00:00", f'Commit outcome: input="x" payload={json.dumps(payload)}')
        lines = [
            outcome({"path": "prefix", "prefixRank": 1, "inScoredSet": True}),
            outcome({"path": "prefix", "prefixRank": 0}),
            outcome({"path": "kana-hiragana", "prefixRank": 1}),
            outcome({"path": "deactivation", "prefixRank": 5}),
            # misses
            outcome({"path": "exact", "prefixRank": 23, "inScoredSet": False,
                     "modelOutcome": "exact-homophone-fixed"}),
            outcome({"path": "prefix", "prefixRank": 2, "inScoredSet": True,
                     "modelOutcome": "exact-homophone-passed"}),
            outcome({"path": "kana-hiragana", "modelState": "not-scheduled"}),
            outcome({"path": "google"}),
            # not misses: Enter on raw for a rank-1 word, kana for a reading never converted
            outcome({"path": "exact", "prefixRank": 1}),
            outcome({"path": "google", "prefixRank": 1}),
        ]
        result = MODULE.collect_commit_diagnostics(lines, cutoff=None)

        self.assertEqual(result["count"], 10)
        self.assertEqual(result["missCount"], 3)
        self.assertEqual(result["kanaIntended"], 1)
        self.assertEqual(result["misses"]["byPrefixRank"], {"2-3": 1, "9+": 1, "absent": 1})
        self.assertEqual(result["misses"]["byScoredSet"], {"noReview": 1, "notScored": 1, "scored": 1})
        self.assertEqual(result["misses"]["byModelOutcome"], {
            "exact-homophone-fixed": 1, "exact-homophone-passed": 1, "no-trace": 1,
        })


if __name__ == "__main__":
    unittest.main()
