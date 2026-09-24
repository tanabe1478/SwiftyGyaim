# Gyaim Decision Model

Last updated: 2026-09-19

## Contract and scope

Windows-native PyTorch training, evaluation, calibration and ONNX export. No Swift
runtime changes. Inputs are state and 1–24 candidates; outputs are candidate logits
and one NONE logit. NONE is index 24 in the fixed tensor interface, never a text token.
The JSON interface returns only the actual candidates. Masked logits are -10000;
probabilities are computed in float32 after masking and temperature scaling.

## Architecture decision

Use noncausal text encoders with learned positional and segment embeddings, masked
mean pooling, state/candidate interaction, metadata embeddings, and one set-attention
block without candidate position embeddings. Compare A (shared text encoder) and B
(independent candidate encoder). Original rank is explicit metadata, not position.
Changing candidate order together with metadata must permute candidate logits only.
NONE attends to the state and the entire valid candidate set. Padding cannot affect
pooling, set attention or loss. Plain matmul/softmax/GELU/LayerNorm operators preserve
ONNX and future Core ML conversion feasibility. No teacher/runtime LM dependency.

## Data and leakage boundary

Reuse local public zenz JSONL files and the repository connection dictionary. Reuse
RomaKana's mapping table read-only, with documented conversion differences. Mine
same-reading dictionary alternatives, then prefix and kana forms. Do not use
random words. Record whether gold existed BEFORE any gold injection. Real candidate
recall is reported separately from gold-injected training accuracy. Preserve natural
missing-gold sets and create synthetic NONE only from sets containing competitors.

Split public data by normalized context group (or reading when context is empty),
before augmentation. Do not self-mine gold outputs into the candidate index: the initial
experiment demonstrated a severe train/validation NONE-prior shift. All existing public
fixtures are regression holdout; their state/reading keys are excluded from all four
development splits. Keep competitive dictionary sets only and report that selection:
this is a conditional candidate recall estimate, not measured production recall.
Synthetic variants inherit their parent's split. Input manifests
contain source hashes and limits; full-corpus execution remains bounded in memory.
Private input is opt-in, requires timestamps and actual displayed sets, uses chronological
boundaries, and writes only below private/. Public artifact export rejects private runs.
Historical domain files are private-derived and are not read by default.

## Evaluation and selection

Select checkpoints using validation candidate MRR and NONE F1, not loss alone.
Architecture and metadata ablations are selected on validation only. Temperature uses
calibration only; report before/after NLL, Brier, ECE and reliability bins. Test and
regression holdout are final audits, not hyperparameter-selection sets. Compare stored
original rank and the existing gyaim-lm conditional mean-logprob baseline on identical
sets. LM does not have a NONE head: report its candidate-only results and mark NONE
metrics unsupported. A low-quality trained artifact is a research artifact, not an
automatically approved replacement. Record failed quality gates explicitly.

## Reproducibility and export

Reuse ../model-training/.venv; no new environment manager. Save config, data/tokenizer
hashes, git state, seed, environment, optimizer/scheduler/scaler/RNG, epoch and next
batch position. Resume validates dataset hashes. Tokenization is cached in local runs.
Export PyTorch FP32/FP16 reference and FP32/dynamic-INT8 ONNX candidates, validate logits/argmax
parity and measure accuracy/calibration changes rather than assuming quantization safe.
Bundle tokenizer.json, normalization and golden vectors, schema, manifest, calibration,
reports and model card. Benchmark CPU/GPU batch 1 at 3/8/24 candidates. Windows does
not validate Core ML runtime; macOS conversion/performance remains an integration task.

## Existing assets inspected

- ../model-training/: full public HF model, ROCm venv and 36.5GB public zenz corpus.
- docs/specs/{ai-rerank,zenz-model-tuning,dictionary-system}.md.
- docs/internal/model-contribution-investigation-2026-09-12.md: net ranking benefit,
  frequency protection, context limitations, selection bias in dogfood observations.
- Tests/GyaimTests/Fixtures/fast-context-eval-cases.jsonl: held out in full.
- Old data/domain*.jsonl and mixed runs: excluded from public experiments.

Tokenizer source: https://huggingface.co/ku-nlp/gpt2-small-japanese-char
ONNX API: https://docs.pytorch.org/docs/stable/onnx.html
