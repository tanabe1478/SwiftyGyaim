# BUG-012: 長文phraseで自然な助詞分割候補が人名prefix複合に負ける

- **発見日**: 2026-05-23
- **症状**: ログ由来ケース `imanodankaideha` で、期待候補 `今の段階では` が `今野段階では` / `居間載段階では` などより下位になる
- **影響**: 長文phrase入力で自然な助詞分割候補が見つかっていても、辞書内の人名・同音prefix複合に押し流される
- **原因**:
  - lattice上には `今 + の + 段階 + では` から `今の段階では` を生成できていたが、segment length が長い `imano -> 今野` 系の人名prefix複合が局所スコアで勝っていた
  - Swift heuristic rerank が助詞を含む自然な文節構造（`漢字 + の + 漢字`、文末 `では` など）を評価していなかった
- **修正**:
  - `AIReranker.localRerank` に助詞を含む自然なphrase bonusを追加
  - `AIReranker.localRerank` で `kind=exact` かつ reading完全一致の候補に追加 bonus を付与
  - lattice 側に `今 + の + 段階 + では` の複合語 bonus を追加
  - 内蔵辞書への `imanodankaideha` 固定エントリ追加は取り下げ、生成・rerank側で解決する
- **検証**: `testFeedbackWatchlistCasesHaveExpectedCandidateNearTop` に `imanodankaideha -> 今の段階では` を追加し、内蔵phraseエントリなしで上位5件入りを確認
- **教訓**: azooKey型に寄せるなら、長文phraseは固定辞書追加だけに逃がさず、lattice生成済み候補を文節構造・助詞・接続で評価して上げる。辞書追加は未知語や固有表現の最後の手段にする。
