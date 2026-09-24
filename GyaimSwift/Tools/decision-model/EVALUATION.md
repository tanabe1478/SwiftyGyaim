# Evaluation, calibration and export

Last updated: 2026-09-19

## What the metrics mean

Ranking top1/top3/MRR/meanGoldRank use present-gold examples and rank only actual
candidates. NONE abstention is assessed separately with decisionAccuracy and NONE
precision/recall/F1. Never interpret candidate-only top1 as overall decision accuracy.
Relative improvement compares candidate rank with the existing heuristic Python port
on the exact same set. `netBenefit = improved - worsened`; meanRankDelta is positive
when improved. Stored original rank is used only where no explicit heuristic baseline
has been requested (training validation/checkpoint selection and quantization analysis).

Homophone subset requires at least two `exact`/`compound` candidates with exact-reading
flags. Preference subset requires frequency or affinity metadata. Public training has
neither actual study frequencies nor user affinity; an empty preference subset is
reported as count 0, not invented accuracy. Regression fixtures cover the repository's
known context/frequency, kana, punctuation, symbols, incomplete stem and n/nn cases.
They are held out from training by reading, a stricter exclusion than row deduplication.

The gyaim-lm baseline loads the existing local HF artifact with `HFScorer` from
`compare-hf-gguf.py`, using conditional mean log probability of every candidate.
Context is truncated to 20 characters and the Japanese reading uses Zenz prompt tags.
This is HF scoring, not the deployed GGUF plus runtime guards. NONE metrics are
explicitly unsupported for that baseline; it never predicts NONE. No LM score enters
the production classifier.

The existing LM was already trained on the public zenz sources. A newly held-out
decision-model test split is therefore not certified unseen data for the LM baseline.
Treat these as comparisons against the actual incumbent, not a controlled comparison
of two models trained on identical splits. Regression fixtures are a separate audit.

## Calibration and confidence

Temperature scaling fits log-temperature in [-3,3] to minimize calibration NLL only.
The calibration file's manifest/hash must match the training provenance. Store scalar
temperature separately from weights, with model hash. Reports contain NLL, multiclass
Brier score, top-label ECE and count/accuracy/mean-confidence bins both before and after.
An empty bin has null means, not 0% accuracy. Threshold coverage counts confident
non-NONE decisions over all examples. `wrongDecisionRate` uses all examples as denominator.

Error reports contain example IDs, indices and categories only, never raw context or
candidate text. They include high-confidence mistakes, rank regressions, NONE false
positives/negatives and homophone/preference failures. Resolve IDs against the original
local dataset when inspecting examples. Keep all private output under ignored private/.

## Selection and quality gates

Six experiments compare shared vs independent text encoders, and text-only,
source/kind, frequency, affinity, all-metadata variants. Each uses the same four splits,
seed and training schedule. Checkpoint and architecture selection use validation
MRR + 0.25 NONE F1; parameter count breaks architecture ties. Calibration uses only
calibration data. The final selected model is audited on test and regression once.

Final manifests report positive heuristic net benefit, competitiveness with LM,
homophone non-regression (2 percentage point tolerance), parameter and size targets.
These are offline research gates, not proof of production safety. The current pipeline
labels artifacts `research-not-approved` because synthetic subset results alone do not
establish actual user benefit or Mac runtime behavior. There is no hidden promotion or
change to the bundled SwiftyGyaim model.

## Export and latency

- `model.pt`: PyTorch FP32 state dictionary; architecture lives in model.py.
- `model.onnx`: opset17 FP32, fixed 24 slots/sequence limits, dynamic batch.
- `model-fp16.pt`: FP16 weight storage, evaluated with FP16 GPU inference when available.
- `model-int8.onnx`: dynamic INT8 constant linear weights; embeddings and attention remain
  FP32. Actual bytes, accuracy/ECE delta and latency are measured on validation.
- `manifest.json`, `config.yaml`, `tokenizer*.json`, `schema.json`, `calibration.json`,
  `evaluation.json`, `export-parity.json`, `benchmark.json`, `quantization.json`, model card.

FP32 parity is mandatory at 1/3/8/24 actual candidates and batches1/2, atol=rtol=2e-4
with identical argmax. The explicit legacy exporter avoids default-version ambiguity
on the installed Windows ROCm stack; do not remove parity checks when migrating to
the newer exporter. PyTorch documents the current APIs at
https://docs.pytorch.org/docs/stable/onnx.html .

Benchmarks warm up first and report p50/p95/mean for CPU PyTorch, CPU ONNX, GPU PyTorch
and tokenizer separately, batch1 at 3/8/24 actual candidates. Fixed padding means
candidate-count latency can be similar. CPU threads=4. The numbers exclude model load
and are not end-to-end macOS IME latency. Core ML conversion/runtime validation requires
a subsequent macOS task; the architecture uses elementary exportable operators.
