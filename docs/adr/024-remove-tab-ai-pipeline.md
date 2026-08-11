# ADR-024: Tab AI候補生成パイプラインの削除とGoogle変換への置き換え

## Status

Accepted

## Decision

変換中に Tab を押したときのローカルAI候補生成パイプライン（CandidateGenerator による lattice/補完候補生成 + Zenz制約付き生成〔ADR-022〕 + Zenz alternative review + rerank）を削除し、Tab は Google Transliterate の起動（既存の suffix / 設定ショートカットと同じ経路）に置き換える。

**通常入力中の fast-context 並べ替え（ADR-016/017/020/021）は変更しない。**

## Context

ユーザーのdogfoodで「Tabの候補が悪すぎる。Google APIを呼んでいた頃の方がましだった」との評価。実ログで確認したところ、`syutuji`（出自）に対する Tab 候補が「種辻」「手辻」「酒辻」「朱辻」「首辻」等だった。

原因は構造的で、ローカル生成は接続辞書にある部品の組み合わせしか作れないため、辞書にない語（出自など）は正解を出せず、部品合成のゴミだけが並ぶ。Google Input Tools はサーバー側の大規模語彙で未知語を一発で返すため、未知語変換という Tab の主用途では常に優位。

一方、fast-context 並べ替え（生成をしない軽量順位補正）は実測で確定候補の平均表示順位1.07（29回中28回が1位）と機能しており、削除対象から明確に分離した。

## Consideration

1. **`aiRerankUseGoogle=true` でGoogle候補を後追い追加** — ローカル候補が先に出て数百ms後にGoogle候補で書き換わる2段更新。チラつく上、ゴミのローカル候補を出す構造は残る
2. **Tabをキーバインド設定でGoogle変換ショートカットに割当** — コード変更ゼロだが、壊れたパイプラインのコードと設定UIが残り続ける
3. **パイプライン削除 + Tab=Google変換をコードのデフォルトに（採用）** — ユーザーの要望どおり。壊れた機能を温存しない
4. AI系全部削除 — fast-contextは実績があり削除理由がない。不採用

## Consequences

- Tab の候補品質が未知語で大幅に改善（Google語彙）。ネットワーク必須になるが、失敗時は従来候補が残るだけで劣化しない（GoogleTransliterate既存のstale guard/タイムアウト3秒）
- GyaimController から約330行削除。`HandleResult.HandleAction.aiRerank` 廃止、Tab は `.googleTransliterate` を返す
- CandidateGenerator.swift / CandidateGeneratorTests / CandidatePipelineFeedbackTests を削除（テスト395→383）
- ADR-022（辞書制約付き生成）は本ADRでsupersede。`WordSearch.constrainedCompositions` や `InProcessAIReranker` の生成系メソッドはコードとしては残るが呼び出し元がない（辞書層・モデル層は今回のスコープ外のため未削除）
- **未整理の残骸（フォローアップ対象）**: 設定画面の「Zenz生成」トグル、`aiRerankUseGoogle` / `aiRerankUseLegacyExternalReranker` / `aiRerankZenz*` 設定キー、HTTPAIReranker / ExternalCommandAIReranker（legacy比較用）は無効化されたまま残る

## References

- Issue #85 とは独立。dogfoodフィードバック起点（2026-08-11）
- ADR-011（Google Transliterate統合）、ADR-022（superseded）
- 実ログ証拠: 2026-08-11 12:49 `syutuji` の Zenz candidate score ログ
