# BUG-032: 未入力のdeactivationで空文字を毎回確定する

- **発見日**: 2026-08-06
- **症状**: 1日分のdogfoodログで `converting=false` のIME切替・フォーカス移動時に `Fixed: "" (reading: "")` が24回記録され、各回で `insertText("")` が呼ばれていた。
- **影響**: 表示上の文字化けはないが、入力先アプリへ不要な空文字確定イベントを送り、確定ログ・分析件数にもノイズを混ぜる。
- **原因**: `deactivateServer(_:)` が `inputPat` の有無を確認せず常に `fix(client:skipStudy:)` を呼んでいた。空状態でも `candidates` に空候補が1件残る経路があり、`fix()` のindex guardを通過した。
- **修正**: `shouldCommitOnDeactivation(inputPat:)` を追加し、未確定入力がある場合だけ `fix(skipStudy: true)` を呼ぶ。空なら `resetState()` のみ実行する。未確定入力の自動確定とsender/clientフォールバックは維持する。
- **検証**: `AcceptedDetailPayloadTests.testDeactivationCommitsOnlyActiveComposition` で空入力を拒否し、非空入力を確定対象にすることを確認。
- **教訓**: deactivationの「未確定入力を失わない」と「常にfixする」は同義ではない。ライフサイクルイベントでは副作用の前に実際のcomposition有無を確認する。
