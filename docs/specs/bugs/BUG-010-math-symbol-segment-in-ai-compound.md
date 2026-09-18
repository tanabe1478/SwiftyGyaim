# BUG-010: AI複合候補に数学記号segmentが混入する

- **発見日**: 2026-05-22
- **症状**: Tab AI候補生成で `nandoka` に対して `ん∩か` / `る∩か` のような不自然な候補が生成される
- **影響**: Zenz rerank では下位に落ちるが、候補リストにノイズが混じり、Zenz scoring 対象も浪費する
- **原因**: CandidateGenerator が完全一致segment候補を文字種検証なしで連結していた。接続辞書に `ando -> ∩` のような記号エントリがあると、日本語文として不適切なcompound候補に混入した
- **修正**:
  - 複合候補segmentに文字種フィルタを追加し、かな・カナ・漢字・全角英数・々/〆/〇のみ許可
  - Zenz scoring の既定対象を上位8件に減らし、raw input を scoring 対象から除外してTab latencyを削減
- **検証**: `testCompoundGenerationRejectsSymbolSegments` を追加
- **教訓**: rerankerで下げられるノイズでも、生成段階で排除できるものは排除する。特に辞書由来の記号・数式文字は日本語IME候補として別扱いにする。
