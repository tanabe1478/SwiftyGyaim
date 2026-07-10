# Spec: バグメモリ

> Trigger: 全ファイル（デバッグ時に参照）
> Last updated: 2026-07-11 (BUG-027追加)

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

### BUG-011: 長文lattice候補で短い数値segmentと低順位同音語が上位化する

- **発見日**: 2026-05-23
- **症状**: ログ由来ケース `jikaikidougo` で、期待候補 `次回起動後` より `次回起動５` / `次回木戸動` / `次回軌道後` などが上位に出る
- **影響**: Tab AI候補生成が、実際にユーザーが選んだ複合語を上位に戻せない
- **原因**:
  - lattice の segment 候補上限が狭く、`kidou -> 起動` のような辞書内で少し下位の候補が探索から落ちやすかった
  - `go -> ５` / `五` のような短い数値候補が長文lattice内で文脈なしに高スコア化していた
  - 一般的な複合語（例: `起動後`）への局所的な補正がなかった
- **修正**:
  - segment候補上限を5に拡張
  - 短い読みの数値segmentをlattice生成から除外
  - `起動 + 後` などログで観測された一般的な複合語に bonus を追加
  - ログ由来 watchlist を `CandidatePipelineFeedbackTests` に追加
- **検証**: `testFeedbackWatchlistCasesHaveExpectedCandidateNearTop` で `jikaikidougo -> 次回起動後` が上位5件に入ることを確認
- **教訓**: 実ログの accepted rank が悪いケースは候補生成の探索幅不足・短segmentノイズ・局所複合語不足のいずれかに分解し、テスト化してから生成側を直す。

### BUG-012: 長文phraseで自然な助詞分割候補が人名prefix複合に負ける

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

### BUG-013: 誤学習した複数行テキストが候補・ログに露出する

- **発見日**: 2026-05-24
- **症状**: ログ由来ケース `kiitenai` の候補列に、改行を含む長いMarkdown風テキストが混入していた
- **影響**: IME候補として不要なだけでなく、個人メモや設定説明、secretに関する文書が候補ウィンドウやログに露出する可能性がある
- **原因**: study/local辞書に登録された候補文字列を表示前に安全検証しておらず、複数行・長大テキストも通常候補として返していた
- **修正**: `WordSearch.search()` の返却直前に候補安全フィルタを追加し、空白のみ、80文字超、改行またはNULを含む候補を除外する
- **検証**: `testSearchFiltersUnsafeMultilineStudyCandidate` を追加
- **教訓**: 学習辞書はユーザー入力由来なので信頼しない。登録時だけでなく検索返却時にも表示安全性を検証する。

### BUG-014: 外部候補が辞書候補の後ろに埋もれて単語登録しづらい

- **発見日**: 2026-05-30
- **症状**: `約` をコピーして `yaku` と入力しても、コピーした `約` が候補ウィンドウ直後に見えず、辞書候補の後ろに埋もれる。ログ上は `Captured clipboard: "約"` が出ているが、`Registered to user dict: "約"` は出ず、localdict に登録されない。
- **影響**: フォーク元 Gyaim の「登録したい単語を選択/コピーして読みを入力すると第一候補に出し、確定でユーザ辞書登録する」体験から外れ、外部候補を選びづらい。
- **原因**: `buildPrefixCandidates()` が `raw input → 辞書検索結果 → 外部候補 → ひらがな` の順で候補を作っていた。候補ウィンドウは raw input の次から表示するため、外部候補が辞書候補より後ろに表示された。
- **修正**: prefix mode の候補順を `raw input → クリップボード → 選択テキスト → 辞書検索結果 → ひらがな` に変更。raw input は Enter 誤確定防止のため先頭維持し、外部候補だけを辞書候補より前へ移動した。コピー後5秒以内の制約は維持。
- **検証**: `ExternalCandidateTests` の候補順期待値を更新し、クリップボード/選択テキストが raw input 直後に並ぶことを確認。
- **教訓**: `candidates` 内部順と候補ウィンドウ表示順は1つずれる（`showCands()` は `nthCand + 1` から表示）。登録UXを確認するときは、内部配列だけでなく表示上の第一候補を基準にする。

### BUG-015: chrome-extension URL が選択テキスト候補として混入し誤学習される

- **発見日**: 2026-06-17
- **症状**: `taisyou` などの入力で `chrome-extension://.../app.html` が候補ウィンドウ先頭付近に表示され、誤って確定すると study 辞書へ学習される。ログには `Captured selected text: "chrome-extension://..."` と `Studied: "chrome-extension://..."` が残る。
- **影響**: Chrome拡張ページのURLが日本語変換候補に混入し、削除しても再び選択テキスト候補として出ると再学習される。
- **原因**: `isValidExternalCandidate()` が URL 除外を `hasPrefix("http")` だけで判定しており、`chrome-extension://` や `obsidian://` など URL scheme 形式の文字列を外部候補として許可していた。
- **修正**: 外部候補検証で前後改行もtrimし、lowercase化した文字列が `://` を含む場合は無効とする。従来の `http` prefix と Gyazo hash 除外は維持。
- **検証**: `ExternalCandidateTests` に `chrome-extension://...` / `obsidian://...` の無効化と、選択テキスト候補への混入防止テストを追加。
- **教訓**: 外部候補は選択中テキスト・クリップボード由来で、アプリ内部URLやdeep linkも入りうる。URL判定は `http(s)` だけに限定せず、scheme形式全般を候補から除外する。

### BUG-016: 接続辞書の内部ラベルが候補 surface に混入する

- **発見日**: 2026-06-18
- **症状**: `omoku` の候補で `重い形容詞` / `おもい形容詞` が `重く` より上位に表示される。誤って確定すると学習辞書にも登録される。
- **影響**: 品詞説明・接続カテゴリのような内部ラベルが通常の日本語入力候補として露出し、fast-context-rerank の exact 優先でさらに目立ちやすくなる。
- **原因**: 接続辞書の `word` が表示 surface と内部接続ラベルを兼ねている。`omoku = omo + ku = 重 + い形容詞` のように、`ku -> い形容詞` が接続探索で連結され、`WordSearch` 側では connection compound exact も通常の `.exact` として扱われていた。
- **修正**: `ConnectionDict` が `word` を `canStart` / `canTerminate` / `contributesSurface` に正規化して扱うようにし、`い形容詞` / `な形容詞` などの内部ラベル風ノードは探索用に残しつつ surface に寄与させない。さらに `WordSearch` の connection 候補追加直前にも狭い suffix フィルタを置き、インポート済み辞書などへの防御層にする。connection compound exact は通常 `.exact` ではなく `.compound` として扱う。
- **検証**: `ConnectionDictTests` / `WordSearchTests` に `omoku` で `重い形容詞` / `おもい形容詞` が出ず、`重く` が残ること、`keiyoushi -> 形容詞` が残ること、`kyokushoka -> 局所化` が connection compound metadata を持つことを確認するテストを追加。
- **教訓**: 接続辞書では表示 surface と接続制御ノードを同じ `word` に詰め込むと、内部カテゴリが候補に漏れる。`*` だけで全ての内部ノード意味を表現しようとせず、`canStart` / `canTerminate` / `contributesSurface` のように接続用ノードと表示 surface を分離する。

### BUG-017: fast-context Zenz review が1文字 prefix で広すぎる置換を行う

- **発見日**: 2026-06-19
- **症状**: dogfood log の `review-fixed` で、`kouh -> 高品質`、`tukat -> つかっちゃ`、`kaiz -> 会場` のように、Swift heuristic の最上位候補から文脈に合わない候補へ先頭が大きく入れ替わるケースが目立つ。
- **影響**: model backend を ON にした dogfood で、fast-context の安全な exact / prefix heuristic を Zenz review が上書きし、通常入力中の第一候補品質が不安定になる。
- **原因**: `evaluateCandidate` の `fixRequiredPrefix` は、最初に不一致になった model 最尤 token までの prefix を返す。ログ上の `review fixed` 160件中157件が1文字 prefix で、`高` / `つ` / `ど` のような短すぎる prefix が既存候補の `hasPrefix` 判定に一致し、広すぎる候補移動を許していた。
- **修正**: fast-context review の既存候補置換では、trim 後2文字未満の `fixRequiredPrefix` を採用しない。また prefix が現在の最上位候補自身に一致する場合は順位変更として扱わず、local order を維持する。
- **検証**: `ZenzRuntimeTests` に、1文字 prefix が置換されないこと、2文字以上の prefix は既存候補へ移動できること、現在の最上位候補自身は replacement にならないことを確認するテストを追加。
- **教訓**: token 単位の model review 結果を候補順位へ変換するとき、1 token / 1文字 prefix は制約として弱すぎる。特に IME の通常入力中 rerank では、候補集合内 `hasPrefix` に直接流す前に prefix 長・現在候補との同一性・安全性を検証する。

### BUG-018: 途中入力で polite negative 候補が先頭化する

- **発見日**: 2026-06-19
- **症状**: dogfood log で `onegaisim` の `お願いします -> お願いしません`、`omoim` の `おもいます -> 思いません` のように、`masen` まで入力していない段階で polite negative 候補が第一候補になる。
- **影響**: 肯定・依頼表現を入力している途中で否定表現が先頭化し、Enter 確定時に意味が反転する可能性がある。
- **原因**: 学習済み候補や prefix 候補の metadata によっては、`〜ません` が exact / 高スコア候補として扱われ、prefix penalty だけでは `お願いします` / `思います` 系を守りきれない。
- **修正**: `masen` / `masenn` が inputPat に含まれず、左文脈にも否定 cue がない場合、`ません` / `ませんか` / `ません？` / `ませんか？` で終わる候補へ `politeNegativePredictionPenalty` を与える。Python offline evaluator にも同じ feature を追加し、dogfood 由来 fixture を2件追加。
- **検証**: `AIRerankerTests` に premature polite negative の抑制と、`masen` まで明示入力した場合は抑制しないテストを追加。fast-context eval fixture は 107件で top1 `107/107`。
- **教訓**: 通常入力中の prefix prediction では、長い候補が「文法的にあり得る」だけでは先頭にしない。特に否定・依頼・疑問など意味を反転させる接尾表現は、入力文字列または左文脈で明示されるまで保守的に扱う。

### BUG-019: 設定画面で標準Commandショートカットが効かない

- **発見日**: 2026-06-19
- **症状**: 設定画面で他のmacOSアプリでは効く `Cmd+W` や `Cmd+V` が効かない。
- **影響**: 設定画面をキーボードで閉じられず、URL入力欄などへの paste もできないため、通常のmacOSアプリとしての操作感を損なう。
- **原因**: IMEは `LSBackgroundOnly` で動作し、設定画面表示時だけ `.accessory` に切り替える。通常アプリのようなメインメニュー / Editメニューを持たないため、Command key equivalent が標準メニューアクションとして解決されず、`keyDown` override だけでは `Cmd+W` / `Cmd+V` を安定して受けられない。
- **修正**: `PreferencesWindow.performKeyEquivalent(with:)` で `Cmd+W` を直接処理し、`Cmd+X/C/V/A/Z` と `Shift+Cmd+Z` は `NSApp.sendAction` で first responder へ標準 text / undo action として送る。
- **検証**: `PreferencesWindowTests` に `Cmd+W` が window を閉じること、`Cmd+V` が first responder の `paste(_:)` に dispatch されることを確認するテストを追加。
- **教訓**: `LSBackgroundOnly` なIMEが一時的に設定画面を出す場合、通常アプリのメニュー由来ショートカットを前提にしない。`keyDown` ではなく `performKeyEquivalent` または明示的なメニュー構築で標準Command操作を補う。

### BUG-020: fast-context model reviewがexact同音異義語を比較できない

- **発見日**: 2026-06-22
- **症状**: `どちらの` の後に `muki` を入力した場合、文脈上は `向き` が自然でも `無機` が上位に出ることがある。
- **影響**: `向き` / `無機`、`機能` / `昨日` のような同じ読みの候補が、左文脈を使わず学習・元順・heuristicだけで選ばれる。
- **原因**: fast-context の model opt-in 経路は `.exact` / `.compound` の最上位候補を `protected-exact-skip` として常にZenz reviewから除外していた。これはprefix予測候補へ沈めない安全策として有効だが、同じ読みのexact候補同士の比較まで禁止していた。
- **修正**: 左文脈があり、同じ読みの `.exact` / `.compound` 候補が複数ある場合だけ exact 同音異義語 review を許可する。Zenz の `fixRequiredPrefix` による置換先は同じ読みの `.exact` / `.compound` 候補に限定し、prefix予測候補への移動は引き続き禁止する。
- **検証**: `ZenzRuntimeTests` に、exact同音異義語レビューの発火条件と、置換先制限がprefix候補を拒否することを確認するテストを追加。
- **dogfood追記**: `exact-homophone-fixed` 30件を一次レビューしたところ、`ください -> くださ` の未完成候補昇格が1件見つかった。ひらがな候補を末尾 `い` 1文字だけ削った未完成候補へ短縮する置換を拒否し、regression test を追加。
- **教訓**: 「exact保護」は prefix 予測への誤沈降を防ぐための制約であり、同じ読みの候補間比較まで一律に止めると文脈rerankの価値が出ない。安全境界は候補kindだけでなく、同一reading内/外で分ける。また、同一reading内でも未完成なひらがな短縮候補を上げると入力途中感が強くなるため、表記の完成度も安全条件に含める。
- **2026-07-04追記**: fixRequiredPrefix 経由の置換は ADR-021 で protected exact 候補同士の直接logprob比較に置き換えた。またユーザー履歴による文脈条件付き学習（ContextDict、ADR-020）でモデルを呼ばずに同音異義語を解決する経路を追加した。

### BUG-021: `ha?` で長いlocal候補が `は？` より上位化する

- **発見日**: 2026-06-23
- **症状**: `ha?` 入力で `投機的デコーディング` が `は？` より上位になり、確定後に `ha?` の study/local 候補として残った。さらに `h` / `ha` の prefix 候補にも混入した。
- **影響**: 句読点つき短入力で、直前に誤登録された長いユーザー辞書候補が自然な句読点候補を押しのける。削除操作で study だけ消しても local に残ると復活する。
- **原因**: `kind=exact` かつ `reading == inputPat` の長い local 候補に exact reading bonus / source bias が強くかかり、句読点を含む自然候補 `は？` の小さな punctuation penalty を上回った。また候補削除は候補sourceに応じて study または local の片方だけを削除していた。
- **修正**: `inputPat` が `?` / `!` で終わる場合、対応する句読点を含まない候補に `punctuatedInputMismatchPenalty` を与える。候補削除UIでは `.study` / `.local` のどちらから見えた場合でも、同じ word/reading を study/local 両方から削除する。
- **検証**: `AIRerankerTests` に `ha?` で `は？` が `投機的デコーディング` より上位になる regression test を追加。`WordSearchTests` に `deleteFromUserDictionaries` が study/local 両方を削除するテストを追加。fast-context eval fixture に `ha?` ケースを追加。
- **教訓**: ユーザー辞書由来の exact 候補でも、句読点つき短入力では「句読点を含むか」を安全条件に含める。削除UIは表示sourceだけを信用せず、同一word/readingのユーザー管理辞書をまとめて掃除する。

### BUG-022: exact-homophone review が `ください` を `くださ` へ再短縮する

- **発見日**: 2026-07-01
- **症状**: guard導入後のdogfoodでも `kudasa` で `ください -> くださ` が再発した。ログ上は current best が `下さ`、Zenz prefix が `く`、replacement が `くださ` になっていた。
- **影響**: ユーザーが `kudasai` へ入力継続する途中で、未完成なひらがな語幹 `くださ` が先頭に出る。
- **原因**: 既存guardは current best と replacement の直接比較だけを見ていたため、`下さ -> くださ` は不完全短縮として検出できなかった。候補集合内に `ください` が存在することを見ていなかった。
- **修正**: exact-homophone replacement では、replacement だけでなく候補集合全体を見て、`replacement + い` に相当する完成候補がある場合は未完成語幹への置換を拒否する。同じ prefix で安全な `ください` が後続候補にあればそちらへ移動できる。Swift heuristic / offline evaluator でも `少な` / `くださ` のような末尾 `い` 欠落語幹へ `incompleteISuffixStemPenalty` を与える。
- **検証**: `ZenzRuntimeTests` に current best が `下さ` でも `くださ` を飛ばし `ください` へ到達する regression test を追加。`AIRerankerTests` と fast-context eval fixture に `sukuna -> 少な` / `kudasa -> くださ` 抑制を追加。
- **教訓**: safety guard は current best との2者比較だけでは足りない。候補集合内のより完成した候補を見て、未完成語幹への降格を拒否する。
- **2026-07-04追記**: ADR-021 で置換機構を直接logprob比較に変更し、未完成語幹は比較対象から除外（`exactHomophoneCandidateIndices`）する構造にしたため、この置換ガードのクラスは経路ごと解消。heuristic 側は `incompleteStemPenalty` に改名し、`っ` 終わり語幹（`使っ` vs `使った`）にも汎化した。

### BUG-023: 句読点付き読みでコード風clipboardが外部候補登録される

- **発見日**: 2026-07-01
- **症状**: `sns_origination_identity_arn` をコピーした状態で `korejjanaino?` を入力すると、clipboard候補として表示・確定され `localdict` に登録された。
- **影響**: snake_case 風の識別子やARN断片が日本語IME候補・ユーザー辞書に混入する。句読点付きの自然文入力では外部候補登録の意図が薄いのに、候補ウィンドウ先頭付近に出る。
- **原因**: 外部候補検証が URL / Gyazo hash には対応していたが、ASCII snake_case 風識別子を許可していた。また `inputPat` に `?` が含まれていても外部候補を挿入・登録していた。
- **修正**: 外部候補検証で snake_case 風ASCII識別子を除外する。`inputPat` に `?` / `!` / `？` / `！` が含まれる場合は外部候補の挿入・登録をしない。確定時にも同じ条件で登録を再検証する。
- **検証**: `ExternalCandidateTests` に snake_case 風識別子の除外、句読点付き入力でのclipboard候補非挿入を追加。
- **教訓**: clipboard/選択テキストはコード・設定値・secret断片を含みうる。外部候補はURL以外のコード風文字列も疑い、句読点付き自然文入力では登録UXより誤登録防止を優先する。

### BUG-024: 同音異義語レビューがひらがな候補を漢字候補より昇格させる

- **発見日**: 2026-07-05
- **症状**: exact同音異義語の直接logprob比較（ADR-021）導入後のdogfoodで、`komi` の「込み」より「こみ」、`ikka` の「一家」より「いっか」がZenzレビューで先頭化した。
- **影響**: study辞書が「込み」（頻度3）を持ち、ユーザーが `komitto` 入力途中でも、意味の薄いひらがな候補が先頭に出る。`exact-homophone-fixed` 42件中3クラス（こみ/いっか/てっていて系）で発生。
- **原因**: 文字レベルLM（zenz-v3.1-xsmall）はひらがな列に系統的に高い平均logprobを与える（`いっか` -0.33 vs `一家` -1.88、`こみ` -1.88 vs `込み` -2.55）。長さ正規化では消えないLM固有のバイアス。
- **修正**: 入力の生かな表記（候補text == `request.hiragana` のひらがなのみ候補）を、bestでない限り `exactHomophoneCandidateIndices` の比較対象から除外する。悪性昇格3クラスはすべて生かな表記だった。生かな表記は heuristic 順・かな確定キー（`;` / `q`）から常に到達できるため機能は失われず、`ください`（生かな表記 `くださ` とは別語）のような正当なひらがな語は比較対象に残る。bestが生かな表記そのものの場合は除外せず、漢字同音異義語の昇格を維持する。
- **検証**: `ZenzRuntimeTests` に、生かな表記の除外・bestが生かな表記の場合の非除外・`ください` が比較対象に残ること（BUG-022回帰意図の維持）を確認するテストを追加。
- **教訓**: LMスコアの直接比較を導入するときは、モデル固有の系統バイアス（かな優位・短文優位など）を候補フィルタ側で相殺する。dogfoodログに候補別スコアを出しておくと、この種のバイアスが数値で即特定できる。

### BUG-025: typo由来の「+い」学習エントリが完成語をincompleteStemPenaltyで沈める

- **発見日**: 2026-07-06
- **症状**: `sitehosii` 入力で、頻度22の学習済み「してほしい」が3位に沈み、typo由来の「してほしいい」（頻度1）が1位に出た。
- **影響**: 「い」で終わる完成語すべてが、過去に「+い」のtypoを一度でも確定していると恒常的に降格される。直近24時間のaccepted rankでrank 4+确定の一因。
- **原因**: `incompleteStemPenalty`（BUG-022対策）は「候補集合に `stem+い` が存在すれば stem は未完成」と判定していた。completion側が正当な語であることを暗黙に仮定しており、studydictのゴミエントリ「してほしいい」が「してほしい」を未完成語幹に見せた。
- **修正**: `isIncompleteStemCompletion` に「stemが既に『い』で終わる場合は+い完成とみなさない」ガードを追加（Swift / Python evaluator両方）。「い」欠落ルールの前提は「stemに末尾のいが無い」ことなので、い終わりstemは定義上対象外。`少な→少ない` / `くださ→ください` の既存抑制は維持。
- **検証**: `AIRerankerTests` に「してほしい」が降格されない regression test、eval fixture に `incomplete-stem-sitehosii-garbage-001` を追加。
- **教訓**: 「候補集合内の別候補を根拠に penalize する」ルールは、根拠側の候補が正当であることを検証できない（studydictにはtypoが混入する）。ルールの言語的前提（い終わり語幹は既に完成形）を条件に明示することで、ゴミ根拠に対して頑健になる。

### BUG-026: n/nnのローマ字揺れで頻出語「更新」が「行進」に負ける

- **発見日**: 2026-07-07
- **症状**: `kousin` 入力で、頻度101の学習済み「更新」が2位に沈み、誤確定の蓄積である「行進」（頻度11）が常に1位に出る。ユーザーは毎回スペースで2位を選ぶか、`kousinn` と打ち直す必要があった。
- **影響**: `ん` を含む語すべてで発生しうる。学習時の入力が `nn` で確定reading（例: `kousinn`）になると、次回 `n` 1つで入力した時に読みが文字列不一致となり、exact保護・同音異義語レビュー・exactボーナスの全てから漏れる。
- **原因**: (1) exact判定（`WordSearch.matchKind` / `AIReranker` / `ZenzRuntime` の protected判定）がローマ字readingの**文字列完全一致**だった。`kousinn` と `kousin` は同じ「こうしん」なのに、前者は prefix 扱い。(2) `studyFrequencyBonus` の cap 0.30 は頻度8で飽和し、両方exactになっても頻度101 vs 11 を区別できず、MRU順（直近の誤確定）が勝っていた。
- **修正**: `WordSearch.matchKind` に かな等価判定（`roma2hiragana(reading) == roma2hiragana(query)`）を追加し、かな等価readingへ `kind=exact` を付与。`AIReranker.isExactReadingMatch` / `ZenzRuntime.isProtectedExactReadingCandidate` は「辞書由来の `kind=exact` かつ reading 非nil」を exact として信頼する（外部候補は reading nil のため対象外）。`studyFrequencyBonus` の cap を 0.60 に引き上げ、頻度差でMRU逆転を可能にした。
- **検証**: `WordSearchTests`（kousinn学習 → kousin検索で kind exact）、`AIRerankerTests`（更新が行進に勝つ・prefix penalty非適用・cap 0.60）、`ZenzRuntimeTests`（かな等価readingが同音異義語レビュー対象）、eval fixture `kana-variant-kousin-001` を追加。
- **教訓**: ローマ字readingは同じかなに対して複数表記がある（`n`/`nn`、将来的には `si`/`shi`、`tu`/`tsu` も同種）。「読みの一致」を判定する箇所は文字列比較ではなくかな正規化後の比較にする。また対数ボーナスのcapは「区別したい実データの頻度域」（今回101 vs 11）を確認してから決める。

### BUG-027: 設定ファイルの毎回読込でfast-contextレイテンシが4倍化

- **発見日**: 2026-07-11
- **症状**: dogfood集計で heuristic 経路の p50 が 2.1ms → 8.3ms に悪化（レイテンシゲート p95 < 2ms を大幅超過）。
- **影響**: 全キーストロークの体感。設定を読むすべての経路が対象で、今後設定キーが増えるたびに悪化する構造だった。
- **原因**: `GyaimSettings.loadDictionary()` が読み取りのたびに `~/.gyaim/settings.json` をディスクから読んでJSONパースしていた（キャッシュなし）。従来はrerank毎に数回で顕在化しなかったが、#70 で `ContextDict.isEnabled` を affinity 内（候補ごと＝キーストロークあたり最大24回）に置いたことで顕在化した。
- **修正**: 設定辞書を mtime 無効化付きでキャッシュ（localdictと同じホットリロード方式）。読み取りは stat() 1回+辞書lookupになり、外部編集の反映は維持。`saveDictionary` はキャッシュも同時更新。あわせてモデル無効時の outcome ラベルを `fallback` → `heuristic` に修正（Swift側 `fastContextRerankOutcome`）。
- **検証**: `GyaimSettingsTests` に外部編集の反映・パス切替追随・キャッシュ読み速度ガードを追加。
- **教訓**: 設定読み取りAPIは「軽い」と仮定されて呼び出し側で自由に使われる。ホットパスに入りうる共有APIはキャッシュを内蔵し、コスト特性をAPI側で保証する。dogfoodのレイテンシ集計（byOutcome p50）は機能バグだけでなく性能バグも1日で検出できた。

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
