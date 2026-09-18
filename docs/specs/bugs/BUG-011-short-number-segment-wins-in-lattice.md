# BUG-011: 長文lattice候補で短い数値segmentと低順位同音語が上位化する

- **発見日**: 2026-05-23
- **症状**: ログ由来ケース `jikaikidougo` で、期待候補 `次回起動後` より `次回起動５` / `次回木戸動` / `次回軌道後` などが上位に出る
- **影響**: Tab AI候補生成が、実際にユーザーが選んだ複合語を上位に戻せない
- **原因**:
  - lattice の segment 候補上限が狭く、`kidou -> 起動` のような辞書内で少し下位の候補が探索から落ちやすかった
  - `go -> ５` / `五` のような短い数値候補が長文lattice内で文脈なしに高スコア化していた
  - 一般的な複合語（例: `起動後`）への局所的な補正がなかった
- **修正**:
  - segment候補上限を5に拡張
  - 短い読みの数値segmentをlattice生成から除外
  - `起動 + 後` などログで観測された一般的な複合語に bonus を追加
  - ログ由来 watchlist を `CandidatePipelineFeedbackTests` に追加
- **検証**: `testFeedbackWatchlistCasesHaveExpectedCandidateNearTop` で `jikaikidougo -> 次回起動後` が上位5件に入ることを確認
- **教訓**: 実ログの accepted rank が悪いケースは候補生成の探索幅不足・短segmentノイズ・局所複合語不足のいずれかに分解し、テスト化してから生成側を直す。
