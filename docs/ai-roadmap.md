# SwiftyGyaim AI / LLM 導入ロードマップ

> Status: Draft
> Last updated: 2026-05-22
> 対象リポジトリ: <https://github.com/tanabe1478/SwiftyGyaim>

## 1. 目的

SwiftyGyaim に LLM / AI を導入し、日本語入力体験・辞書品質・個人化・開発運用を改善する。

ただし、本ロードマップの中心は「LLM を主変換エンジンにする」ことではない。IME は毎秒触る道具であり、遅延・不安定さ・プライバシー・外部依存がそのまま入力体験の悪化につながる。そのため SwiftyGyaim では、既存の Gyaim らしさを保ったまま、AI を次の用途に限定的・段階的に導入する。

- 候補の追加
- 候補の再順位付け
- 明示トリガーによる文章変換
- 辞書改善支援
- ローカルで透明な個人化
- デバッグ・評価・説明可能性の強化

目指す方向は以下である。

> SwiftyGyaim = “AI で賢くなる IME” ではなく、
> “AI も呼べる、透明でプログラマブルな日本語入力環境”。

## 2. 前提: SwiftyGyaim の現在地

### 2.1 プロジェクト概要

SwiftyGyaim は、増井俊之氏の RubyMotion 製 IME `GyaimMotion` を Swift + InputMethodKit へ移植・発展させた macOS 用日本語 IME である。

主な特徴:

- Swift + InputMethodKit 実装
- XcodeGen によるプロジェクト管理
- macOS 13 以降対応
- `NSPanel` ベースの候補ウィンドウ
- リスト表示 / クラシック表示の候補 UI
- キーボードショートカット設定
- ユーザー辞書エディタ
- Google Input Tools API による補完
- os.Logger + `~/.gyaim/gyaim.log` のログ基盤
- 3層辞書システム

### 2.2 主要な実装単位

| 領域 | 主なファイル | 役割 |
| --- | --- | --- |
| 入力処理 | `GyaimSwift/Sources/Gyaim/GyaimController.swift` | キー入力、候補更新、確定、IME lifecycle |
| 辞書検索 | `GyaimSwift/Sources/Gyaim/WordSearch.swift` | Study / Local / Connection の3層検索 |
| 接続辞書 | `GyaimSwift/Sources/Gyaim/ConnectionDict.swift` | 接続辞書の読み込み・検索 |
| 候補 UI | `GyaimSwift/Sources/Gyaim/CandidateWindow.swift` | 候補表示、ページング、位置計算 |
| 設定 UI | `GyaimSwift/Sources/Gyaim/PreferencesWindow.swift` | 設定、ログ、辞書、Google変換など |
| Google 補完 | `GyaimSwift/Sources/Gyaim/GoogleTransliterate.swift` | 非同期 Google Transliterate 候補 |
| ログ | `GyaimSwift/Sources/Gyaim/GyaimLogger.swift` | Unified Logging + ファイルログ |

### 2.3 既存の辞書設計

SwiftyGyaim の辞書は以下の3層で構成される。

| 優先度 | 辞書 | ファイル | 特徴 |
| --- | --- | --- | --- |
| 1 | Study | `~/.gyaim/studydict.txt` | 使用履歴に基づく学習辞書。timestamp / frequency を保持 |
| 2 | Local | `~/.gyaim/localdict.txt` | ユーザーが明示的に登録する辞書 |
| 3 | Connection | `Resources/dict.txt` または `~/.gyaim/connectiondict.txt` | 接続情報付きの固定辞書 |

Study 辞書は `reading`, `word`, `lastAccessTime`, `frequency` を保持し、MRU・淘汰なし・スコアベース淘汰の設定を持つ。

Local 辞書は plain text の TSV であり、ユーザーが直接編集できる。

Connection 辞書は Gictionary 由来の接続辞書を扱える。`dict2.txt` または `Gictionary.json` を取り込み、`~/.gyaim/connectiondict.txt` に保存して利用できる。

### 2.4 既存の候補ソース

現在の候補は概ね以下から作られる。

- Study 辞書候補
- Local 辞書候補
- Connection 辞書候補
- Google Transliterate 候補
- クリップボード候補
- 選択テキスト候補
- raw input 候補
- ひらがな / カタカナ候補
- `ds` などの特殊候補

この構造は、AI 候補を「既存候補ソースの一つ」として差し込むのに向いている。

### 2.5 既存の非同期候補処理

Google Transliterate では、すでに以下の設計がある。

- 明示トリガー文字またはショートカットで発動
- `URLSession` による非同期取得
- 3秒タイムアウト
- `pendingGoogleQuery` による stale guard
- 入力が変わった場合は古い結果を破棄
- callback 後は main queue で候補更新

AI 候補もこの考え方を一般化して扱うべきである。

## 3. SwiftyGyaim の設計思想

SwiftyGyaim が保つべき価値は以下である。

### 3.1 軽量であること

IME は常時動作し、キー入力ごとに呼ばれる。AI 導入により以下が起きると、IME としての価値が落ちる。

- 変換が遅い
- キー入力が詰まる
- メモリ使用量が大きい
- 起動が遅い
- ネットワークに依存する

AI は同期的な主処理に入れず、非同期・低優先度・明示トリガー中心にする。

### 3.2 透明であること

Gyaim 系の強みは、辞書や挙動が読みやすく、ユーザーが改造しやすいことにある。

AI 導入でも、以下を重視する。

- 候補の出自が分かる
- 設定ファイルが読める
- 辞書が plain text で編集できる
- ログで挙動を追える
- AI が何を入力として受け取ったか説明できる
- cloud / local / external command の境界が明確である

### 3.3 プログラマブルであること

Gyaim 由来の魅力は、単なるかな漢字変換に閉じない「変な便利機能」にある。

例:

- 時刻入力
- 画像候補
- 秘密文字列
- コピー / 選択テキスト由来候補
- 辞書を直接触る運用

AI もこの文脈で扱う。

つまり、SwiftyGyaim は「正統派ニューラル IME」を目指すより、ユーザーが自分の入力環境を拡張できる AI-ready IME を目指す。

### 3.4 プライバシーを最優先すること

IME はユーザーの入力をすべて見える位置にある。AI 連携では、通常アプリ以上に慎重な安全境界が必要である。

基本方針:

- デフォルトでは cloud AI に入力内容を送らない
- 選択テキスト / クリップボードは明示許可がある時だけ渡す
- 秘密候補は絶対に AI provider に渡さない
- ログに全文を残す設定は慎重に扱う
- AI provider ごとに許可範囲を明示する
- AI 連携は opt-in にする

## 4. azooKey / AzooKeyKanaKanjiConverter から学ぶこと

### 4.1 公開情報から見える azooKey の方向性

azooKey は iOS / iPadOS 向けの日本語キーボードアプリであり、公開 README では以下が特徴として挙げられている。

- Swift 実装
- 独自開発の高精度変換エンジン
- ニューラルかな漢字変換システム Zenzai
- ライブ変換
- カスタムキー
- カスタムタブ
- iOS / iPadOS 向けのキーボード体験
- macOS 版として azooKey-Desktop も存在

AzooKeyKanaKanjiConverter は azooKey のために開発されたかな漢字変換エンジンであり、公開 README では以下が示されている。

- iOS / macOS / visionOS / Ubuntu で利用可能
- macOS 13 以降対応
- Swift 6.1 以上が必要
- 数行のコードでかな漢字変換を組み込める
- Zenzai による高精度ニューラル変換をサポート
- 学習データ保存
- ComposingText による入力管理
- ConvertRequestOptions による候補要求
- デフォルト辞書あり
- 1.0 未満であり、破壊的変更リスクがある

### 4.2 azooKey の強さ

azooKey / AzooKeyKanaKanjiConverter の強さは、かな漢字変換そのものに正面から取り組んでいる点にある。

特に以下が強い。

- 変換エンジンを独立モジュールとして提供している
- Zenzai によりニューラル変換を選べる
- 学習や予測変換をエンジン側で扱える
- ライブ変換を UX の中心に据えている
- Swift でアプリから組み込みやすい

これは正攻法として強力である。

### 4.3 SwiftyGyaim が同じ方向をそのまま追わない理由

SwiftyGyaim が azooKey と同じ土俵で「高精度ニューラルかな漢字変換 IME」を目指すと、以下のリスクがある。

- 軽量さが失われる
- 実装が大きく複雑になる
- 既存の透明な辞書設計が相対的に弱くなる
- Gyaim 由来の改造しやすさが薄れる
- azooKey の強い領域で後追いになる
- SwiftyGyaim ならではの差別化軸が曖昧になる

そのため、AzooKeyKanaKanjiConverter は「将来の optional provider / adapter」として扱うのがよい。

最初から SwiftyGyaim の中核を置き換えるのではなく、以下のように比較可能な構成にする。

```text
既存 Gyaim 候補
+ AzooKeyKanaKanjiConverter 候補
+ AI rerank
+ ユーザー設定による有効/無効
```

## 5. AI 導入の基本方針

### 5.1 LLM を主変換器にしない

LLM は日本語文章生成には強いが、IME の主変換器としては以下の問題がある。

- latency が高い
- 候補が不安定になりやすい
- 入力のたびに呼ぶには高コスト
- hallucination が起きる
- 候補外の語を勝手に作る
- privacy risk が高い
- offline で使いにくい

したがって、初期段階では LLM は以下に限定する。

- 明示トリガー時の候補生成
- 既存候補の rerank
- 選択テキストの変形
- 辞書改善支援
- 設定・プロファイルに基づく文章補助

### 5.2 AI は CandidateProvider の一種にする

AI 専用の特別扱いを増やすのではなく、候補提供者を抽象化する。

```swift
protocol CandidateProvider {
    var id: String { get }
    var isAsync: Bool { get }

    func candidates(
        for context: ConversionContext
    ) async throws -> [SearchCandidate]
}
```

`ConversionContext` は、AI に渡す情報を明示的に限定する。

```swift
struct ConversionContext {
    let inputPat: String
    let hiragana: String
    let currentCandidates: [SearchCandidate]
    let selectedText: String?
    let clipboardText: String?
    let appBundleIdentifier: String?
    let mode: ConversionMode
}
```

これにより、以下を同じ仕組みで扱える。

- 既存辞書 provider
- Google Transliterate provider
- External command provider
- Foundation Models provider
- AzooKeyKanaKanjiConverter provider
- ローカル LLM provider
- ユーザー自作 script provider

### 5.3 非同期・timeout・stale guard を共通化する

AI 候補は必ず非同期扱いにする。

原則:

- 入力処理をブロックしない
- timeout を短くする
- 古い入力への結果は捨てる
- 返ってきた候補は候補リストに後から merge する
- provider ごとに有効 / 無効を設定できる
- provider ごとに privacy 許可を持つ

Google Transliterate の既存設計を一般化し、`AsyncCandidatePipeline` のような層にまとめる。

## 6. 提案1: AI 候補 provider 基盤

### 6.1 目的

AI 導入の最初の PR では、LLM 本体を入れない。まず AI を差し込める候補 provider 基盤を作る。

### 6.2 追加する概念

#### CandidateSource の拡張

現在の `CandidateSource` は以下を持つ。

- `.study`
- `.local`
- `.connection`
- `.external`
- `.synthetic`

ここに以下を追加する。

```swift
case ai(providerID: String)
case google
case externalCommand(providerID: String)
case azooKey
```

ただし `Equatable` や既存テストへの影響を考えると、初期実装では単純な `.ai` から始めてもよい。

#### SearchCandidate の拡張

現在:

```swift
struct SearchCandidate: Equatable {
    let word: String
    let reading: String?
    let source: CandidateSource
}
```

将来案:

```swift
struct SearchCandidate: Equatable {
    let word: String
    let reading: String?
    let source: CandidateSource
    let label: String?
    let privacyLevel: CandidatePrivacyLevel
    let score: Double?
    let metadata: [String: String]
}
```

初期段階では `label` と `privacyLevel` だけでもよい。

#### CandidatePrivacyLevel

```swift
enum CandidatePrivacyLevel {
    case normal
    case externalText
    case personalMemory
    case secret
}
```

AI provider に渡せるかどうかを判定する材料にする。

### 6.3 provider 実行順序

初期案:

```text
1. Sync providers
   - Study
   - Local
   - Connection
   - Synthetic
   - Clipboard / selected text

2. UI 更新
   - まず即時候補を表示

3. Async providers
   - Google
   - ExternalCommand
   - FoundationModels
   - AzooKey adapter

4. stale guard
   - inputPat が変わっていれば破棄

5. merge / rerank
   - provider policy に従って候補を追加・再順位付け
```

### 6.4 期待される効果

- LLM を入れる前に設計が整理される
- Google Transliterate も同じ枠組みに統合できる
- 将来の provider 追加が容易になる
- テストしやすい
- AI 導入の影響範囲を限定できる

## 7. 提案2: ExternalCommandProvider

### 7.1 目的

SwiftyGyaim 本体を重くせず、外部コマンドで AI 候補を生成できるようにする。

これは Gyaim らしい拡張性と相性がよい。ユーザーは自分の環境に合わせて以下を使える。

- ローカル LLM
- 社内 API
- 自作 Python / Node / Swift script
- 辞書生成 script
- shell command
- MCP 的な補助ツール

### 7.2 設定例

```json
{
  "aiProviders": [
    {
      "id": "local-ai",
      "type": "externalCommand",
      "command": "/Users/me/.gyaim/providers/gyaim-ai-provider",
      "timeoutMs": 800,
      "allowClipboard": false,
      "allowSelectedText": true,
      "allowCloud": false,
      "modes": ["assist", "rerank"]
    }
  ]
}
```

設定ファイルは候補として以下が考えられる。

- `~/.gyaim/ai-providers.json`
- UserDefaults + 設定 UI
- 将来的に GUI から編集

最初は JSON file でよい。

### 7.3 stdin 形式

```json
{
  "version": 1,
  "requestId": "...",
  "mode": "assist",
  "inputPat": "yoroshiku",
  "hiragana": "よろしく",
  "appBundleIdentifier": "com.apple.TextEdit",
  "selectedText": null,
  "clipboardText": null,
  "currentCandidates": [
    {"text": "よろしく", "source": "connection"},
    {"text": "宜しく", "source": "connection"}
  ],
  "profile": {
    "style": "polite-but-not-too-formal"
  }
}
```

### 7.4 stdout 形式

```json
{
  "candidates": [
    {
      "text": "よろしくお願いします",
      "reading": "yoroshiku",
      "label": "丁寧",
      "score": 0.92
    },
    {
      "text": "何卒よろしくお願いいたします",
      "reading": "yoroshiku",
      "label": "フォーマル",
      "score": 0.81
    }
  ]
}
```

### 7.5 エラー時の扱い

- timeout したら候補追加なし
- stderr は debug log に残す
- exit code != 0 は provider failure として扱う
- IME 操作は継続する
- 連続 failure 時は provider を一時停止してもよい

### 7.6 セキュリティ

ExternalCommandProvider は任意コード実行である。デフォルト無効とし、ユーザーが明示的に設定したものだけ実行する。

設定 UI では以下を明示する。

- この provider はローカルでコマンドを実行する
- コマンドは入力内容を読める
- cloud に送るかどうかは provider 側次第
- 信頼できる provider だけ登録する

## 8. 提案3: Gyaim Assist モード

### 8.1 目的

通常のかな漢字変換とは別に、明示トリガーで AI 文章補助を呼び出す。

azooKey の「いい感じ変換」に近い体験を、Gyaim らしい suffix / command 方式で実装する。

### 8.2 基本方針

- 通常入力では発動しない
- suffix またはショートカットでのみ発動
- AI の候補は候補ウィンドウに表示する
- ユーザーが選んだものだけ確定する
- provider が遅ければ出さない
- cloud provider は opt-in

### 8.3 トリガー例

| 入力 | 意味 |
| --- | --- |
| `yoroshiku\`ai` | AI 補助候補 |
| `kaigi\`fmt` | 表現整形 |
| `otsukaresama\`mail` | メール文候補 |
| `kore\`emoji` | 絵文字付き候補 |
| `sentaku\`sum` | 選択テキスト要約 |

Google Transliterate のトリガー文字と衝突しないよう、AI Assist 用の suffix は別設定にする。

例:

- Google: `` ` ``
- AI Assist: `` `ai `` 形式
- Format: `` `fmt ``

### 8.4 入力例

```text
yoroshiku`ai
```

候補:

```text
よろしくお願いします
何卒よろしくお願いいたします
よろしくお願いいたします 🙏
```

```text
otsukaresama`mail
```

候補:

```text
お疲れさまです。
お疲れさまです。以下の件についてご確認ください。
お疲れさまです。先ほどの件について補足です。
```

```text
kaigi`fmt
```

候補:

```text
会議
会議メモ
会議の議事録
会議で確認する事項
```

### 8.5 選択テキスト変換

SwiftyGyaim は選択テキスト候補を持つ。これを AI と組み合わせると強い。

選択テキストがある状態で:

```text
fmt`
```

候補:

```text
丁寧語にする
箇条書きにする
Markdown 整形する
短くする
```

```text
sum`
```

候補:

```text
要約
タイトル案
Slack 向け一文
```

```text
en`
```

候補:

```text
英訳
自然な英語
技術文書向け英語
```

これは単なるかな漢字変換ではなく、IME から文章操作を行う機能であり、SwiftyGyaim の個性になり得る。

## 9. 提案4: AI rerank

### 9.1 目的

AI に候補を生成させるのではなく、既存候補の順序だけを調整する。

### 9.2 なぜ rerank から始めるべきか

LLM 生成は候補外の語を作る可能性がある。一方 rerank なら、候補集合は既存辞書に制約される。

利点:

- hallucination しにくい
- 辞書資産を活かせる
- 失敗しても元候補に戻せる
- latency が高い場合は無視できる
- privacy の入力範囲を限定できる

### 9.3 例

入力:

```text
kisya
```

既存候補:

```text
記者
汽車
貴社
帰社
```

軽い文脈:

```text
直前に「御社」「メール」「ご確認」などがある
```

rerank 結果:

```text
貴社
記者
帰社
汽車
```

ただし、SwiftyGyaim は周辺テキスト取得に IMKTextInput の制約があるため、最初から全文文脈を扱わない。まずは以下に限定する。

- app bundle identifier
- 入力中の reading
- 既存候補リスト
- ユーザープロファイル
- 直近の確定語の小さな履歴

### 9.4 返却形式

AI reranker は候補そのものではなく、index の順序だけ返す。

```json
{
  "order": [2, 0, 3, 1],
  "reason": "メール文脈では貴社が自然"
}
```

本体側は以下を検証する。

- index が範囲内か
- 重複がないか
- 欠落候補を末尾に戻す
- provider failure 時は元順序

### 9.5 注意点

通常入力ごとに rerank すると遅い。初期実装では以下のどちらかに限定する。

- 明示ショートカットで rerank
- 候補数が一定以上かつ provider が高速な場合だけ rerank
- on-device provider のみ自動 rerank

## 10. 提案5: ローカルで透明な個人化

### 10.1 目的

azooKey にはプロフィールプロンプトや履歴学習の方向性がある。SwiftyGyaim では、それを透明なローカルファイルとして実装する。

### 10.2 ファイル構成案

```text
~/.gyaim/studydict.txt
~/.gyaim/localdict.txt
~/.gyaim/profile.md
~/.gyaim/context-memory.jsonl
~/.gyaim/ai-providers.json
```

### 10.3 profile.md

```markdown
# Gyaim profile

- 一人称: 私
- メール文体: やや丁寧、過剰に堅くしない
- 技術文書では英語の関数名を保持する
- 絵文字は基本使わない

## よく使う固有名詞

- SwiftyGyaim
- Gictionary
- InputMethodKit
- XcodeGen
- CandidateProvider

## 変換の好み

- 「実装」は `jissou` で優先
- 「確認」は `kakuninn` で優先
- 「御社」より「貴社」をメールで使う
```

### 10.4 app profile

```json
{
  "bundle": "com.apple.Terminal",
  "prefer": [
    "英数字そのまま",
    "記号半角",
    "短い候補",
    "コード片を壊さない"
  ]
}
```

```json
{
  "bundle": "com.apple.mail",
  "prefer": [
    "丁寧語",
    "句読点あり",
    "メール文体",
    "過剰に堅くしない"
  ]
}
```

### 10.5 context-memory.jsonl

全文ログではなく、最小限のメモリにする。

```jsonl
{"type":"commit","reading":"jissou","word":"実装","bundle":"com.apple.TextEdit","timestamp":...}
{"type":"deleteCandidate","reading":"ken","word":"県","bundle":"com.apple.Terminal","timestamp":...}
```

記録しないもの:

- パスワード
- 秘密候補
- 長い本文
- cloud に送った prompt 全文
- クリップボード全文

### 10.6 個人化の用途

- AI Assist の文体調整
- rerank
- external command provider への context
- 辞書候補生成
- よく使う固有名詞の補助

## 11. 提案6: AI 安全境界

### 11.1 なぜ必要か

IME は最も privacy-sensitive なアプリケーションの一つである。AI provider は候補生成のために入力内容を受け取る可能性があるため、明確な安全境界が必要である。

### 11.2 privacy level

```swift
enum CandidatePrivacyLevel {
    case normal
    case externalText
    case personalMemory
    case secret
}
```

### 11.3 provider policy

```swift
struct AIProviderPolicy {
    let allowInputPat: Bool
    let allowCurrentCandidates: Bool
    let allowClipboard: Bool
    let allowSelectedText: Bool
    let allowPersonalMemory: Bool
    let allowSecret: Bool
    let allowCloud: Bool
}
```

デフォルト:

```text
allowInputPat = true
allowCurrentCandidates = true
allowClipboard = false
allowSelectedText = false
allowPersonalMemory = false
allowSecret = false
allowCloud = false
```

### 11.4 secret 候補

Gyaim 由来の秘密文字列機能は、AI 導入時に明確な強みになる。

ルール:

- secret 候補は AI provider に渡さない
- secret 候補を含む候補リストは redaction して渡す
- secret 確定はログにも本文を残さない
- secret provider と AI provider は明示的に分離する

### 11.5 UI 表示

設定 UI では provider ごとに以下を表示する。

| 項目 | 表示例 |
| --- | --- |
| Provider ID | `local-ai` |
| 種別 | External command |
| 入力読み許可 | ON |
| 候補リスト許可 | ON |
| クリップボード許可 | OFF |
| 選択テキスト許可 | OFF |
| 個人メモリ許可 | OFF |
| Cloud送信 | OFF |

## 12. 提案7: Agentic Dictionary Workflow

### 12.1 目的

実行時 AI より先に、開発時 AI で辞書を育てる。

これは SwiftyGyaim / Gictionary らしさを最も強く出せる領域である。

### 12.2 背景

SwiftyGyaim は Gictionary / 接続辞書を扱える。辞書は TSV / JSON として見える形で存在し、テストやログで挙動を検証できる。

この透明性は AI エージェントと相性が良い。

### 12.3 CLI 案

```bash
gyaim-dict trace masuitosiyuki
gyaim-dict eval corpus/golden.tsv
gyaim-dict propose --from ~/.gyaim/studydict.txt
gyaim-dict explain-entry "目黒駅"
gyaim-dict generate-source --from Gictionary.json
gyaim-dict benchmark --before dict.txt --after proposed-dict.txt
```

### 12.4 trace

入力 reading がどのように候補へ展開されたかを説明する。

例:

```bash
gyaim-dict trace meguroeki
```

出力:

```text
input: meguroeki
segments:
  meguro -> 目黒 / place-name
  eki    -> 駅 / station-suffix
connection:
  place-name -> station-suffix: allowed
candidate:
  目黒駅
source:
  connection dictionary
```

### 12.5 eval

golden corpus を用意し、top1 / top3 / top10 を評価する。

```tsv
reading expected
jissou 実装
kakuninn 確認
masuitosiyuki 増井俊之
meguroeki 目黒駅
```

評価指標:

- top1 accuracy
- top3 accuracy
- top10 accuracy
- average candidate count
- average search latency
- regression count
- dictionary size

### 12.6 propose

Study / Local から connection dict に足すべき語を提案する。

手順:

1. `studydict.txt` / `localdict.txt` を読む
2. connection dict に存在しない語を抽出
3. 頻度・最終利用時刻で優先度を付ける
4. 名詞 / 固有名詞 / 技術用語 / 活用語に分類
5. Gictionary source 形式を提案
6. 接続 class の根拠を説明
7. golden corpus で regression を確認
8. PR 用 diff を生成

### 12.7 AI agent の役割

AI agent に任せること:

- 未登録語の分類
- 読みの正規化案
- 接続 class 候補の説明
- 類似語との比較
- 辞書 entry の draft
- golden corpus の追加案
- regression summary

人間が確認すべきこと:

- 最終的な辞書追加
- 接続 class の妥当性
- privacy-sensitive な語の除外
- ライセンス上問題ない語源か
- 変換品質の判断

### 12.8 CI gate

辞書変更 PR では以下を CI で実行する。

```bash
gyaim-dict validate
gyaim-dict eval corpus/golden.tsv
gyaim-dict benchmark
./Scripts/run-unit-tests.sh
```

CI が出す summary:

```text
Top1: 72.3% -> 73.1% (+0.8)
Top3: 88.5% -> 88.9% (+0.4)
Latency p95: 27.5ms -> 28.0ms (+0.5ms)
Regressions: 2
Improvements: 14
```

### 12.9 これが SwiftyGyaim らしい理由

azooKey 的な「モデルで賢くする」とは別に、SwiftyGyaim は「開いた辞書を AI で育てる」方向に強みを出せる。

- 辞書が見える
- 変更理由が説明できる
- テストできる
- PR review できる
- ユーザー辞書から改善を提案できる
- Gictionary との関係を保てる

## 13. 提案8: 候補の説明可能性

### 13.1 目的

AI 導入でブラックボックス化しないよう、候補の出自と理由を表示できるようにする。

### 13.2 通常表示

候補ウィンドウに出自ラベルを表示する。

```text
1. 実装        [study]
2. 実装する    [connection]
3. jissou      [raw]
4. 実装案      [AI: local-ai]
```

### 13.3 詳細表示

ショートカットで詳細を見る。

```text
候補: 実装
source: study
reading: jissou
frequency: 27
lastAccess: 2026-05-21
score:
  study-frequency: +3.2
  recency: +4.1
  exact-reading: +10
```

AI 候補の場合:

```text
候補: よろしくお願いします
source: AI provider local-ai
mode: assist
input: yoroshiku
profile used: yes
selectedText used: no
clipboard used: no
cloud: no
```

### 13.4 ログとの連携

ログには候補生成結果を構造化して残せるとよい。

```text
AIProvider local-ai mode=assist input=yoroshiku candidates=3 elapsed=420ms stale=false
```

ただし、本文をログに残すかどうかは設定で制御する。

## 14. 提案9: Gyaim 式ライブ候補

### 14.1 背景

azooKey はライブ変換を特徴としている。SwiftyGyaim が同じ UX を完全に追う必要はない。

Gyaim の操作感は以下にある。

- ローマ字入力
- 候補表示
- Space で候補送り
- Enter で確定
- 必要に応じて完全一致検索
- F6 / F7 / shortcut でかな確定

この操作感を壊さず、ライブ変換的な恩恵だけ取り入れる。

### 14.2 ライブ候補プレビュー

入力中の marked text は従来どおり保ち、候補ウィンドウ内で top1 preview を強調する。

例:

```text
入力: nihongonyu
候補:
  日本語入力   ← top1 preview
  日本語乳
  にほんごにゅう
```

### 14.3 実装方針

- 確定動作は変えない
- marked text を勝手に置き換えない
- 候補ウィンドウ上の表示だけ改善する
- preview は候補 source / confidence を持つ
- AI preview は遅ければ表示しない

### 14.4 将来案

ユーザー設定で以下を選べる。

| モード | 動作 |
| --- | --- |
| Classic | 現在の Gyaim 操作 |
| Preview | top1 を候補ウィンドウで強調 |
| Live-lite | marked text に top1 を反映するが、すぐ戻せる |
| Full live | 将来検討。初期導入しない |

## 15. 提案10: AzooKeyKanaKanjiConverter adapter

### 15.1 目的

AzooKeyKanaKanjiConverter を optional provider として接続し、既存 Gyaim 候補と比較可能にする。

### 15.2 位置づけ

最初から中核にしない。

理由:

- Swift 6.1 以上が必要
- 1.0 未満で破壊的変更リスクがある
- 依存が大きくなる可能性がある
- SwiftyGyaim の軽量性と透明性を保ちたい

### 15.3 実装案

```swift
final class AzooKeyCandidateProvider: CandidateProvider {
    let id = "azooKey"
    let isAsync = false

    func candidates(for context: ConversionContext) async throws -> [SearchCandidate] {
        // hiragana / composing text を converter に渡す
        // results.mainResults を SearchCandidate に変換
    }
}
```

### 15.4 比較モード

開発用に比較ログを出す。

```text
input: jissou
Gyaim top3: 実装, 実装する, じっそう
Azoo top3: 実装, 実装する, 実装済み
selected: 実装
```

### 15.5 成功条件

- 既存候補を壊さない
- optional build である
- provider を無効化できる
- latency が許容範囲
- 辞書・学習との関係が明確

## 16. 提案11: Foundation Models provider

### 16.1 目的

Apple のオンデバイス LLM を optional provider として利用する。

### 16.2 位置づけ

macOS 26+ / Apple Intelligence 対応環境向けの optional feature とする。

SwiftyGyaim 本体は macOS 13+ 対応を維持するため、Foundation Models への直接依存は分離する。

### 16.3 用途

- Gyaim Assist
- rerank
- profile-based phrase generation
- selected text formatting
- short summary

### 16.4 設計方針

- build flag で分離
- availability check
- provider として扱う
- cloud provider より privacy level を緩められるが、明示設定は必要
- structured output を使う

### 16.5 例

```swift
if #available(macOS 26, *) {
    providers.append(FoundationModelsCandidateProvider())
}
```

## 17. フェーズ別ロードマップ

## Phase 0: ログ・評価の整備

### 目的

AI 導入前に、改善効果を測れるようにする。

### 実施内容

- 既存ログから候補順・確定 index・検索 latency を集計する script を作る
- `Fixed` ログを構造化しやすくする
- 候補 source ごとの確定率を集計する
- 空文字確定や外部候補誤爆を検出する
- golden corpus の置き場を作る

### 成果物

```text
Scripts/analyze-gyaim-log.py
corpus/golden.tsv
docs/specs/evaluation.md
```

### 成功条件

- 変更前後で top1 / top3 / latency を比較できる
- ログから改善候補を定量的に見つけられる

## Phase 1: CandidateProvider 基盤

### 目的

AI / Google / external / future engines を同じ枠組みで扱えるようにする。

### 実施内容

- `CandidateProvider` protocol を追加
- `ConversionContext` を追加
- `CandidatePrivacyLevel` を追加
- `SearchCandidate` の metadata 拡張を検討
- sync provider / async provider の実行 pipeline を分ける
- stale guard を共通化
- timeout を provider ごとに設定
- mock provider でテスト

### 成果物

```text
Sources/Gyaim/CandidateProvider.swift
Sources/Gyaim/ConversionContext.swift
Tests/GyaimTests/CandidateProviderTests.swift
docs/specs/ai-candidate-provider.md
docs/adr/019-ai-candidate-provider.md
```

### 成功条件

- 既存候補の挙動を壊さない
- mock async provider の stale result が破棄される
- provider 無効時は完全に現状同等

## Phase 2: ExternalCommandProvider

### 目的

本体を重くせずに AI 候補を実験可能にする。

### 実施内容

- `~/.gyaim/ai-providers.json` を読み込む
- external command に JSON を stdin で渡す
- stdout JSON を候補に変換
- timeout / error handling
- provider policy
- 設定 UI は最初は簡易表示のみでもよい

### 成果物

```text
Sources/Gyaim/ExternalCommandCandidateProvider.swift
Tests/GyaimTests/ExternalCommandCandidateProviderTests.swift
docs/specs/external-command-provider.md
examples/ai-providers/simple-provider.py
```

### 成功条件

- ローカル script から候補を追加できる
- timeout しても IME が止まらない
- stderr / error がログに残る
- privacy policy が守られる

## Phase 3: Gyaim Assist

### 目的

明示トリガーで AI 文章補助を呼び出す。

### 実施内容

- `assist` mode を追加
- suffix parser を追加
- `ai`, `fmt`, `mail`, `sum`, `en` などの mode を定義
- external command provider に mode を渡す
- AI 候補を候補ウィンドウに表示
- provider label を表示

### 成果物

```text
Sources/Gyaim/GyaimAssist.swift
Tests/GyaimTests/GyaimAssistTests.swift
docs/specs/gyaim-assist.md
```

### 成功条件

- 通常変換に影響しない
- 明示 suffix でだけ発動する
- 遅い provider の結果は捨てられる
- 選択テキストを使う場合は明示許可が必要

## Phase 4: AI rerank

### 目的

既存候補を AI で並べ替える。

### 実施内容

- rerank provider mode を追加
- index order 形式の返却を定義
- invalid order の検証
- fallback
- provider ごとの auto / manual 設定
- latency guard

### 成果物

```text
Sources/Gyaim/CandidateReranker.swift
Tests/GyaimTests/CandidateRerankerTests.swift
docs/specs/ai-rerank.md
```

### 成功条件

- 候補外の語を生成しない
- provider failure 時に元順序へ戻る
- rerank の理由を debug log に残せる

## Phase 5: Agentic Dictionary Workflow

### 目的

AI を使って辞書改善を継続的に回す。

### 実施内容

- `gyaim-dict trace`
- `gyaim-dict eval`
- `gyaim-dict propose`
- golden corpus
- benchmark
- CI summary
- source dictionary / class mapping 整理

### 成果物

```text
Tools/gyaim-dict/
corpus/golden.tsv
docs/specs/dictionary-evaluation.md
docs/specs/agentic-dictionary-workflow.md
```

### 成功条件

- 辞書変更の品質を数値で比較できる
- AI 提案を人間が review できる
- regression が見える
- Gictionary との関係が説明できる

## Phase 6: Foundation Models provider

### 目的

macOS 26+ でオンデバイス AI を利用する。

### 実施内容

- availability 分離
- provider 実装
- structured output
- privacy policy
- optional build

### 成果物

```text
Sources/Gyaim/FoundationModelsCandidateProvider.swift
docs/specs/foundation-models-provider.md
```

### 成功条件

- macOS 13+ build を壊さない
- 対応環境でのみ有効
- cloud なしで assist / rerank が動く

## Phase 7: AzooKeyKanaKanjiConverter adapter

### 目的

ニューラルかな漢字変換候補を optional に比較導入する。

### 実施内容

- Swift version / dependency 条件の調査
- optional package 化
- provider adapter
- 比較ログ
- benchmark

### 成果物

```text
Sources/Gyaim/AzooKeyCandidateProvider.swift
docs/specs/azookey-adapter.md
```

### 成功条件

- 既存 Gyaim 変換を置き換えず比較できる
- provider を無効化できる
- latency / quality が測れる

## 18. 優先順位

### 最優先

1. CandidateProvider 基盤
2. ExternalCommandProvider
3. Gyaim Assist
4. ログ分析 / 評価基盤

理由:

- 小さく始められる
- SwiftyGyaim の軽さを壊さない
- ユーザーが自由に実験できる
- LLM の種類に依存しない
- 実装リスクが低い

### 次点

5. AI rerank
6. Agentic Dictionary Workflow
7. 候補説明 UI

理由:

- 既存辞書資産を活かせる
- SwiftyGyaim らしい透明性が出る
- 品質改善を継続的に回せる

### 後半

8. Foundation Models provider
9. AzooKeyKanaKanjiConverter adapter
10. ライブ候補プレビュー

理由:

- platform / dependency 条件が重い
- 最初から中核にすると設計が大きくなる
- 基盤ができてから optional に足す方が安全

## 19. 実装時の注意点

### 19.1 InputMethodKit 制約

- IME は background app として動く
- 候補ウィンドウは `.nonactivatingPanel` を維持する
- `NSApp.unhide(nil)` は使わない
- `deactivateServer(_:)` では `sender as? IMKTextInput` に加えて `self.client()` fallback を使う
- 入力処理を重くしない

### 19.2 テスト方針

AI 導入でも、LLM 自体に依存するテストは避ける。

テストすべきこと:

- provider timeout
- stale guard
- JSON parse
- privacy policy
- candidate merge
- rerank order validation
- fallback
- source label
- logging

LLM 出力内容そのものは fixture / mock で固定する。

### 19.3 ログ方針

ログは改善に重要だが privacy risk がある。

デフォルト:

- provider id
- mode
- elapsed ms
- candidate count
- stale discard
- error code

詳細ログ opt-in:

- inputPat
- candidate texts
- provider request / response

禁止または要 redaction:

- secret 候補
- password らしき入力
- 長文 clipboard
- 選択テキスト全文

## 20. 現在のプロトタイプと次の設計メモ

2026-05-22 時点の Tab 明示起動 AI 変換プロトタイプ、および azooKey / AzooKeyKanaKanjiConverter から取り込みたい候補生成設計は `docs/ai-current-state-and-azookey-plan.md` にまとめる。

要点:

- Tab 時のみ AI / Google / 複合候補生成を走らせる
- raw input を候補0に残して誤確定を避ける
- Google Input Tools は当面候補生成の補助輪・teacher として使う
- 最終的にはローカル辞書 + lattice / beam search + cost 設計で Google 依存を下げる
- 次の実装は `CandidateGenerator` 分離、`CandidateKind` 導入、N-best lattice 強化を優先する

## 21. まとめ

SwiftyGyaim は、azooKey のような高精度ニューラル変換 IME を正面から追うより、Gyaim 由来の以下の特徴を AI で伸ばすのがよい。

- 軽量
- 透明
- 改造しやすい
- 辞書が開いている
- 候補ソースを増やしやすい
- 変な便利機能を許容する
- ローカルファイル中心で個人化できる
- ログとテストで改善できる

最初に作るべきものは LLM 変換器ではない。

最初に作るべきものは、AI を安全に差し込める CandidateProvider 基盤である。

その次に ExternalCommandProvider を作れば、SwiftyGyaim 本体を重くせずに、ローカル LLM・社内 API・自作 script・将来の Foundation Models・AzooKeyKanaKanjiConverter をすべて実験できる。

最も SwiftyGyaim らしい発展は、以下の組み合わせである。

```text
透明な3層辞書
+ AI候補 provider
+ Gyaim Assist
+ ローカル profile.md
+ privacy boundary
+ agentic dictionary workflow
+ 候補の説明可能性
```

これにより SwiftyGyaim は、単に「AI が入った IME」ではなく、

> AI 時代の、透明でプログラマブルな日本語入力環境

として発展できる。
