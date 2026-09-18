# BUG-008: Classic候補ウィンドウが白紙になる

- **発見日**: 2026-05-07
- **症状**: `sitei` や `deki` など、候補数が多く長い候補列をClassic表示で出すと、candwin.pngの白いcontent areaだけが表示され候補文字が見えない。スペースを押すと実際には「指定」などに変換できるため、候補生成ではなく描画だけの問題
- **影響**: 候補が存在するのに空白に見え、候補選択が困難になる
- **原因**: Classic表示の `NSScrollView.documentView` である `NSTextView` に文字列は設定されていたが、折り返し高さ計算後に `textView.frame` を明示更新していなかった。documentViewのframeがゼロ/不適切なままになり、白いscrollView背景のみが描画されるケースがあった
- **修正**:
  - `resizeClassicToFit()` で `documentWidth` と `scrollHeight` を計算後、`textView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: scrollHeight)` を設定
  - scroll位置を `.zero` に戻し、`reflectScrolledClipView` でscrollViewに反映
- **検証**: `testClassicModeSizesTextViewForWrappedLongCandidates` を追加し、`sitei` 相当の長い候補列で `NSTextView.string` が空でないこと、`textView.frame.width > 0`、最低高さ以上であることを確認
- **教訓**:
  - `NSScrollView` の `documentView` はAuto Layout制約外になりやすい。文字列設定とlayoutManager計算だけでなく、documentViewのframeを明示する
  - 「候補は確定できるが表示だけ空白」は、候補生成ではなく `NSTextView` / `NSScrollView` の描画・documentViewサイズを疑う
