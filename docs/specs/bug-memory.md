# Spec: バグメモリ

> Trigger: 全ファイル（デバッグ時に参照）
> Last updated: 2026-05-22 (BUG-010追加)

## 概要

過去に発生したバグとその修正パターンを記録する。AIがデバッグ時にこのファイルを参照することで、同じ問題の再発を防ぐ。

## バグ記録

### BUG-001: deactivation時に未確定テキストが消える

- **Issue**: #13
- **発見日**: 2026-03-17
- **影響**: IME切替時にユーザーの入力が消失
- **原因**: `deactivateServer(_:)` が `fix()` を引数なしで呼び、`sender as? IMKTextInput` が常に失敗
- **修正**: `fix(client: sender)` でsenderを渡す + `self.client()` フォールバック追加
- **教訓**: IMKTextInputのクライアント取得は必ず `self.client()` フォールバックを入れること
- **関連ADR**: ADR-012

### BUG-002: deactivation確定でstudyDictに意図しない登録

- **Issue**: #13 (follow-up)
- **発見日**: 2026-03-17
- **影響**: IME切替時の自動確定でローマ字がそのまま学習辞書に登録され、次回入力時に不要な候補が出現
- **原因**: `fix()` が常に `ws?.study()` を呼んでいた
- **修正**: `fix(client:skipStudy:)` パラメータ追加、deactivation時は `skipStudy: true`
- **教訓**: ユーザーが意図的に選択していない確定では学習しないこと
- **関連PR**: #18

### BUG-003: study辞書がファイルに保存されず学習が失われる

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

### BUG-004: 完全一致reading優先が辞書をまたがず localDict exact が studyDict prefix に埋もれる

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

### BUG-005: 複数インスタンスの studyDict が互いの学習データを上書きして消す

- **発見日**: 2026-04-16
- **症状**: Google APIで「乖離」を確定しログにも `Studied: "乖離"` と記録されるが、時間が経つと候補リストに出てこなくなる。studydict.txt からエントリが消失
- **影響**: あるアプリで学習した語が、別アプリ（別の GyaimController インスタンス）での study/save 時に上書きされて消える。BUG-003修正（保存タイミング）後も発生
- **原因**: `studyDict` が `WordSearch` のインスタンス変数だった。InputMethodKit はクライアントアプリごとに別の `GyaimController`/`WordSearch` インスタンスを生成するため、各インスタンスが独立したメモリ上の `studyDict` を保持。インスタンスAで study した語が、インスタンスB の `saveStudyDict` 時にインスタンスBのメモリ（Aの学習を知らない）でファイルを上書きし消失
- **修正**:
  - `WordSearch.studyDict` と `studyDictFile` をインスタンス変数から **static 変数**（プロセス内共有）に変更
  - init() は studyDictFile が異なる場合のみ再読み込み（テスト互換性）
  - `resetStudyDict()` を追加（テスト間のアイソレーション用）
- **検証**: `testStudyVisibleAcrossInstances`, `testStudySurvivesOtherInstanceSave` の2テスト追加
- **教訓**:
  - IMKInputController はクライアントアプリごとにインスタンスが生成される。共有状態（学習辞書等）をインスタンス変数にすると、マルチインスタンス間で不整合が起きる
  - BUG-003（保存タイミング）の修正は必要条件だったが十分条件ではなかった。「保存しても消える」場合は、別インスタンスによる上書きを疑うべき
  - ファイルを介した間接的な共有（各インスタンスが read → modify → write）は write-write 競合の温床。メモリ上で単一の真実を共有すべき

### BUG-006: 候補ウィンドウが画面左下付近に表示される

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

### BUG-007: ローカルXcodeでGyaimTests.xctestを読み込めない

- **発見日**: 2026-05-05
- **症状**: ローカル環境で `xcodebuild -project Gyaim.xcodeproj -scheme GyaimTests -derivedDataPath .build test` を実行すると、`GyaimTests.xctest` の `Contents/MacOS/GyaimTests` は存在するにもかかわらず `Cannot find executable for CFBundle` / `Failed to load the test bundle` で失敗する
- **影響**: ローカルでユニットテストが実行できず、修正確認が困難になる。GitHub Actions では通る場合があり、環境差分として見落としやすい
- **原因**:
  - XcodeGen生成プロジェクトでテストターゲットにもアプリ用 `Resources/Info.plist` が `INFOPLIST_FILE` として入っており、テストバンドルにIMEアプリ用のInfo.plistキーが混入していた
  - ローカルmacOS/Xcodeの組み合わせで生成直後の `.xctest` に `com.apple.provenance` 拡張属性が付き、`xcodebuild test` のローダーが実行ファイルなしとして誤報するケースがある
- **修正**:
  - `project.yml` の `GyaimTests` / `GyaimE2ETests` に `INFOPLIST_FILE: ""` を明示し、生成Info.plistだけを使う
  - `Scripts/run-unit-tests.sh` を追加し、`build-for-testing` → `.xctest` のxattrクリア → `xcrun xctest` の順で実行する
  - CI/Release workflow と agent向けテストコマンドを新スクリプトへ更新
- **検証**: `./Scripts/run-unit-tests.sh` で 222 tests / 0 failures を確認
- **教訓**:
  - 「実行ファイルが見つからない」エラーでも、実際にはInfo.plist混入や拡張属性が原因のローダー失敗である場合がある
  - XcodeGenでアプリソース/リソースをテストターゲットにも含める場合、アプリ用Info.plistをテストバンドルに流用しないこと
  - macOSのローカルセキュリティ属性に起因するテスト実行問題は、`build-for-testing` と `xcrun xctest` の分離で切り分けやすい

### BUG-008: Classic候補ウィンドウが白紙になる

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

### BUG-009: 接続辞書インポートでGitHubリポジトリURLを指定すると失敗する

- **発見日**: 2026-05-07
- **症状**: 設定画面の接続辞書URLに `https://github.com/masui/Gictionary` を入力してインポートすると「Gictionary JSONまたは接続辞書TSVとして解釈できません」と表示される
- **影響**: UI上はGictionaryのURLを指定できそうに見えるが、実際にはGitHubのHTMLページをダウンロードしてしまいインポートできない
- **原因**: `GictionaryConnectionImporter.importFromURL` が入力URLをそのまま `URLSession` に渡しており、GitHubリポジトリURLや `/blob/...` URLをrawファイルURLへ変換していなかった。UIの説明も `dict2.txt` raw URLが必要であることを明示していなかった
- **修正**:
  - `normalizedSourceURL(from:)` を追加し、`https://github.com/<owner>/<repo>` を `https://raw.githubusercontent.com/<owner>/<repo>/master/dict2.txt` へ正規化
  - `https://github.com/<owner>/<repo>/blob/<branch>/<path>` もraw URLへ正規化
  - URL欄が空の場合は推奨raw URLを使う
  - UI文言とspecに、指定できるURL例と使い方を明記
- **検証**: `testGitHubRepositoryURLNormalizesToRecommendedDict2RawURL`, `testGitHubBlobURLNormalizesToRawURL`, PreferencesWindowのURL説明テストを追加
- **教訓**:
  - URL入力UIでは「人間が貼りがちなURL」と「機械が取得すべきraw URL」を区別し、内部で正規化する
  - 外部リポジトリ連携は、成功パスだけでなく実際にユーザーが貼るURL形式でテストする

### BUG-010: AI複合候補に数学記号segmentが混入する

- **発見日**: 2026-05-22
- **症状**: Tab AI候補生成で `nandoka` に対して `ん∩か` / `る∩か` のような不自然な候補が生成される
- **影響**: Zenz rerank では下位に落ちるが、候補リストにノイズが混じり、Zenz scoring 対象も浪費する
- **原因**: CandidateGenerator が完全一致segment候補を文字種検証なしで連結していた。接続辞書に `ando -> ∩` のような記号エントリがあると、日本語文として不適切なcompound候補に混入した
- **修正**:
  - 複合候補segmentに文字種フィルタを追加し、かな・カナ・漢字・全角英数・々/〆/〇のみ許可
  - Zenz scoring の既定対象を上位8件に減らし、raw input を scoring 対象から除外してTab latencyを削減
- **検証**: `testCompoundGenerationRejectsSymbolSegments` を追加
- **教訓**: rerankerで下げられるノイズでも、生成段階で排除できるものは排除する。特に辞書由来の記号・数式文字は日本語IME候補として別扱いにする。

## パターン集

### パターン: IMKTextInputクライアント取得

**常にフォールバックを使う**:
```swift
let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
guard let client = resolvedClient else { ... }
```

`sender` が nil や予期しない型の場合がある（特にライフサイクルメソッド）。

### パターン: ライフサイクルメソッドでの副作用

deactivateServer等のライフサイクルメソッドでは:
1. UIを先にクリーンアップ（hideWindow）
2. テキスト処理（fix）
3. リソース解放（ws?.finish）

の順で実行。テキスト処理でクライアントが取得できない場合でもUIクリーンアップは完了させる。
