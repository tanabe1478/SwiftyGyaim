# ADR-019: Gictionary接続辞書インポート

## Status

Accepted

## Context

SwiftyGyaim の接続辞書は元々 https://github.com/masui/Gictionary のデータを変換したものに由来する。これまでは bundle 内の `Resources/dict.txt` だけを読み込んでいたため、Gictionary側の更新やユーザーが用意した接続辞書を利用するにはアプリをビルドし直す必要があった。

## Decision

設定画面からURLを指定し、Gictionaryリポジトリの `dict2.txt` 形式（接続辞書TSV）を `~/.gyaim/connectiondict.txt` にインポートできるようにする。`Gictionary.json` も補助的に読み込み可能とするが、現行辞書との完全一致確認対象は `dict2.txt` とする。

- インポート済みファイルが存在し非空なら bundle 辞書より優先して読み込む
- インポート成功後は現在の `WordSearch` を作り直し、再起動せずに反映する
- 「内蔵辞書に戻す」でインポート済みファイルとURL設定を削除する
- Gictionary JSONは、各pageのtitleを表記、先頭の `読み カテゴリ 次カテゴリ` 行を接続辞書エントリとして扱う
- ひらがな読みは `RomaKana.hiragana2roma()` でローマ字候補に展開する

## Consequences

- Gictionaryのraw JSON URLを指定するだけで接続辞書を更新できる
- bundle辞書はfallbackとして残るため、インポート失敗や削除時も従来動作に戻せる
- InputMethodKitではcontrollerが複数存在し得るため、即時反映は現在の共有controllerを対象とする。他controllerは再生成時または次回reload時に新しい辞書を使う
