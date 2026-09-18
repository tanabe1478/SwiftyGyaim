# BUG-003: study辞書がファイルに保存されず学習が失われる

- **発見日**: 2026-04-15
- **症状**: Google変換で「明示的」を何度確定しても候補に残らない。ログには `Studied: "明示的" (reading: "meijiteki")` が記録されているが、studydict.txt には該当エントリが存在しない
- **影響**: IMEプロセスが `deactivateServer` を経由せず終了した場合（killall, クラッシュ, OSによる強制終了等）、そのセッション中にstudyされた語がすべて失われる
- **原因**: `WordSearch.study()` はメモリ上の `studyDict` 配列を更新するのみで、ファイル保存（`saveStudyDict`）を呼んでいなかった。保存は `finish()`（deactivateServer経由）か `deleteFromStudy()` のみで行われていた
- **修正**:
  - `study()` の `evict()` 直後に `Self.saveStudyDict(...)` を追加（メイン修正）
  - `AppDelegate.applicationWillTerminate` で `GyaimController.saveStudyDictIfNeeded()` を呼ぶセーフティネット追加
- **検証**: `testStudyPersistsToFileWithoutFinish`, `testStudyFrequencyIncrementPersistsWithoutFinish` の2テストを追加
- **教訓**:
  - メモリ上の変更は必ずファイル保存とペアで行うこと。片方だけ実装すると、ライフサイクルメソッドが呼ばれないケースでデータが失われる
  - `deleteFromStudy` が保存しているのに `study` が保存していない非対称性は設計上の赤信号
  - 「ログには残っているがファイルに存在しない」現象は、メモリと永続化の乖離を示すシグナル
