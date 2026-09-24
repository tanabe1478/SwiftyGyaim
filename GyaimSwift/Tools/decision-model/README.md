# Gyaim Decision Model — Windows

Last updated: 2026-09-19

Windows-native training/evaluation/export for a discriminative candidate-set model.
The existing causal LM is a comparison baseline only. This directory does not change
the macOS application. Read [ARCHITECTURE.md](ARCHITECTURE.md) for design decisions,
[DATASET.md](DATASET.md) for data boundaries, and [EVALUATION.md](EVALUATION.md) for
metric interpretation. A successfully exported model is not automatically production-approved.

## Environment

Use the existing ROCm/CUDA venv; do not replace its PyTorch wheel with PyPI torch.
Run from this directory, in PowerShell:

```powershell
cd C:\Users\tanab\repos\SwiftyGyaim\GyaimSwift\Tools\decision-model
$env:PYTHONUTF8 = '1'
$env:PYTHONUNBUFFERED = '1'
$pythonExe = '..\model-training\.venv\Scripts\python.exe'
& $pythonExe -m pip install -r requirements.txt
& $pythonExe -c "import torch; print(torch.__version__, torch.version.hip, torch.cuda.is_available()); print(torch.cuda.get_device_name(0))"
& $pythonExe -m pytest tests -q
```

Verified locally: Python 3.12, PyTorch 2.9.1+rocm7.2.1, RX 9070 XT 16GB. CUDA/HIP
availability and a real matrix multiplication are checked before each run. GPU failure
does not silently start a slow CPU run. Explicit CPU configs require `precision: fp32`.

## Dataset and tokenizer

Source files already exist from previous public-model training. Historical `data/domain*`
and mixed training files are not used. Each output directory must be new.

```powershell
& $pythonExe tokenizer.py
& $pythonExe build_dataset.py `
  --sources ..\model-training\data-full\train_wikipedia.jsonl ..\model-training\data-full\train_llm-jp-corpus-v3.jsonl `
  --limit 500000 --version public-v2 --output data\public-v2
& $pythonExe analyze_dataset.py data\public-v2\train.jsonl --output data\public-v2\train-distribution.json
& $pythonExe analyze_dataset.py data\public-v2\validation.jsonl --output data\public-v2\validation-distribution.json
```

The checked-in recipe scans 500,000 rows **per source** and filters for competitive
short-reading dictionary sets. This is not full-corpus or production-distribution
training. `--limit 0` scans entire sources; see DATASET.md before scaling up. No network
access or upload is performed by the pipeline.

## Benchmark, train, stop, resume

```powershell
& $pythonExe train.py --config configs\small-a.yaml --run runs\benchmark-a --benchmark
& $pythonExe train.py --config configs\small-a.yaml --run runs\small-a
```

Training configuration is YAML. `model.separate_encoder` selects shared vs separate
encoders. Set `data.cache_mode: indexed` to tokenize training batches from a disk index
instead of loading all training text/tensors into RAM. The default is `memory`.
`model.metadata` is `text`, `source_kind`, `frequency`, `affinity`, or `all`.
Training uses masked listwise CE with NONE at fixed tensor index 24. Validation logs
contain loss, top1/top3/MRR, NONE metrics and calibration statistics. Best checkpoint
selection uses validation MRR + 0.25 × NONE F1.

Request a safe stop from a second PowerShell window, or press Ctrl+C once:

```powershell
New-Item runs\small-a\STOP_REQUESTED -ItemType File
```

Wait for `checkpoint step-N`. To continue, remove that request file, then pass the
printed checkpoint directory. Do not load untrusted PyTorch checkpoint files.

```powershell
Remove-Item -LiteralPath runs\small-a\STOP_REQUESTED
& $pythonExe train.py --resume runs\small-a\checkpoints\step-500
```

The checkpoint contains model, optimizer, scheduler, scaler, all RNG states, epoch,
next row offset, config, provenance and the validation-selected best weights. Data paths are absolute in saved configs.
Dataset files must remain available and pass hash checks. Checkpoint directory alone
supplies the run configuration; it does not contain a copy of the dataset. Exact
tokenizer bytes are included as a fallback if the original tokenizer path is unavailable.
Older checkpoints created before best-weight bundling also need the original `run/best.pt`.
Exact
CPU resume is tested bit-for-bit. GPU kernels can still differ across devices/drivers.
Runs include code hashes and dependency versions; preserve that source version for
reproduction. `STOP_REQUESTED` persists intentionally until explicitly removed.

## Calibration, evaluation and export

The completed September 19 comparison is documented in [RESULTS.md](RESULTS.md).
Its final local artifact is `artifacts/gyaim-decision-small-v1-optimized` (INT8 6.84 MB).
The earlier `gyaim-decision-small-v1` export is superseded for packaging only; weights
and model selection are unchanged. Quality gates fail: this is a research artifact,
not a production replacement. Shared constant aliases are resolved before INT8
quantization so both uses of each encoder weight can be quantized without retaining
an unnecessary FP32 copy.

```powershell
& $pythonExe calibrate.py --model runs\small-a\final --data data\public-v2\calibration.jsonl --device cuda
& $pythonExe evaluate.py --model runs\small-a\final --data data\public-v2\test.jsonl `
  --output runs\small-a\eval\test --device cuda `
  --lm ..\model-training\runs\zenz-v2.5-full\final
& $pythonExe evaluate.py --model runs\small-a\final --data data\public-v2\regression.jsonl `
  --output runs\small-a\eval\regression --device cuda `
  --lm ..\model-training\runs\zenz-v2.5-full\final
& $pythonExe export.py --model runs\small-a\final --output artifacts\gyaim-decision-small-v1 `
  --validation data\public-v2\validation.jsonl --evaluation runs\small-a\eval\test
& $pythonExe infer.py --model artifacts\gyaim-decision-small-v1 --input examples\request.json
```

All six required architecture/metadata comparisons, selection on validation, calibration,
test + regression baseline audits and export can be run sequentially:

```powershell
& $pythonExe experiments.py --output runs\comparison-v1 --artifact artifacts\gyaim-decision-small-v1
```

This creates `comparison.json`, `COMPARISON.md`, and `selection.json`. Runs are resumable;
rerunning skips completed stages. Use a fresh comparison directory when changing code,
data or configs. Do not repeatedly select models on the final test/regression results.

## Private personalization

Only explicitly supplied, reviewed JSONL with actual displayed candidate sets and
timezone-aware timestamps should be used. There is no automatic scan of user logs.
See DATASET.md for the schema. Output must stay below this directory's ignored `private/`.

```powershell
& $pythonExe build_dataset.py --private --sources private\reviewed-events.jsonl `
  --boundaries 2026-07-01T00:00:00+09:00 2026-08-01T00:00:00+09:00 2026-09-01T00:00:00+09:00 `
  --version personal-v1 --output private\data-v1
```

Point a copied config at that manifest and use `--run private\runs\personal-v1`.
Private export requires `--personalized` and an output below `private/`. Private
examples are never printed in logs or error reports. Public and personalized weights
must never share an artifact directory or model version.
