# ADR-018: 候補ウィンドウ位置決定のlineRect検証とフォールバック

## Status

Accepted

## Decision

候補ウィンドウの表示位置を決める際、`IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` が返す `lineRect` をそのまま信頼せず、スクリーン座標として妥当かを検証する。

`CandidateWindowPositioner.resolveLineRect()` で以下の順に表示位置用のrectを決定する。

1. 妥当な `reportedLineRect` はそのまま使用し、前回正常値として保存する
2. 原点付近かつ1px幅のような疑わしいrectは、前回正常値にフォールバックする
3. 前回正常値がない場合は `NSEvent.mouseLocation` からフォールバックrectを作る

対象スクリーンは、解決後のrectと交差する `NSScreen.visibleFrame` を優先し、見つからない場合はマウス位置のスクリーン、最後にメインスクリーンを使う。

## Context

Issue #10 および実ログで、候補ウィンドウがキャレット位置ではなく画面左下付近に表示されるケースが確認された。

ログでは、通常はスクリーン座標らしい値が返る一方で、以下のようなビュー原点付近の値が観測された。

```text
lineRect=(34.0, 10.0, 1.0, 14.0) -> origin=(34.0, 24.0)
lineRect=(60.0, 10.0, 1.0, 14.0) -> origin=(60.0, 24.0)
```

また Issue #10 では、Cosense/Scrapbox などブラウザ上のWebアプリで、`(13.75, 12.0, 1.0, 17.5)` のような値が返ることが報告されている。

`GyaimController.showWindow()` はこの `lineRect` を妥当性チェックなしで使用していたため、クライアントがローカル座標を返すと候補ウィンドウも画面左下に出ていた。

## Consideration

### 案1: `lineRect` を常にそのまま使う

実装は最も単純だが、現在の不具合を解決できない。

### 案2: 疑わしい `lineRect` では常にマウス位置を使う

左下表示は避けられるが、キーボード操作中のマウス位置はキャレットから離れていることが多く、候補ウィンドウが不自然な位置に出やすい。

### 案3: 前回正常値を優先し、なければマウス位置にフォールバックする

同じ入力セッションや同じクライアント内では直前の正常なキャレット位置に近い場所へ表示できる。初回など正常値がない場合だけマウス位置を使うため、案2より自然な挙動になる。

この案を採用する。

### 疑わしいrectの判定

ログで観測された不正値はいずれも以下の特徴を持つ。

- `x`, `y` が原点付近
- caret rect らしく幅が1px前後
- 高さは通常の行高程度

そのため、`x/y < 64`, `width <= 2`, `height` が通常行高程度のrectを、スクリーン座標ではなくクライアントローカル座標の可能性が高い値として扱う。

## Consequences

良い点:

- ブラウザ/Webアプリがローカル座標を返す場合でも、候補ウィンドウが画面左下に飛びにくくなる
- 前回正常値を使うことで、マウス位置フォールバック単独より自然な表示位置になりやすい
- ログに `reportedLineRect`, `resolvedLineRect`, `source` を出すため、フォールバック発生時の追跡が容易になる
- `visibleFrame` を使うため、メニューバー/Dock領域やマルチディスプレイでのクランプが改善する

注意点:

- 前回正常値が古い場合、実際のキャレット位置からずれる可能性がある
- 原点付近が本当に有効なスクリーン座標である特殊ケースでは、フォールバックが働く可能性がある。ただし候補ウィンドウを画面左下に出すより、前回正常値/マウス位置の方がUX上安全と判断した

## References

- Issue #10: https://github.com/tanabe1478/SwiftyGyaim/issues/10
- Scrapbox: https://scrapbox.io/swifty-gyaim/候補ウィンドウの表示位置がおかしい時がある
- `docs/specs/candidate-window.md`
- `docs/specs/bug-memory.md` BUG-006
