# BUG-036: 同音異義語レビューがユーザーの頻出語を低頻度語で上書きしていた

- **日付**: 2026-09-12
- **症状**: `kimi` で 君（study freq 31）が先頭だったのに、モデルが キミ（freq 7）を先頭にし、ユーザーが 君 を選び直した。`siteki` でも 指摘（63）が 私的（3）に上書き。1.5日のログで、上書きが起きた確定の top1 率は 88.5%、起きなかった確定は 98%。
- **原因**: `selectExactHomophoneWinner` は margin と contextAffinity 優位しか見ておらず、ユーザーが何十回も確定してきた頻度差を無視していた。文字レベル LM は左文脈に出現した表記（キミ）をそのまま高確率にするため、gap 3.4 という「確信」を出していた。
- **修正**: bestのstudy頻度優位 `log2(best/挑戦者)` × 2.0 を要求 margin に加算（`aiRerankExactHomophoneFrequencyMarginWeight`）。挑戦者がstudy語でなければ頻度1扱い。
- **検証**: `HomophoneFrequencyGuardTests` に実ログの数値（kimi / siteki）を固定し、頻度が同等または挑戦者側が多い場合は従来どおり上書きできることも確認。
- **教訓**: モデルの上書きは「ユーザーが既に教えたこと」より弱くあるべき。affinity と同じく頻度も override のコストに入れる。集計は outcome 別 top1 率で見ると上書き経路の劣化がすぐ分かる。
