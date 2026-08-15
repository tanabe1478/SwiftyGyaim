import json
import tempfile
import unittest
from pathlib import Path

from train_zenz import StreamingZenzSFTDataset


class FakeTokenizer:
    eos_token_id = 0

    def encode(self, text, add_special_tokens=False):
        return [ord(character) for character in text]


class StreamingZenzSFTDatasetTests(unittest.TestCase):
    def test_resume_yields_the_exact_same_next_examples(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "train.jsonl"
            rows = [
                {
                    "input": f"ヨミ{index}",
                    "output": f"出力{index}",
                    "left_context": f"文脈{index}",
                }
                for index in range(100)
            ]
            path.write_text(
                "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows),
                encoding="utf-8",
            )

            original = StreamingZenzSFTDataset(
                [path], FakeTokenizer(), max_length=192, seed=42, shuffle_buffer=16
            )
            original_iterator = iter(original)
            for _ in range(7):
                next(original_iterator)
            saved_state = original.state_dict()
            expected = [
                next(original_iterator)["input_ids"].tolist() for _ in range(20)
            ]

            resumed = StreamingZenzSFTDataset(
                [path], FakeTokenizer(), max_length=192, seed=42, shuffle_buffer=16
            )
            resumed.load_state_dict(saved_state)
            resumed_iterator = iter(resumed)
            actual = [
                next(resumed_iterator)["input_ids"].tolist() for _ in range(20)
            ]

            self.assertEqual(expected, actual)
            original.close()
            resumed.close()


if __name__ == "__main__":
    unittest.main()
