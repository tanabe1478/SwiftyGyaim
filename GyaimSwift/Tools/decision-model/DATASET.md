# Dataset, tokenizer and tensor contract

Last updated: 2026-09-19

## JSONL v1

`schema.json` defines requests. Labeled records additionally require `selected`, an
index into the actual candidate list or JSON null for NONE. Missing metadata uses
null/omission; missing values have separate numeric mask bits. Unknown source/kind
uses the explicit `unknown` enum. Candidate count is 1–24 inclusive. Empty sets are
rejected. No padding candidates appear in JSON. `originalRank` is zero-based.

```json
{"schemaVersion":1,"id":"example","context":"このモデルの","readingRoman":"kinou","readingHiragana":"きのう","candidates":[{"text":"機能","reading":"kinou","source":"connection","kind":"exact","originalRank":0,"studyFrequency":null,"contextAffinity":null,"exactReadingMatch":true},{"text":"昨日","reading":"kinou","source":"connection","kind":"exact","originalRank":1,"studyFrequency":null,"contextAffinity":null,"exactReadingMatch":true}],"selected":0}
```

Private events use the same structure and a `timestamp` such as
`2026-09-01T13:05:00+09:00`. Log adapters must preserve actual displayed candidates.
Do not manufacture a complete candidate set from historical pairwise preference
exports: those omit lower candidates and often omit rank-1 selections. `selected:null`
means the user selected/typed something absent from this recorded set, not an abandoned
composition or an unlabeled event.

## Public generation and its limits

1. Read a reproducible bounded prefix of each public zenz file and record SHA-256 of
   every scanned byte. Restrict reading length to 12 kana by default.
2. Split by normalized full context group; empty context groups by normalized reading.
   SHA-256 buckets assign train/validation/calibration/test = 85/5/5/5 percent at group
   level. Deduplicate identical context/reading/gold records.
3. Exclude **all readings** represented in the existing fast-context regression fixture
   from all development splits. Fixture rows themselves are written only to regression.
4. Load current `GyaimSwift/Resources/dict.txt`, convert using RomaKana's source mapping
   table, and collect same-reading standalone dictionary surfaces in dictionary order.
   Add bounded prefix candidates and the hiragana form, deduplicating text, capped at 24.
5. Keep sets with at least two original competitors. Do not add random negatives.
   Preserve missing gold as real NONE. For present gold, optionally remove gold only,
   retaining its competitors as synthetic NONE (default probability 0.15).
6. `candidateRecall` records whether gold existed in the original generated set.
   Synthetic NONE retains that provenance but is excluded from recall's denominator.

This first builder does **not** reproduce the connection-state graph, study/local
dictionary history, inflected compounds, MRU ordering or user context-affinity state.
It omits `*`-marked connection-only entries rather than treating their internal text as
standalone words. Kana/romaji conversion uses the checked-in table, greedy matching,
double consonants and trailing n; inverse romanization selects a canonical first entry,
so it does not reproduce a user's n/nn spelling or incomplete input. The real regression
fixtures preserve these ambiguities. Evaluation of partial-input prediction is therefore
limited; do not infer production recall from this subset.

`candidateRecallAt24` is conditional on **short-reading, competitive dictionary sets**.
`filtered` and `no_competition` counts expose discarded source records. The initial
sampling is corpus-prefix biased. A full corpus scan is possible (`--limit 0`), but
deduplication stores keys in RAM and source rows are spooled to disk. For training set
`data.cache_mode: indexed` in YAML: a memory-mapped 8-byte row-offset index allows
on-demand tokenization of each batch, without materializing training records/token
arrays in RAM. The epoch permutation still uses 8 bytes per retained example;
validation/calibration/evaluation are materialized. Account for these costs when scaling.

No corpus gold lexicon is added: initial self-mining made train NONE 11.2% versus
validation 70.9%. With dictionary-only generation these became approximately 21.2% and
19.9%. The rejected dataset remains ignored local research output and is not used for
reported model comparisons. Distribution reports include counts, source/kind, lengths,
gold rank, metadata missingness, hard negative types, homophones and NONE rate.

## Tokenizer

Reuse `tokenizer.json` from the existing public gyaim-lm artifact, derived from
ku-nlp/gpt2-small-japanese-char. No LM architecture or weights are required. The upstream
[model card](https://huggingface.co/ku-nlp/gpt2-small-japanese-char) documents a 6K byte-BPE
character vocabulary and the ASCII-space limitation. Normalize NFC, map ASCII space
to ideographic space, then encode **each Unicode scalar separately**, concatenating IDs.
This makes literal `[PAD]`/`[UNK]` strings ordinary text and prevents special-token injection.
It is a new explicit tokenizer protocol, not an assertion that arbitrary whole-string HF
encoding is identical. Preserve case, punctuation and compatibility characters.

`tokenizer-vectors.json` covers kana, kanji, rare supplementary characters, ASCII,
romaji, numbers, symbols, emoji, dictionary words, literal special tokens and combining
marks. The tokenizer script reports unknown counts and tokens per scalar. Windows
UTF-8 mode is recommended; JSON inference uses ASCII escapes for console portability.

## Tensors

| Input | Shape | dtype | Meaning |
|---|---|---|---|
| state_ids | B×112 | int64 | context suffix64 + roman prefix24 + hiragana prefix24 |
| state_segments | B×112 | int64 | 0=context, 1=roman, 2=hiragana |
| state_mask | B×112 | bool | true for actual tokens |
| candidate_ids | B×24×48 | int64 | text prefix24 + reading prefix24 |
| candidate_segments | B×24×48 | int64 | 0=text, 1=reading |
| token_mask | B×24×48 | bool | true for actual tokens |
| candidate_mask | B×24 | bool | true for actual candidates |
| categories | B×24×2 | int64 | source and kind enum indexes in common.py |
| numeric | B×24×8 | float32 | 4 normalized values then 4 presence flags |

Numeric values: min(rank,23)/23; min(log1p(frequency),10)/10; affinity in [0,1]; exact flag
0/1. Presence flags follow the same order. Unknown values are zero **with presence=0**.
An empty text collection has one neutral [PAD] position marked valid to avoid all-masked
attention. Entire invalid candidate rows remain masked in the set interaction and output.

Output `logits` is B×25 float32, actual candidate slots followed by fixed NONE slot24.
Invalid candidate logits use the reserved sentinel -10000. The probability routine
reapplies this mask before temperature scaling/softmax, so invalid probabilities are
exactly zero even at high temperature. NONE is always valid.
