import json
import tempfile
import unittest
from pathlib import Path

from train_zenz import (
    STREAMING_EXHAUSTION_MESSAGE,
    StreamingZenzSFTDataset,
    train_allowing_streaming_exhaustion,
)


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
            resumed = None
            try:
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
            finally:
                original.close()
                if resumed is not None:
                    resumed.close()

    def test_multiple_sources_are_interleaved_in_proportion_to_row_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / "small.jsonl", Path(directory) / "large.jsonl"]
            for path, prefix, count in zip(paths, ("S", "L"), (4, 12)):
                path.write_text(
                    "".join(
                        json.dumps(
                            {"input": f"{prefix}{index}", "output": prefix},
                            ensure_ascii=False,
                        )
                        + "\n"
                        for index in range(count)
                    ),
                    encoding="utf-8",
                )

            dataset = StreamingZenzSFTDataset(
                paths,
                FakeTokenizer(),
                max_length=192,
                seed=42,
                shuffle_buffer=0,
                row_counts=[4, 12],
            )
            try:
                iterator = iter(dataset)
                yielded = [next(iterator)["input_ids"].tolist() for _ in range(8)]
                small_examples = sum(ord("S") in input_ids for input_ids in yielded)
                large_examples = sum(ord("L") in input_ids for input_ids in yielded)

                self.assertEqual((2, 6), (small_examples, large_examples))
            finally:
                dataset.close()


class FakeTrainer:
    def __init__(self, error=None, global_step=123):
        self.error = error
        self.resume_checkpoint = None
        self.state = type("State", (), {"global_step": global_step})()

    def train(self, resume_from_checkpoint=None):
        self.resume_checkpoint = resume_from_checkpoint
        if self.error is not None:
            raise self.error


class StreamingCompletionTests(unittest.TestCase):
    def test_streaming_exhaustion_is_treated_as_completion(self):
        trainer = FakeTrainer(ValueError(STREAMING_EXHAUSTION_MESSAGE), global_step=99)

        exhausted = train_allowing_streaming_exhaustion(
            trainer,
            resume_checkpoint="checkpoint-80",
            streaming=True,
        )

        self.assertTrue(exhausted)
        self.assertEqual("checkpoint-80", trainer.resume_checkpoint)

    def test_non_streaming_exhaustion_remains_fatal(self):
        trainer = FakeTrainer(ValueError(STREAMING_EXHAUSTION_MESSAGE))

        with self.assertRaisesRegex(ValueError, "Batch does not contain"):
            train_allowing_streaming_exhaustion(
                trainer,
                resume_checkpoint=None,
                streaming=False,
            )

    def test_unrelated_streaming_value_error_remains_fatal(self):
        trainer = FakeTrainer(ValueError("corrupt training row"))

        with self.assertRaisesRegex(ValueError, "corrupt training row"):
            train_allowing_streaming_exhaustion(
                trainer,
                resume_checkpoint=None,
                streaming=True,
            )


if __name__ == "__main__":
    unittest.main()
