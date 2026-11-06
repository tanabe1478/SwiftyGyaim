# BUG-047: 設定画面で表示スタイルを切り替えると、別コントローラの候補ウィンドウが空になる

- **Issue**: なし（dogfood の報告「クラシック表示壊れてるよね？」）
- **発見日**: 2026-11-06
- **影響**: 設定画面で「リスト表示 / クラシック表示」を切り替えた直後、切り替え前に変換を始めていたアプリで候補ウィンドウが空の吹き出し（クラシック → リスト）または空の灰色の箱（リスト → クラシック）になる。コントローラが作り直されるまで続く（アプリや入力欄を切り替えると治る）。クラシック表示だけを使っていると切り替え自体をしないので気づかない。
- **原因**: 候補ウィンドウは `GyaimController` ごとに 1 枚あるが、`PreferencesWindow.changeDisplayMode` は `CandidateWindow.shared`（最後に作られた 1 枚）にしか `applyDisplayMode()` を呼ばなかった。他のウィンドウは制約と表示 / 非表示が旧モードのまま、`updateCandidates` だけが設定の新モードで分岐し、隠れたビューに文字を流し込んでいた。
- **修正**: `CandidateWindow` が組み立てたモードを `appliedDisplayMode` に覚え、`updateCandidates` で設定と違えば `applyDisplayMode()` を呼んでから更新する。設定画面側は `CandidateDisplayMode.setCurrent` を呼ぶだけにした。
- **検証**: `CandidateWindowDisplayModeTests.testUpdateCandidatesAppliesAModeChangedAfterInit`（classic で作ったウィンドウを list に切り替えて更新 → stack が表示・幅 260、逆方向で吹き出しが表示・幅 241）。修正前はオフスクリーン描画で両方向とも空の枠だけになることを確認した。
- **教訓**: プロセス内に同じ UI が複数枚ある IME では、設定変更を「今見えている 1 枚」に通知する作りは漏れる。ウィンドウ側が描画時に設定と自分の状態を突き合わせる方が確実。
- **関連ADR / PR**: ADR-010（表示モード切替）、設定画面の作り直し PR
