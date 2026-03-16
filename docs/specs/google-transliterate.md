# Spec: Google Transliterate連携

> Trigger: GoogleTransliterate.swift
> Last updated: 2026-03-17

## 概要

内蔵辞書で変換できない語のフォールバック。Google Input Tools APIにひらがなを送信し、漢字候補を取得。

## API

- **Endpoint**: `https://inputtools.google.com/request`
- **Method**: GET
- **Parameters**: text (ひらがな), itc=ja-t-i0-handwrit
- **Timeout**: 3秒

## トリガー方式

1. **サフィックス文字**: inputPatの末尾にトリガー文字（デフォルト`` ` ``）を付ける
   - UserDefaultsキー: `googleTransliterateTrigger`
2. **キーボードショートカット**: 変換中に押すとGoogle変換を発動
   - KeyBindingsで永続化

## 非同期処理フロー

```
triggerGoogleTransliterate()
  → pendingGoogleQuery = inputPat   ← stale guard用
  → URLSession.dataTask (async)
      → callback:
          guard pendingGoogleQuery == originalQuery  ← staleチェック
          → combineSegments() → 直積結合 (max 20件)
          → filterCandidates() → ひらがな重複除去
          → DispatchQueue.main で候補更新
```

## Stale Guard

APIレスポンスが返る前にユーザーが入力を変更した場合、古い結果を破棄する。`pendingGoogleQuery` に発行時のクエリを保存し、コールバックで一致を確認。

## セグメント結合

APIは入力を複数セグメントに分割して返す（例: 「ますいとしゆき」→ [「増井」「俊之」]）。`combineSegments()` で直積を取り、最大20件に制限。

## 既知の制約

- Google APIは外部依存のため、オフラインでは機能しない
- タイムアウト3秒は固定値
- API仕様変更のリスクあり（非公開API）
