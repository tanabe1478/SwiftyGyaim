# Spec: 設定ストア（settings.json）

> Trigger: GyaimSettings.swift
> Last updated: 2026-09-24 (ExactHomophoneMaxCandidates 既定6・FastContextModelMinInputLength 既定3 — ADR-031)

## 概要

すべての設定値は `~/.gyaim/settings.json` に保存する。コードからの読み書きは `GyaimSettings` だけを通し、`UserDefaults.standard` を直接触らない（`GyaimSettingsTests.testKnownKeysMatchSettingsKeysUsedInSources` がキー一覧とソースの一致を検査する）。

- 書き込み: settings.json のみ（ADR-027）。原子的保存、`prettyPrinted` + `sortedKeys`
- 読み取り: settings.json → 無ければ UserDefaults（旧バージョンが書いた値の後方互換 fallback）→ 無ければコード側の既定値
- 起動時移行: `synchronizeFileAndUserDefaults()` が `knownKeys` のうち settings.json に無いキーを UserDefaults から一度だけコピーする。逆方向（ファイル → UserDefaults）のコピーはしない
- `removeObject(forKey:)` はファイルと UserDefaults の両方から消す（fallback で復活させないため）
- キャッシュ: 解析済み辞書を mtime で無効化し、`cacheRevalidationInterval`（既定 0.2 秒）の間は stat() も省く（BUG-027）
- テスト実行中（XCTest 検出時）は `settingsFilePathOverride` を設定した場合だけファイルを使う。未設定なら書き込みは UserDefaults に行き、テストは従来どおり `UserDefaults.standard` で設定・後始末できる
- `Data` 値は `{"type":"data","base64":"..."}` として保存する（`GyaimKeyBindings`）

## キー一覧

既定値はコード側にあり、settings.json には明示的に変更した値だけが入る。「UI」列は設定画面から変更できるもの。

### 一般

| キー | 型 | 既定値 | UI | 内容 |
|---|---|---|---|---|
| `loggingEnabled` | Bool | false | ○ | ファイルログ（info 以上）の有効化 |
| `customModelPath` | String | "" | – | 同梱モデルより優先してロードする GGUF の絶対パス（`~` 展開可） |

### 候補

| キー | 型 | 既定値 | UI | 内容 |
|---|---|---|---|---|
| `candidateDisplayMode` | Int | 1 | ○ | 0=リスト、1=クラシック |
| `clipboardCandidateEnabled` | Bool | true | ○ | コピー直後のクリップボード内容を候補に出す |
| `selectedTextCandidateEnabled` | Bool | true | ○ | 選択テキストを候補に出す |

### 学習辞書・文脈学習

| キー | 型 | 既定値 | UI | 内容 |
|---|---|---|---|---|
| `studyDictEvictionMode` | Int | 0 | ○ | 0=MRU、1=淘汰なし（上限なし、ADR-025）、2=スコアベース |
| `studyHiraganaEnabled` | Bool | true | ○ | 全ひらがな語の確定を学習する |
| `exactReadingMatchPriority` | Bool | false | ○ | 読み完全一致を前方一致より上に並べる（ADR-016/017） |
| `kanaConfirmStudyEnabled` | Bool | false | – | `;` によるひらがな確定も学習する（旧挙動） |
| `contextLearningEnabled` | Bool | true | ○ | ContextDict の記録と affinity 参照（ADR-020） |

### Google 変換・接続辞書・キー割り当て

| キー | 型 | 既定値 | UI | 内容 |
|---|---|---|---|---|
| `googleTransliterateTrigger` | String | `` ` `` | ○ | Google 変換を起動するサフィックス文字 |
| `connectionDictSourceURL` | String | "" | ○ | 最後にインポートに成功した Gictionary の URL |
| `GyaimKeyBindings` | Data | 内蔵既定 | ○ | ショートカット・かな確定キー・候補削除キー（JSON を base64 で格納） |

### 通常入力の並べ替え（fast-context rerank）

| キー | 型 | 既定値 | UI | 内容 |
|---|---|---|---|---|
| `aiRerankFastContextEnabled` | Bool | true | ○ | heuristic 並べ替えの有効化 |
| `aiRerankUseModelForFastContext` | Bool | false | ○ | 同梱モデルによるレビューを使う |
| `aiRerankFastContextLoggingEnabled` | Bool | false | ○ | 入力ごとのレイテンシ・順序ログ |
| `aiRerankFastContextModelMinInputLength` | Int | 3（1〜12。ADR-031 で4から変更） | – | モデルレビューを走らせる最小入力長 |
| `aiRerankFastContextNormalReviewMinInputLength` | Int | 5（1〜12） | – | 同音異義語以外の通常レビューの最小入力長 |
| `aiRerankFastContextMaxContextLength` | Int | 20（1〜200） | – | モデルに渡す左文脈の末尾文字数 |
| `aiRerankFastContextCandidateLimit` | Int | 24（2〜48） | – | 並べ替え対象の辞書候補数 |
| `aiRerankFastContextReviewDelayMs` | Int | 0（0〜1000） | – | 背景モデルレビュー開始前のスロットル（ADR-029）。0 で毎打鍵 |
| `aiRerankFastContextSelectionWaitMs` | Int | 30（0〜200） | – | Space で先頭候補を選ぶとき、実行中のレビュー結果を待つ上限 |

### 同梱モデル

| キー | 型 | 既定値 | UI | 内容 |
|---|---|---|---|---|
| `aiRerankUseBundledZenz` | Bool | true | ○ | 同梱 GGUF モデルを使う |
| `aiRerankZenzWeight` | Double | 0.30 | – | 全件 rerank 時のモデルスコア重み |
| `aiRerankZenzMaxCandidates` | Int | 8 | – | 全件 rerank でモデル採点する上位件数 |
| `aiRerankExactHomophoneMargin` | Double | 0.10 | – | 同音異義語上書きに必要な平均 logprob 差 |
| `aiRerankExactHomophoneMaxCandidates` | Int | 6（〜6。ADR-031 で3から変更） | – | 同音異義語比較の候補数 |
| `aiRerankExactHomophoneAffinityThreshold` | Double | 0.75（〜1.0） | – | この affinity 以上ならレビューをスキップ |
| `aiRerankExactHomophoneFrequencyMarginWeight` | Double | 2.0 | – | best の study 頻度優位 1 doubling あたりの追加 margin（BUG-036） |

### 削除済みキー

以下はコードに存在しない（settings.json に残っていても読まれない）。ADR-024 の Tab パイプライン削除に伴うもの: `aiRerankUseZenzGeneration` / `aiRerankZenzGenerationBeamWidth` / `aiRerankConstrainedSelectionMaxSurfaces` / `aiRerankZenzGenerationLimit` / `aiRerankUseZenzFreeGeneration` / `aiRerankZenzReviewRounds` / `aiRerankZenzAlternativeLimit` / `aiRerankUseGoogle`。legacy 外部 reranker（GPT-2 server / external command）の削除に伴うもの: `aiRerankServerURL` / `aiRerankHTTPTimeoutMs` / `aiRerankCommand` / `aiRerankTimeoutMs` / `aiRerankUseLegacyExternalReranker`。

## 変更手順

1. 読み書きは `GyaimSettings.bool/integer/double/string/data` と `set` を使う（既定値は呼び出し側で `default:` に渡す）
2. キーを `GyaimSettings.knownKeys` に追加する（テストが漏れを検出する）
3. この spec の表に行を追加する
