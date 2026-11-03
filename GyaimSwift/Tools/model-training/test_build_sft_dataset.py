"""stdlib-only tests for build_sft_dataset.py (issue #125)."""
import json
import tempfile
import unittest
from pathlib import Path

import build_sft_dataset as b


def log_line(time, kind, input_pat, payload):
    return f"[{time}] [input] [info] {kind}: input=\"{input_pat}\" payload={json.dumps(payload, ensure_ascii=False)}\n"


def accepted(time, controller, input_pat, word, context, composition=1):
    return log_line(time, "Fast context accepted detail", input_pat, {
        "controller": controller, "composition": composition, "generation": composition,
        "context": context, "chosenRank": 1,
        "top": [{"rank": 0, "word": input_pat}, {"rank": 1, "word": word}],
    })


def kana_commit(time, controller, input_pat, path, context, composition=1):
    return log_line(time, "Commit outcome", input_pat, {
        "controller": controller, "composition": composition, "generation": composition,
        "context": context, "path": path,
    })


class BuildSftDatasetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.converter = b.RomaToKata(b.load_roma_to_kata(b.ROMAKANA_SWIFT))

    def write_log(self, lines):
        path = Path(tempfile.mkdtemp()) / "gyaim.log"
        path.write_text("".join(lines), encoding="utf-8")
        return path

    def test_kana_commits_become_pairs_and_other_paths_are_ignored(self):
        path = self.write_log([
            kana_commit("2026-11-03 18:02:21", "A", "gomenn", "kana-hiragana", ""),
            kana_commit("2026-11-03 18:02:22", "A", "ripojitori", "kana-katakana", "ごめん", 2),
            kana_commit("2026-11-03 18:02:23", "A", "saikai", "prefix", "ごめんリポジトリ", 3),
        ])
        events = list(b.iter_events([path], self.converter))
        self.assertEqual([(e["word"], e["source"]) for e in events],
                         [("ごめん", "kana"), ("リポジトリ", "kana")])

    def test_retyped_first_commit_is_dropped(self):
        events = [
            {"time": "2026-10-22 14:01:33", "controller": "A", "input": "saku", "word": "作成", "context": "回避", "source": "accepted"},
            {"time": "2026-10-22 14:01:35", "controller": "A", "input": "saku", "word": "策", "context": "回避作成", "source": "accepted"},
            {"time": "2026-10-27 15:27:29", "controller": "B", "input": "kenn", "word": "件", "context": "徒歩", "source": "accepted"},
            {"time": "2026-10-27 15:27:32", "controller": "B", "input": "kennnai", "word": "圏内", "context": "徒歩件", "source": "accepted"},
            {"time": "2026-10-27 15:30:00", "controller": "B", "input": "kenn", "word": "県", "context": "x", "source": "accepted"},
            {"time": "2026-10-27 15:30:01", "controller": "B", "input": "kenn", "word": "県", "context": "x県", "source": "accepted"},
        ]
        kept, dropped = b.drop_retyped(events)
        self.assertEqual(dropped, 2)
        self.assertEqual([e["word"] for e in kept], ["策", "圏内", "県", "県"],
                         "same word twice and a retype after the window are kept")

    def test_context_variants_are_distinct_tails(self):
        self.assertEqual(b.context_variants("てごめん再開してリポジトリ残る作業の全体", [20, 10, 5, 0]),
                         ["てごめん再開してリポジトリ残る作業の全体", "ジトリ残る作業の全体", "作業の全体", None])
        self.assertEqual(b.context_variants("全体", [20, 10, 5, 0]), ["全体", None])
        self.assertEqual(b.context_variants(None, [20, 0]), [None])

    def test_archive_and_rotated_log_overlap_is_deduplicated(self):
        line = accepted("2026-11-03 18:06:35", "A", "zou", "像", "残る作業の全体")
        first, second = self.write_log([line]), self.write_log([line])
        self.assertEqual(len(list(b.iter_events([first, second], self.converter))), 1)

    def test_katakana_to_hiragana(self):
        self.assertEqual(b.katakana_to_hiragana("ゾウ"), "ぞう")
        self.assertEqual(b.katakana_to_hiragana("リポジトリー"), "りぽじとりー")


if __name__ == "__main__":
    unittest.main()
