# BUG-030: `文章` の反復学習が生ひらがなに負け、`yonndeite` で学習済み候補を取得できない

- **発見日**: 2026-08-03
- **症状**: `bunsyou` で「文章」を何度選んでも「ぶんしょう」が先頭に戻る。また「この辺の文章を」に続けて `yonndeite` と入力しても、学習済みの「読んでいて」が安定して先頭にならない。
- **影響**: 学習頻度と直前文脈の両方がユーザーの選択を支持していても、候補順位へ反映されない。
- **原因**: (1) 生ひらがなのstudy候補にも ContextDict affinity bonus 1.5と5文字以上のexact bonus 2.0を付けていたため、「ぶんしょう」が短い漢字表記「文章」のstudy頻度差を上回った。(2) BUG-026のかな等価判定は正規表現でprefix取得できた候補だけに適用され、保存済み `yondeite` に対して今回入力 `yonndeite` のように保存readingがqueryの文字列prefixでない方向では候補自体を取得できなかった。
- **修正**: 入力の生ひらがな表記には ContextDict affinity bonusと文字数由来のexact bonusを適用しない。WordSearchのstudy/local検索では、文字列prefix一致に加えてかな等価readingも取得条件にし、exactPriorityのexactバケットにも双方向で含める。
- **検証**: `AIRerankerTests` に頻度12の「文章」がaffinity 1.0・頻度6の「ぶんしょう」に勝つテスト、`WordSearchTests` に保存 `yondeite` を入力 `yonndeite` で `.study/.exact` として取得するテストを追加。
- **教訓**: かな等価は候補取得後の分類だけでなく取得条件そのものに使う。生かな表記は専用確定経路で到達可能なので、文脈学習による自動昇格を漢字同音異義語と同じ強さで扱わない。
