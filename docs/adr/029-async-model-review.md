# ADR-029: モデルレビューを毎打鍵バックグラウンドで実行し、Space で短く合流する

## Status

Accepted (2026-09-13). Supersedes ADR-026.

## Decision

通常入力のモデルレビュー（同音異義語レビュー・通常レビュー）を、打鍵ごとに専用の直列 queue（`GyaimController.modelReviewQueue`、userInitiated）で実行する。打鍵時は heuristic 順を即座に表示し、レビューが終わったら `FastContextReviewTicket` 経由でメインスレッドに戻し、世代・入力・`searchMode == 0`・`nthCand == 0` が変わっていない場合だけ候補を差し替える。

先頭候補を選ぶ Space（`nthCand == 0`）では、同じ入力のレビューが実行中なら `aiRerankFastContextSelectionWaitMs`（既定 30ms、0〜200）だけ結果を待ってから適用し、届かなければ heuristic 順のまま進む。数字キーや `nthCand > 0` の Enter は表示済みの位置を選ぶ操作なので待たない。

`aiRerankFastContextReviewDelayMs` は「レビュー開始前のスロットル」に意味を変え、既定 0（毎打鍵）とする。打鍵内でモデルを同期実行する経路は削除した。

## Context

ADR-026 は打鍵をブロックしないために 80ms の遅延実行を選んだが、#107 の計測（インストール後 108 確定）で、予約されたレビューの 64.6% がユーザーの Space / Enter より遅く、モデルが最終入力を見る前に確定していた。走った 17 件でも確定順位は heuristic と同じで、モデルの寄与は測定上ゼロだった。一方、候補が微妙なときはユーザーの手が止まるので、そこでレビューが届けば効く場面に効く。

## Consideration

- 毎打鍵同期（ADR-026 以前）: モデルは必ず見るが、打鍵ごとに 20〜27ms（p95 60ms）メインスレッドが止まる。
- 遅延を縮める: 同期部分がメインスレッドに残り、採点開始後の打鍵は待たされる。cancelled 率も部分的にしか下がらない。
- バックグラウンド + Space 合流（採用）: 打鍵は止まらず、モデルは最終入力を含めて毎回見る。Space での待ちは最大 30ms、しかも結果が数 ms 後に届く場合だけ実際に待つ。
- スレッド安全性: `buildPrefixCandidates` は静的関数で、参照するのは `GyaimSettings`（mtime キャッシュ、ロック済み）、`ContextDict.shared.affinity`（ロック済み）、`InProcessAIReranker` → `BundledZenzRuntime`（ロック内でだけ llama を触る）。controller の状態は snapshot（`FastContextPrefixInput`）で渡し、適用はメインスレッドで行う。worker は開始前に ticket の cancelled を確認するので、連続打鍵では最新の入力だけがモデルを呼ぶ。

## Consequences

- モデルが確定に関与する割合が上がる。`modelEffect.committedBeforeReviewRate` で確認し、`netImproved` で純利益を測る（ADR-028）。
- 候補ウィンドウが打鍵から 20〜30ms 後に並び替わることがある。連続打鍵中は次の打鍵で破棄されるため見えない。
- CPU は打鍵ごとに約 25ms のモデル採点（1 日 4,600 打鍵で約 2 分）。
- ADR-026 の「メインスレッド遅延実行」は廃止。設定 `aiRerankFastContextReviewDelayMs` の意味が変わる（既定 80 → 0、スロットル）。
- 実機での体感確認は本 ADR 作成時点で未実施。`aiRerankUseModelForFastContext=false` でモデル経路ごと止められる。

## References

- ADR-026（supersede 対象）、ADR-028（計測）
- docs/internal/model-contribution-investigation-2026-09-12.md「非同期化」
- docs/specs/input-flow.md
