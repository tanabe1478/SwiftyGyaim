# BUG-006: 候補ウィンドウが画面左下付近に表示される

- **Issue**: #10
- **発見日**: 2026-05-05
- **症状**: Cosense/Scrapbox などブラウザ上のWebアプリで候補ウィンドウがキャレット位置ではなく画面左下付近に表示されることがある
- **影響**: 変換候補が入力位置から大きく離れ、候補選択が困難になる
- **原因**: `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` がスクリーン座標ではなく、`(13.75, 12.0, 1.0, 17.5)` やログで観測された `(34.0, 10.0, 1.0, 14.0)`, `(60.0, 10.0, 1.0, 14.0)` のようなビュー原点付近のローカル座標を返すクライアントがある。`GyaimController.showWindow()` は妥当性チェックなしでこの `lineRect` を使用していた
- **修正**:
  - `CandidateWindowPositioner.resolveLineRect()` を追加し、原点付近かつ1px幅の疑わしい `lineRect` を検出
  - 正常な `lineRect` を `GyaimController.lastValidCandidateLineRect` として保持し、疑わしい値では前回正常値にフォールバック
  - 前回正常値がない場合は `NSEvent.mouseLocation` からフォールバックrectを作成
  - `lineRect` と交差するスクリーンの `visibleFrame` を使い、マルチディスプレイ/画面端でのクランプを改善
  - ログに `reportedLineRect`, `resolvedLineRect`, `source` を出力
- **検証**: `testSuspiciousOriginLineRectFallsBackToPreviousValidRect`, `testSuspiciousOriginLineRectFallsBackToMouseWhenNoPreviousRect`, `testValidReportedLineRectIsUsedAsIs` を追加
- **教訓**:
  - IMKTextInputが返す座標はクライアント依存で、常にスクリーン座標とは限らない
  - UI位置計算では「取得できた」だけでなく「スクリーン座標として妥当か」を検証する
  - フォールバック発生時にログで元値・解決後の値・選択元を確認できるようにする
