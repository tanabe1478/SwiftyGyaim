# BUG-029: Zenzスコア加算が採点済み候補を一律減点し、未採点ゴミが上位化

- **発見日**: 2026-07-16
- **症状**: `seisansei` のTabで「性三世」「製参政」等のゴミ合成が「生産性」より上に並ぶ（生産性はindex 6、通常入力ではindex 1）。
- **影響**: Tab rerank全般。採点予算（上位8 index）の外に座るcompound/lattice合成が、採点された正しい語より構造的に有利だった。
- **原因**: Zenzスコア＝平均log probability は**常に負**。`combined = heuristic + zenz × 0.3` を採点対象だけに適用していたため、採点された候補は必ず減点され、未採点候補（index 8以降）は無傷。「生産性」(heuristic 0.54) が −0.27 されて「性三世」(0.36, 未採点) に負けた。
- **修正**: Zenz寄与を採点集合の平均との差分に変更（mean-centering）: `combined = heuristic + (zenz − mean(zenz)) × weight`。平均より良い語はプラス、悪い語はマイナス、未採点はゼロで公平になる。
- **検証**: `ZenzRuntimeTests.testCombineScoresCentersZenzOnScoredMean`（seisansei実数値で再現）。
- **教訓**: 符号が偏ったスコア（logprob等）を部分集合にだけ加算すると、集合の内外で系統的な不公平が生じる。部分採点を混ぜるときは中心化するか全件採点する。BUG-028と同じくdogfoodの1報告から実ログで即再現できた——「候補リストそのものがFixedログに残る」設計が効いている。
