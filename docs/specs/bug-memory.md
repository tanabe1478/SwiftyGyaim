# Spec: バグメモリ

> Trigger: 全ファイル（デバッグ時に参照）
> Last updated: 2026-04-16 (BUG-005追加)

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
