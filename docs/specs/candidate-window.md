# Spec: 候補ウィンドウ

> Trigger: CandidateWindow.swift, PreferencesWindow.swift
> Last updated: 2026-03-17

## 概要

NSPanelベースの非アクティブウィンドウ。フォーカスを奪わない（`.nonactivatingPanel`）。

## 表示モード

| モード | 最大候補数 | レイアウト | 選択表示 |
|--------|-----------|----------|---------|
| list | 9 | 縦リスト、番号1-9 | ハイライト行 |
| classic | 11 | 横並び、candwin.png背景 | 下線 |

UserDefaultsキー: `candidateDisplayMode` (Int, 0=list, 1=classic, デフォルト1)

## Classic背景の描画

`ClassicBackgroundView`: candwin.pngを9スライス描画（上部/中央/下部をストレッチ）。候補数に応じて幅を可変。

## 位置計算

`CandidateWindowPositioner`: クライアントから取得した`lineRect`（カーソル位置）を基準に表示位置を計算。画面境界でクランプ。

## モード切替の実装

NSLayoutConstraintのactivation/deactivationで切り替え。list用のNSStackViewとclassic用のClassicBackgroundViewを両方保持し、表示時に切り替える。

## 既知の制約

- IMEはLSBackgroundOnlyのため、`NSApp.unhide(nil)` は使えない。`orderFront(nil)` のみ（ADR-005）
- NSPanelの`.nonactivatingPanel`は必須。通常のNSWindowだとフォーカスを奪う（ADR-006）
