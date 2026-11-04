# Issue #125: 本番順位の退行分析と次の学習設計

Last updated: 2026-11-04

## 今回の範囲

ユーザーの許可範囲は分析器と設計まで。追加学習、重み変更、モデル適用、
本番ランキング規則の変更は行わない。実データのケース別traceはまだ取得していない。
以下の取得コマンドはMac側で次に実施する手順であり、実施済みの記録ではない。

## native比較で判明したこと

[Mac側の報告](https://github.com/tanabe1478/SwiftyGyaim/issues/125#issuecomment-6629234575)では、
baseとVを同じハーネス・ケース・辞書・既定重みで比較した。Release、全件11,066、gap30は4,121。
Mac17,2 / Apple M5 / 32GB / macOS26.7.2 / Xcode27.2 / commit234e553d。

| 文脈 | 全件モデル単体の差 | 全件本番式の差 | gap30本番式の差 |
|---|---:|---:|---:|
| 0 | +576 | +9 | +3 |
| 5 | +40 | +1 | +1 |
| 10 | +43 | +5 | +3 |
| 20 | +43 | -11 | -1 |

全件p50/p95はbase11.28/15.98ms、V11.26/15.65ms。速度ゲートは満たす。
20文字の本番式が退行しているためVの採用は見送り。集計値だけでは、壊した件・直した件の数、
かな対漢字か同音異義語か、どの加減点との差をモデルが越えたのかは分からない。
この不足を埋めるのが今回の分析器であり、新しいモデルの改善を既に確認したものではない。

## ケース別traceの取得

PR #128の更新を含む同じcloneで両モデルを評価する。元ZIPのモデルはそのまま使用する。
最初は20文字だけでよい。全件traceからgap30も集計できるので、gap30だけの再採点は不要。

```bash
cd /path/to/SwiftyGyaim/GyaimSwift
mkdir -p Tools/model-training/runs/issue-125/native-v-diagnostic-v1
OUT="$PWD/Tools/model-training/runs/issue-125/native-v-diagnostic-v1"
PACKAGE=/path/to/extracted-mac-eval-package
export CONFIGURATION=Release
export GYAIM_CONTEXT_EVAL_LENGTHS=20 GYAIM_CONTEXT_EVAL_SUBSET=all
export GYAIM_CONTEXT_EVAL_CASES="$HOME/.gyaim/eval/context-cases-2026-10.jsonl"
unset GYAIM_CONTEXT_EVAL_LIMIT

GYAIM_CONTEXT_EVAL_MODEL="$PACKAGE/public-v1-Q5_K_M.gguf" \
GYAIM_CONTEXT_EVAL_TRACE="$OUT/base.trace.jsonl" \
bash Tools/eval/run-context-cases-eval.sh "$OUT/base.report.json"

GYAIM_CONTEXT_EVAL_MODEL="$PACKAGE/candidate-v-Q5_K_M.gguf" \
GYAIM_CONTEXT_EVAL_TRACE="$OUT/v.trace.jsonl" \
bash Tools/eval/run-context-cases-eval.sh "$OUT/v.report.json"

cd Tools/model-training
python3 analyze_native_context.py \
  --cases "$GYAIM_CONTEXT_EVAL_CASES" \
  --baseline-trace "$OUT/base.trace.jsonl" --trial-trace "$OUT/v.trace.jsonl" \
  --output runs/issue-125/native-v-analysis-v1
```

Python3.11以上が必要。Windowsでは学習用Python3.12でも解析できる。
元ケース・GGUFのhashは既存ZIPのSHA256SUMS/provenanceと照合する。
実行前後のcommitと`git diff`も記録し、両モデル間でソース・辞書・設定を変えない。
ハッシュが同じでも、元データとは異なるモデル名だけで同一モデルとは判断しない。
既存traceは上書きしない。失敗途中の`.partial`は残り、解析器は受け付けない。
再試行では新しい出力ディレクトリを使用する。

`GYAIM_CONTEXT_EVAL_TRACE`省略時は従来の集計評価のまま。
指定すると、同じscoreBatchの結果を使い、計測区間の後にtraceを書き出す。
モデルの追加呼び出しはしないが、I/Oや追加集計があるため診断時の速度を正式な性能測定へ流用しない。
速度の再確認はtraceなしで実施する。

## traceと解析の検証

trace形式は`gyaim-native-context-trace` version1。旧HF用caseHash exportとは別形式。

- header: 元ケースとGGUFのSHA256、辞書・関連Swift source・Llama package定義のSHA256、
  OS、重み、構成、文脈長、subset、limitを記録。
- case: 元JSONLの物理行番号（1始まり）、その行のLFを除く元UTF-8 bytesのSHA256、
  prompt hash、truth index、モデル/本番/heuristicの全順位、モデル/本番点数、
  学習頻度・文脈学習・生ひらがな・複合語・4安全規則の加減点を記録。
  CRLFの場合、行hashにはCRを含める。入力文・候補文字列はtraceへ出さない。
- summary: 従来の集計report。最後まで完了した後だけ`.partial`から正式名へ移す。

本番点数と順位は`llmPrimaryOrder`の実結果。加減点の分解は、実際の本番点数と
再合成した点数が一致することをSwift側・Python側の両方で確認する。
Pythonはさらに元ケースのhash、同一辞書・source・OS・重み・文脈長、全対象のcoverage、
候補数、完全順列、null/有限値、モデルの元順tie、本番のheuristic tie、集計値との一致を検証する。
Release・既定重みの完全評価だけを対象にし、limit付き、欠落、重複、前提条件の異なる比較を拒否する。

## 読む出力

`summary.json`には全件/gap30ごとのモデル単体と本番式の良化・悪化・正解数差、
本番順位が変わった例のカテゴリと相互作用を出す。

- `kana-vs-kanji`: かなのみの表記と漢字を含む表記の対比。
- `same-reading-dictionary`: exact/compound辞書候補で読みが入力と等価。同品詞・同義の保証ではない。
- `other`: 上記以外。prefix、記号、読み不明などは人手確認の対象。
- `base-rescued-by-production`: 元モデル単体は外したが、本番式では正解していた例。
- `heuristic-correct`: heuristicも正解だった例。

`changes.jsonl`は本番式の正誤が変わった例だけを含む。truthと競合候補のindex、
base/Vのモデルmargin・本番margin、加減点差、必要なモデルmargin、同点時の勝者を記録する。
同じ2候補で `本番margin = モデルmargin + 加減点差` として読める。
加減点差が0でないことは誤りの原因を証明せず、変更すべき規則を自動選定するものでもない。
未採点がある場合はmarginをnullに保ち、0点として埋めない。

必要なら新しい出力先に`--include-text`を付けて再解析すると、入力・元文脈・truth・競合表記を
ローカルの確認用出力へ追加できる。元文脈は短縮前で、Swiftでの実入力はprompt hashで対応を確認する。
どちらの出力も`Tools/model-training/runs/`配下に限定し、個人データとして管理する。
公開Issueへは集計値だけを記載する。学習用JSONLは生成しない。

## 次の学習設計（実行は別途再開時）

まず20文字の本番式の「悪化」と「良化」を両方読み、全件とgap30を分ける。
次の分岐は仮説であり、まだ退行原因を特定したという意味ではない。

| 分析結果 | 次に比較する学習上の変更 | 検証する点 |
|---|---|---|
| 元の本番式が救っていた例で、Vのモデルmarginが加点差を越えて逆転 | 学習側で文脈ありmarginの保持損失を追加し、その重み1項だけ比較 | 本番の既正解を守りつつ、元の本番誤りを直せるか |
| かな／漢字の退行が集中 | 同読みのかな・漢字の公開対比を学習側だけで均衡化 | 表記priorだけの変化で文脈判別を壊していないか |
| 同読み辞書候補の退行が集中 | 判断材料のある公開文脈・候補ペアをレビューして補う | 短縮文脈で曖昧な正解を強制していないか |
| traceの採点不能・辞書/source/設定の不一致がある | 比較条件を修正し、学習変更は見送る | 対象・母数・tie処理が同じか |

本番式を考慮した候補学習を行う場合は、**学習splitの候補集合とmetadataだけ**から
既定の本番順位を再現し、元の本番式で外している例を重点化する。
候補間の学習logitにはモデルmarginだけでなく、その2候補の本番加減点差を固定offsetとして含める案を比較する。
ただし学習頻度・文脈学習・複合語判定が取得できない公開例を、実ログと同じ本番式の例とは呼ばない。
既存9月ペアと公開例の利用可能metadataを学習側で監査してから適用範囲を決める。
順位のtieや安全規則そのものは微分できないので、最終選定はnative本番式で行う。

固定10月ケースは原因分析専用。失敗例、ラベル、個人頻度を学習へコピーせず、
固定評価から作った類似文を訓練データとすることもしない。
validationは学習側の読み単位splitで固定し、過去の固定評価を独立テストとして扱わない。
一度に変えるのは一つの学習要因。モデル単体は補助指標、本番式20文字の改善を主指標とし、
5/10文字の退行・全件/gap30・速度・既存公開評価も併記する。微小な差だけで体感改善を断定しない。

## 検証範囲

Pythonの合成テストで、モデル単体の改善と本番退行の分離、加点margin、gap>30秒、
LF/CRLF、欠落・条件差・集計不一致・tie-break・途中ファイルの拒否を確認する。
既存固定ケースを採点せずに解析対象だけ照合し、全件11,066・gap30 4,121・skipped1,706が
Mac報告と一致することも確認済み。元のケース内容は変更していない。
Macのユニットテストは実際の`llmPrimaryOrder`から合成traceを出し、同じbytesをPython解析器へ渡す。
このテストは形式と計算の検証であり、実データの退行内訳を測ったものではない。
