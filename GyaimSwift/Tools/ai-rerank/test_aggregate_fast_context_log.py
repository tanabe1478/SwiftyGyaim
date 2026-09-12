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


if __name__ == "__main__":
    unittest.main()
