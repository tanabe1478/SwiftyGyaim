# BUG-004: 完全一致reading優先が辞書をまたがず localDict exact が studyDict prefix に埋もれる

- **発見日**: 2026-04-15
- **症状**: ユーザーが `ken` で `件` を毎回確定しても、候補リストで `件` が常に7番目に出る。`exactReadingMatchPriority = ON` でも改善せず
- **影響**: 短い読みの語が長い読みの学習済み prefix 候補に押し流される。ADR-016 の "完全一致優先" の契約が事実上守られていない
- **原因**: `WordSearch.search()` が `studyDict (exact + prefix) → localDict (exact + prefix) → connection` の順で探索しており、**studyDict prefix が localDict exact より先に列挙**される。各辞書内では2-passだが、**辞書をまたいだ exact > prefix の整理がされていなかった**
- **修正**:
  - `WordSearch.search()` の `exactPriority == true` 分岐を **4バケット順序** に変更: `study-exact → local-exact → study-prefix → local-prefix → connection` (ADR-017)
  - connection は単一バケット維持（6バケット案を採用すると、`ken` の単漢字16件が予測候補を押し流すため却下）
- **検証**:
  - `testLocalExactBeatsStudyPrefix`（直接的再現と修正検証）
  - `testStudyExactBeatsLocalExact`（階層維持）
  - `testConnectionExactDoesNotJumpAheadOfStudyPrefix`（regression防止: 6バケット採用していないこと）
  - `testLocalExactSourcePreservedOverConnection`（dedup先着勝ちで .local source 維持）
- **教訓**:
  - 「機能をONにしたが contract を満たさない」は ON/OFF 設定とは別の設計バグ。設定の有無ではなく**仕様の一貫性**を疑うべき
  - dedup の先着勝ちは `source` フィールドの整合性に直結する。priorityを変えるときは候補削除機能との連動を必ず確認
  - 辞書をまたいだランキング設計は connectionDict の static 単漢字を考慮しないと UX が劣化する。"all exact first" は素朴すぎる
