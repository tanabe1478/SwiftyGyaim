# Spec: キー入力フロー

> Trigger: GyaimController.swift
> Last updated: 2026-03-20

## 概要

GyaimControllerはIMKInputControllerのサブクラスで、全キー入力の処理を担う。

## 入力状態

| 変数 | 型 | 意味 |
|------|---|------|
| `inputPat` | String | 現在のローマ字入力 |
| `candidates` | [SearchCandidate] | 現在の候補リスト |
| `nthCand` | Int | 選択中の候補インデックス |
| `searchMode` | Int | 0=前方一致, 1=完全一致, 2=Google結果 |
| `converting` | Bool (computed) | `!inputPat.isEmpty` |

## イベント処理の流れ

```
handle(_:client:) → routeEvent() → HandleResult
                         ↓
            handleResultに応じた副作用実行
            ├─ 文字入力 → searchAndShowCands()
            ├─ Space → 候補サイクル or searchMode遷移
            ├─ Enter → fix() で確定
            ├─ ESC → resetState()
            ├─ BS → inputPat末尾削除
            └─ F6/F7/shortcut → fixAsKana()
```

## routeEvent() の設計意図

`handle(_:client:)` から副作用のない純粋な分岐ロジックを抽出し、`routeEvent()` static methodとして独立させた（ADR-009）。これによりMockIMKTextInputを使わずにユニットテスト可能。

## 確定パス

| パス | メソッド | 学習 | 用途 |
|------|---------|------|------|
| Enter/数字キー | `fix(client:)` | あり | 通常確定 |
| F6/`;` | `fixAsKana(hiragana: true)` | あり | ひらがな確定 |
| F7/`q` | `fixAsKana(hiragana: false)` | あり | カタカナ確定 |
| IME切替 | `fix(client:sender, skipStudy: true)` | **なし** | deactivation確定 |

## IMEライフサイクル

```
activateServer(_:) → 辞書start, クリップボード取得, showWindow
deactivateServer(_:) → hideWindow, fix(skipStudy: true), 辞書finish
```

**重要**: deactivationではsenderをfix()に渡すこと。渡さないとクライアント取得に失敗しテキストが破棄される（Issue #13で修正済み）。

## showCands() のページ送り

`showCands()` は `nthCand + 1` から `maxVisible` 個の候補を `CandidateWindow.updateCandidates()` に渡す。スペースキーで `nthCand` が進むと表示がスクロールする。

ページ情報の計算:
- `hasMore = (nthCand + 1 + maxCandList) < words.count`
- `hasPrev = nthCand > 0`

ひらがなフォールバック: 候補数が `CandidateDisplayMode.current.maxVisible` 未満の場合、ひらがなを候補に追加。

## 既知の制約

- `handle(_:client:)` のclientはIMKTextInputだが、ターミナルアプリではCtrl+keyを横取りされる
- `routeEvent()` はstaticだがGyaimControllerのインスタンス状態に依存する引数を受け取る
