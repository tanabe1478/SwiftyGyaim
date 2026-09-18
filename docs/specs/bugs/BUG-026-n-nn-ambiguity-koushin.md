# BUG-026: n/nnのローマ字揺れで頻出語「更新」が「行進」に負ける

- **発見日**: 2026-07-07
- **症状**: `kousin` 入力で、頻度101の学習済み「更新」が2位に沈み、誤確定の蓄積である「行進」（頻度11）が常に1位に出る。ユーザーは毎回スペースで2位を選ぶか、`kousinn` と打ち直す必要があった。
- **影響**: `ん` を含む語すべてで発生しうる。学習時の入力が `nn` で確定reading（例: `kousinn`）になると、次回 `n` 1つで入力した時に読みが文字列不一致となり、exact保護・同音異義語レビュー・exactボーナスの全てから漏れる。
- **原因**: (1) exact判定（`WordSearch.matchKind` / `AIReranker` / `ZenzRuntime` の protected判定）がローマ字readingの**文字列完全一致**だった。`kousinn` と `kousin` は同じ「こうしん」なのに、前者は prefix 扱い。(2) `studyFrequencyBonus` の cap 0.30 は頻度8で飽和し、両方exactになっても頻度101 vs 11 を区別できず、MRU順（直近の誤確定）が勝っていた。
- **修正**: `WordSearch.matchKind` に かな等価判定（`roma2hiragana(reading) == roma2hiragana(query)`）を追加し、かな等価readingへ `kind=exact` を付与。`AIReranker.isExactReadingMatch` / `ZenzRuntime.isProtectedExactReadingCandidate` は「辞書由来の `kind=exact` かつ reading 非nil」を exact として信頼する（外部候補は reading nil のため対象外）。`studyFrequencyBonus` の cap を 0.60 に引き上げ、頻度差でMRU逆転を可能にした。
- **検証**: `WordSearchTests`（kousinn学習 → kousin検索で kind exact）、`AIRerankerTests`（更新が行進に勝つ・prefix penalty非適用・cap 0.60）、`ZenzRuntimeTests`（かな等価readingが同音異義語レビュー対象）、eval fixture `kana-variant-kousin-001` を追加。
- **教訓**: ローマ字readingは同じかなに対して複数表記がある（`n`/`nn`、将来的には `si`/`shi`、`tu`/`tsu` も同種）。「読みの一致」を判定する箇所は文字列比較ではなくかな正規化後の比較にする。また対数ボーナスのcapは「区別したい実データの頻度域」（今回101 vs 11）を確認してから決める。
