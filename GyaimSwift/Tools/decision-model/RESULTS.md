# Gyaim Decision Model 実験結果

Last updated: 2026-09-19

モデル: `gyaim-decision-shared-all-v1` / 3,110,642 parameters。
成果物の判定: **research-not-approved**。Swift本体のモデル置換は行っていない。

## 評価

候補Top-1/MRRは正解が候補内にある例のみ。NONEを含む全例の正解率とは分けて示す。
モデル選定はvalidationのみで完了し、その後にtest/regressionを評価した。

| 評価集合 | 件数 | Decision Top-1 | heuristic Top-1 | gyaim-lm Top-1 | Decision MRR | 改善 | 悪化 | net benefit |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| public test | 1478 | 91.69% | 34.93% | 97.31% | 0.9520 | 727 | 46 | +681 |
| regression holdout | 124 | 38.71% | 93.55% | 66.94% | 0.6660 | 2 | 70 | -68 |

Public test: NONE F1=0.7774、全例decision accuracy=86.67%、ECE=0.0189。
候補Recall@24=91.26%。これは短い読み・競合辞書候補がある集合に条件付けたRecallであり、本番全入力のRecallではない。

既存gyaim-lmは公開zenz全体で学習済み。public testはDecisionモデルにとってのholdoutであり、LMにとって未学習とは保証できない。
HF条件付き平均logprobを同一候補集合で比較しており、本番GGUF＋保護規則全体の再現ではない。

## 校正・量子化

Temperature=1.425576。独立calibration splitのNLL 0.3933 → 0.3687、ECE 0.0416 → 0.0236。
INT8 validation Top-1差=+0.000 percentage points、ECE差=+0.00064、argmax一致率=99.93%。
INT8はlinear重みのdynamic quantizationであり、embedding/attentionはFP32のまま。

| ファイル | 実サイズ MB |
|---|---:|
| model.pt | 12.463 |
| model-fp16.pt | 6.242 |
| model.onnx | 12.537 |
| model-int8.onnx | 6.841 |

各サイズは単一modelファイル。参照コード・複数精度・reportを含む配布directory全体のサイズではない。

## Latency

Windows上、batch=1、warmup後、CPU threads=4。model loadは除外。macOS実測ではない。

| backend | candidates | p50 ms | p95 ms | mean ms |
|---|---:|---:|---:|---:|
| pytorch-cpu | 3 | 179.949 | 220.388 | 184.751 |
| onnx-cpu | 3 | 9.137 | 9.377 | 8.826 |
| tokenizer-cpu | 3 | 0.059 | 0.060 | 0.059 |
| pytorch-cpu | 8 | 179.748 | 210.052 | 183.690 |
| onnx-cpu | 8 | 9.261 | 9.397 | 8.427 |
| tokenizer-cpu | 8 | 0.113 | 0.117 | 0.113 |
| pytorch-cpu | 24 | 175.943 | 198.052 | 178.200 |
| onnx-cpu | 24 | 9.197 | 9.331 | 9.139 |
| tokenizer-cpu | 24 | 0.290 | 0.296 | 0.291 |
| pytorch-gpu-fp32 | 3 | 3.694 | 4.037 | 3.729 |
| pytorch-gpu-fp32 | 8 | 3.565 | 3.643 | 3.567 |
| pytorch-gpu-fp32 | 24 | 3.646 | 3.721 | 3.650 |

## 品質判定

| gate | result |
|---|---|
| positiveNetBenefit | PASS |
| competitiveWithLM | FAIL |
| homophoneNonRegression | FAIL |
| parameterTarget | PASS |
| fp16SizeTarget | PASS |
| int8SizeTarget | PASS |
| regressionNetBenefit | FAIL |
| regressionHomophoneNonRegression | FAIL |

## 回帰fixtureの内訳

同じケースが複数tagに属するため、件数は単純加算できない。

| tag | 件数 | Decision Top-1 | gyaim-lm Top-1 | net benefit |
|---|---:|---:|---:|---:|
| adjective-conjugation | 11 | 0.00% | 81.82% | -11 |
| affinity-poisoning | 2 | 0.00% | 50.00% | +0 |
| compound | 24 | 0.00% | 79.17% | -24 |
| connection-internal-label | 11 | 0.00% | 90.91% | -11 |
| context-affinity | 2 | 100.00% | 100.00% | +0 |
| dogfood-regression | 10 | 30.00% | 60.00% | -5 |
| exact-protection | 81 | 53.09% | 76.54% | -38 |
| fast-context | 124 | 38.71% | 66.94% | -68 |
| homophone | 8 | 50.00% | 87.50% | +2 |
| known-issue | 2 | 0.00% | 50.00% | +0 |
| latency-sensitive | 8 | 50.00% | 62.50% | -4 |
| model-required | 6 | 33.33% | 66.67% | +2 |
| negative-imperative | 15 | 0.00% | 0.00% | -15 |
| polite-negative | 2 | 0.00% | 100.00% | -2 |
| preference | 2 | 0.00% | 0.00% | +0 |
| prefix-promotion | 17 | 0.00% | 11.76% | -17 |
| proper-noun | 8 | 50.00% | 75.00% | -4 |
| short-input | 9 | 55.56% | 66.67% | -4 |
| user-dict | 10 | 70.00% | 50.00% | -3 |
| verb-conjugation | 27 | 14.81% | 33.33% | -23 |

## 残る制約

- 公開データは各source先頭50万件から抽出。接続辞書graph全体、学習辞書、入力途中の分布は再現していない。
- 公開学習には実際のstudyFrequency/contextAffinityがない。個人選好の有効性は未立証。
- private temporal split・private artifact分離は実装／テスト済みだが、今回privateデータは使っていない。
- 本番採用は未承認。品質gateが失敗したモデルをSwiftへ置き換えない。
- Core MLの変換・実行とmacOS速度は別途検証が必要。

詳細な再実行手順はREADME.md、比較実験全表は成果物のCOMPARISON.mdを参照する。
