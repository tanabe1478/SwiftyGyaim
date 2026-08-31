#!/usr/bin/env python3
"""Train a kana-kanji conversion model in the zenz-v3 format.

Per docs/specs/zenz-model-tuning.md, the SwiftyGyaim specialized model is
trained FROM THE ORIGINAL BASE MODEL (ku-nlp/gpt2-small-japanese-char),
not by continued SFT on zenz weights. Data format matches ZenzPrompt:

    <left_context><input_katakana><output></s>

with loss computed on the output span only (prompt tokens masked to -100),
following the published zenz recipe (NLP2025 P1-19).

Input JSONL rows: {"input": <katakana>, "output": <text>,
                   "left_context": <text or null>}
(zenz-v2.5-dataset schema; build_sft_dataset.py produces the same.)

Examples:

    # 10-example overfit smoke on MPS
    .venv/bin/python3 train_zenz.py --train smoke.jsonl --output out-smoke \
        --epochs 60 --smoke

    # real run
    .venv/bin/python3 train_zenz.py --train train.jsonl --valid valid.jsonl \
        --output out-v1 --epochs 1 --batch-size 32
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import random
import signal
import sys
import threading
from pathlib import Path
from typing import BinaryIO

import torch
from torch.utils.data import Dataset, IterableDataset
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    Trainer,
    TrainerCallback,
    TrainingArguments,
)
from transformers import __version__ as transformers_version
from transformers.trainer_utils import PREFIX_CHECKPOINT_DIR, get_last_checkpoint

CONTEXT_TAG = "\uEE02"
INPUT_TAG = "\uEE00"
OUTPUT_TAG = "\uEE01"

DEFAULT_BASE = "ku-nlp/gpt2-small-japanese-char"
STREAMING_EXHAUSTION_MESSAGE = (
    "Batch does not contain any data (`None`). At the end of all iterable "
    "data available before expected stop iteration."
)


def train_allowing_streaming_exhaustion(
    trainer: Trainer,
    resume_checkpoint: str | None,
    streaming: bool,
) -> bool:
    """Run Trainer and treat verified iterable exhaustion as normal completion.

    Returns True only when Transformers reports that a streaming dataset has
    been fully consumed before max_steps. Other ValueErrors remain fatal.
    """
    try:
        trainer.train(resume_from_checkpoint=resume_checkpoint)
    except ValueError as error:
        if not streaming or STREAMING_EXHAUSTION_MESSAGE not in str(error):
            raise
        print(
            "streaming dataset exhausted after step "
            f"{trainer.state.global_step:,}; saving final model"
        )
        return True
    return False


def build_prompt(row: dict) -> str:
    prompt = ""
    context = row.get("left_context")
    if context:
        prompt += CONTEXT_TAG + context
    prompt += INPUT_TAG + row["input"] + OUTPUT_TAG
    return prompt


class ZenzSFTDataset(Dataset):
    def __init__(self, path: Path, tokenizer, max_length: int) -> None:
        self.rows = []
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    self.rows.append(json.loads(line))
        self.tokenizer = tokenizer
        self.max_length = max_length

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict:
        return encode_row(self.rows[index], self.tokenizer, self.max_length)


class StreamingZenzSFTDataset(IterableDataset):
    """Read large JSONL files without retaining every row in RAM.

    File byte offsets, the shuffle buffer, and its random-number state are all
    checkpointed. A resumed multi-day run therefore continues with the same
    next example instead of scanning from row 1 or dropping buffered examples.
    """

    def __init__(
        self,
        paths: list[Path],
        tokenizer,
        max_length: int,
        seed: int,
        shuffle_buffer: int,
        row_counts: list[int] | None = None,
    ) -> None:
        super().__init__()
        self.paths = [path.resolve() for path in paths]
        self.file_sizes = [path.stat().st_size for path in self.paths]
        self.tokenizer = tokenizer
        self.max_length = max_length
        self.shuffle_buffer_size = max(0, shuffle_buffer)
        self.row_counts = row_counts
        self.rows_read = [0] * len(self.paths)
        self.file_offsets = [0] * len(self.paths)
        self.sequential_file_index = 0
        self.buffer: list[dict] = []
        self.random = random.Random(seed)
        self._files: list[BinaryIO | None] = [None] * len(self.paths)

    def _close_files(self) -> None:
        for index, file in enumerate(self._files):
            if file is not None:
                file.close()
                self._files[index] = None

    def close(self) -> None:
        self._close_files()

    def _choose_file_index(self) -> int | None:
        if self.row_counts is None:
            if self.sequential_file_index >= len(self.paths):
                return None
            return self.sequential_file_index

        available = [
            index
            for index, count in enumerate(self.row_counts)
            if self.rows_read[index] < count
        ]
        if not available:
            return None
        # Keep every source at nearly the same completion percentage. This
        # distributes a small source throughout a large source without
        # duplicating or dropping rows.
        return min(
            available,
            key=lambda index: self.rows_read[index] / self.row_counts[index],
        )

    def _read_next_row(self) -> dict | None:
        while (file_index := self._choose_file_index()) is not None:
            if self._files[file_index] is None:
                file = open(self.paths[file_index], "rb")
                file.seek(self.file_offsets[file_index])
                self._files[file_index] = file
            file = self._files[file_index]
            assert file is not None
            line = file.readline()
            if line:
                self.file_offsets[file_index] = file.tell()
                if line.strip():
                    self.rows_read[file_index] += 1
                    return json.loads(line)
                continue
            file.close()
            self._files[file_index] = None
            if self.row_counts is not None:
                raise ValueError(
                    f"{self.paths[file_index]} ended at {self.rows_read[file_index]:,} "
                    f"rows; expected {self.row_counts[file_index]:,}"
                )
            self.sequential_file_index += 1
        return None

    def __iter__(self):
        target_buffer_size = max(1, self.shuffle_buffer_size)
        while len(self.buffer) < target_buffer_size:
            row = self._read_next_row()
            if row is None:
                break
            self.buffer.append(row)

        while self.buffer:
            index = self.random.randrange(len(self.buffer)) if self.shuffle_buffer_size else 0
            row = self.buffer[index]
            replacement = self._read_next_row()
            if replacement is None:
                self.buffer.pop(index)
            else:
                self.buffer[index] = replacement
            yield encode_row(row, self.tokenizer, self.max_length)

    def state_dict(self) -> dict:
        return {
            "version": 2,
            "paths": [str(path) for path in self.paths],
            "file_sizes": self.file_sizes,
            "row_counts": self.row_counts,
            "rows_read": list(self.rows_read),
            "file_offsets": list(self.file_offsets),
            "sequential_file_index": self.sequential_file_index,
            "buffer": copy.deepcopy(self.buffer),
            "random_state": self.random.getstate(),
            "shuffle_buffer_size": self.shuffle_buffer_size,
        }

    def load_state_dict(self, state_dict: dict) -> None:
        expected_paths = [str(path) for path in self.paths]
        if state_dict.get("version") != 2:
            raise ValueError("unsupported streaming dataset checkpoint version")
        if state_dict.get("paths") != expected_paths:
            raise ValueError("training JSONL paths differ from the checkpoint")
        if state_dict.get("file_sizes") != self.file_sizes:
            raise ValueError("training JSONL file sizes differ from the checkpoint")
        if state_dict.get("row_counts") != self.row_counts:
            raise ValueError("--train-counts differs from the checkpoint")
        if state_dict.get("shuffle_buffer_size") != self.shuffle_buffer_size:
            raise ValueError("--shuffle-buffer differs from the checkpoint")
        self._close_files()
        self.rows_read = state_dict["rows_read"]
        self.file_offsets = state_dict["file_offsets"]
        self.sequential_file_index = state_dict["sequential_file_index"]
        self.buffer = state_dict["buffer"]
        self.random.setstate(state_dict["random_state"])


def encode_row(row: dict, tokenizer, max_length: int) -> dict:
    prompt_ids = tokenizer.encode(build_prompt(row), add_special_tokens=False)
    output_ids = tokenizer.encode(row["output"], add_special_tokens=False)
    output_ids = output_ids + [tokenizer.eos_token_id]
    input_ids = (prompt_ids + output_ids)[:max_length]
    labels = ([-100] * len(prompt_ids) + list(output_ids))[:max_length]
    return {
        "input_ids": torch.tensor(input_ids),
        "labels": torch.tensor(labels),
        "attention_mask": torch.ones(len(input_ids), dtype=torch.long),
    }


DATASET_STATE_NAME = "dataset_state.pt"
RUN_MANIFEST_NAME = "run_manifest.json"


class ResumableDatasetTrainer(Trainer):
    """Extend a normal Trainer checkpoint with streaming-dataset position."""

    def _save_checkpoint(self, model, trial) -> None:
        super()._save_checkpoint(model, trial)
        dataset = self.train_dataset
        if dataset is None or not hasattr(dataset, "state_dict"):
            return
        checkpoint_dir = (
            Path(self.args.output_dir)
            / f"{PREFIX_CHECKPOINT_DIR}-{self.state.global_step}"
        )
        temporary_path = checkpoint_dir / f"{DATASET_STATE_NAME}.tmp"
        final_path = checkpoint_dir / DATASET_STATE_NAME
        torch.save(dataset.state_dict(), temporary_path)
        temporary_path.replace(final_path)


class GracefulStopCallback(TrainerCallback):
    """Convert Ctrl+C or a stop-request file into a saved training stop."""

    def __init__(self, stop_file: Path) -> None:
        self.stop_file = stop_file
        self._requested = threading.Event()
        self.stop_was_honored = False

    def request_stop(self) -> None:
        self._requested.set()

    def on_step_end(self, args, state, control, **kwargs):
        file_requested = self.stop_file.exists()
        if not self._requested.is_set() and not file_requested:
            return control
        if file_requested:
            self.stop_file.unlink(missing_ok=True)
        if not self.stop_was_honored:
            print(
                "stop requested; saving a resumable checkpoint after "
                f"step {state.global_step}"
            )
        self.stop_was_honored = True
        control.should_save = True
        control.should_training_stop = True
        return control


def streaming_run_manifest(args) -> dict:
    valid_path = args.valid.resolve() if args.valid else None
    return {
        "version": 1,
        "base_model": args.base_model,
        "train_paths": [str(path.resolve()) for path in args.train],
        "train_file_sizes": [path.stat().st_size for path in args.train],
        "train_counts": args.train_counts,
        "valid_path": str(valid_path) if valid_path else None,
        "valid_file_size": valid_path.stat().st_size if valid_path else None,
        "max_steps": args.max_steps,
        "batch_size": args.batch_size,
        "grad_accum": args.grad_accum,
        "max_length": args.max_length,
        "learning_rate": args.lr,
        "seed": args.seed,
        "shuffle_buffer": args.shuffle_buffer,
        "logging_steps": args.logging_steps,
        "save_steps": args.save_steps,
        "eval_steps": args.eval_steps,
        "fp16": args.fp16,
        "python": sys.version,
        "torch": torch.__version__,
        "transformers": transformers_version,
    }


def prepare_streaming_run_manifest(args, parser) -> None:
    if not args.streaming:
        return
    args.output.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output / RUN_MANIFEST_NAME
    current = streaming_run_manifest(args)
    if args.resume:
        if not manifest_path.is_file():
            parser.error(f"streaming run has no {RUN_MANIFEST_NAME}: {manifest_path}")
        saved = json.loads(manifest_path.read_text(encoding="utf-8"))
        if saved != current:
            differing_keys = sorted(
                key for key in set(saved) | set(current) if saved.get(key) != current.get(key)
            )
            parser.error(
                "resume arguments or input files differ from run manifest: "
                + ", ".join(differing_keys)
            )
        return
    if manifest_path.exists() or get_last_checkpoint(str(args.output)) is not None:
        parser.error(
            f"streaming output already contains a run: {args.output}; use --resume or a new output"
        )
    manifest_path.write_text(
        json.dumps(current, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def collate(batch, pad_token_id: int):
    length = max(len(item["input_ids"]) for item in batch)

    def pad(tensor, value):
        return torch.cat([tensor, torch.full((length - len(tensor),), value, dtype=tensor.dtype)])

    return {
        "input_ids": torch.stack([pad(b["input_ids"], pad_token_id) for b in batch]),
        "labels": torch.stack([pad(b["labels"], -100) for b in batch]),
        "attention_mask": torch.stack([pad(b["attention_mask"], 0) for b in batch]),
    }


def pick_device() -> str:
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def greedy_decode(model, tokenizer, prompt: str, device: str, max_new_tokens: int = 64) -> str:
    ids = tokenizer.encode(prompt, add_special_tokens=False, return_tensors="pt").to(device)
    with torch.no_grad():
        out = model.generate(
            ids,
            max_new_tokens=max_new_tokens,
            do_sample=False,
            eos_token_id=tokenizer.eos_token_id,
            pad_token_id=tokenizer.eos_token_id,
        )
    return tokenizer.decode(out[0][ids.shape[1]:], skip_special_tokens=True)


def add_legacy_gpt2_context_alias(model_dir: Path) -> None:
    """Keep the saved GPT-2 config compatible with the bundled GGUF converter.

    Transformers 5 serializes the context length as ``n_positions``.  The
    azooKey llama.cpp fork's GPT-2 converter still reads the historical
    ``n_ctx`` key.  They describe the same value, so retaining both avoids a
    manual edit between training and GGUF conversion.
    """
    config_path = model_dir / "config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    if "n_ctx" not in config and "n_positions" in config:
        config["n_ctx"] = config["n_positions"]
        config_path.write_text(
            json.dumps(config, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-model", default=DEFAULT_BASE)
    parser.add_argument(
        "--train",
        required=True,
        type=Path,
        nargs="+",
        help="One JSONL file, or multiple files when --streaming is used.",
    )
    parser.add_argument("--valid", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--epochs", type=float, default=1.0)
    parser.add_argument("--lr", type=float, default=5e-5)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--grad-accum", type=int, default=1)
    parser.add_argument("--max-length", type=int, default=256)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--logging-steps", type=int, default=50)
    parser.add_argument("--save-steps", type=int, default=2000)
    parser.add_argument(
        "--eval-steps",
        type=int,
        default=0,
        help="Evaluate validation data every N steps. 0 means once per epoch.",
    )
    parser.add_argument(
        "--streaming",
        action="store_true",
        help="Stream very large JSONL files instead of loading them into RAM.",
    )
    parser.add_argument(
        "--train-counts",
        type=int,
        nargs="+",
        help=(
            "Row count for each --train file. When supplied, sources are "
            "interleaved in proportion to their sizes."
        ),
    )
    parser.add_argument(
        "--max-steps",
        type=int,
        default=-1,
        help="Number of optimizer steps. Required with --streaming.",
    )
    parser.add_argument(
        "--shuffle-buffer",
        type=int,
        default=10_000,
        help="Streaming shuffle buffer. 0 disables shuffling.",
    )
    parser.add_argument("--fp16", action="store_true",
                        help="Use mixed-precision FP16 training on a compatible GPU.")
    parser.add_argument("--resume", action="store_true",
                        help="output配下の最新checkpointから学習を再開する")
    parser.add_argument("--smoke", action="store_true",
                        help="After training, greedy-decode every train row and report exact match.")
    args = parser.parse_args()

    if args.streaming and args.max_steps <= 0:
        parser.error("--streaming requires a positive --max-steps")
    if not args.streaming and len(args.train) != 1:
        parser.error("multiple --train files require --streaming")
    if args.train_counts is not None:
        if not args.streaming:
            parser.error("--train-counts requires --streaming")
        if len(args.train_counts) != len(args.train):
            parser.error("--train-counts must have one value per --train file")
        if any(count <= 0 for count in args.train_counts):
            parser.error("--train-counts values must be positive")
    if args.smoke and args.streaming:
        parser.error("--smoke is only supported for an in-memory dataset")
    if args.logging_steps <= 0 or args.save_steps <= 0 or args.eval_steps < 0:
        parser.error("logging/save steps must be positive and eval steps non-negative")
    missing_paths = [path for path in args.train if not path.is_file()]
    if args.valid and not args.valid.is_file():
        missing_paths.append(args.valid)
    if missing_paths:
        parser.error("input file not found: " + ", ".join(map(str, missing_paths)))
    prepare_streaming_run_manifest(args, parser)

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    device = pick_device()
    print(f"device={device} base={args.base_model} fp16={args.fp16}")

    tokenizer = AutoTokenizer.from_pretrained(args.base_model)
    model = AutoModelForCausalLM.from_pretrained(args.base_model).to(device)

    if args.streaming:
        train_ds = StreamingZenzSFTDataset(
            args.train,
            tokenizer,
            args.max_length,
            args.seed,
            args.shuffle_buffer,
            args.train_counts,
        )
    else:
        train_ds = ZenzSFTDataset(args.train[0], tokenizer, args.max_length)
    valid_ds = ZenzSFTDataset(args.valid, tokenizer, args.max_length) if args.valid else None
    train_description = "streaming" if args.streaming else str(len(train_ds))
    print(f"train={train_description} valid={len(valid_ds) if valid_ds else 0}")

    resume_checkpoint = None
    if args.resume:
        resume_checkpoint = get_last_checkpoint(str(args.output))
        if resume_checkpoint is None:
            parser.error(f"no checkpoint-* directory found under {args.output}")
        if args.streaming:
            dataset_state_path = Path(resume_checkpoint) / DATASET_STATE_NAME
            if not dataset_state_path.is_file():
                parser.error(
                    f"streaming checkpoint has no {DATASET_STATE_NAME}: "
                    f"{dataset_state_path}"
                )
            # Checkpoints under --output are local files created by this script.
            dataset_state = torch.load(dataset_state_path, weights_only=False)
            train_ds.load_state_dict(dataset_state)
            print(f"restored streaming data position from {dataset_state_path}")

    training_args = TrainingArguments(
        output_dir=str(args.output),
        num_train_epochs=args.epochs,
        max_steps=args.max_steps,
        learning_rate=args.lr,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.grad_accum,
        logging_steps=args.logging_steps,
        save_steps=args.save_steps,
        save_total_limit=2,
        eval_strategy=(
            "steps" if valid_ds and args.eval_steps else "epoch" if valid_ds else "no"
        ),
        eval_steps=args.eval_steps if args.eval_steps else None,
        report_to=[],
        seed=args.seed,
        fp16=args.fp16,
        use_cpu=(device == "cpu"),
        ignore_data_skip=args.streaming,
        dataloader_num_workers=0,
    )
    stop_callback = GracefulStopCallback(args.output / "STOP_REQUESTED")
    trainer = ResumableDatasetTrainer(
        model=model,
        args=training_args,
        train_dataset=train_ds,
        eval_dataset=valid_ds,
        data_collator=lambda batch: collate(batch, tokenizer.eos_token_id),
        callbacks=[stop_callback],
    )

    previous_handlers = {}

    def handle_stop_signal(signum, frame) -> None:
        print(
            f"received signal {signum}; a checkpoint will be saved after "
            "the current step"
        )
        stop_callback.request_stop()

    for signal_name in ("SIGINT", "SIGTERM"):
        stop_signal = getattr(signal, signal_name, None)
        if stop_signal is not None:
            previous_handlers[stop_signal] = signal.signal(stop_signal, handle_stop_signal)
    try:
        train_allowing_streaming_exhaustion(
            trainer,
            resume_checkpoint=resume_checkpoint,
            streaming=args.streaming,
        )
    finally:
        for stop_signal, previous_handler in previous_handlers.items():
            signal.signal(stop_signal, previous_handler)
        if args.streaming:
            train_ds.close()

    if stop_callback.stop_was_honored:
        latest_checkpoint = get_last_checkpoint(str(args.output))
        print(f"graceful stop complete; resume checkpoint={latest_checkpoint}")
        return 0

    final_dir = args.output / "final"
    trainer.save_model(str(final_dir))
    tokenizer.save_pretrained(str(final_dir))
    add_legacy_gpt2_context_alias(final_dir)

    if valid_ds:
        metrics = trainer.evaluate()
        print(f"valid loss={metrics['eval_loss']:.4f} ppl={math.exp(metrics['eval_loss']):.2f}")

    if args.smoke:
        model.eval()
        hits = 0
        for row in train_ds.rows:
            decoded = greedy_decode(model, tokenizer, build_prompt(row), device)
            ok = decoded == row["output"]
            hits += ok
            mark = "OK " if ok else "NG "
            print(f"{mark} input={row['input']} expected={row['output']} got={decoded}")
        print(f"smoke exact match: {hits}/{len(train_ds.rows)}")
        return 0 if hits == len(train_ds.rows) else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
