# Spec: バグメモリ

> Trigger: 全ファイル（デバッグ時に参照）
> Last updated: 2026-09-15 (bugs/ ディレクトリへ分割、索引化)

## 概要

過去に発生したバグとその修正パターンを記録する。AIがデバッグ時にこの索引から関連するバグだけを参照することで、同じ問題の再発を防ぐ。

このファイルは索引と運用ガイド。各バグの詳細は `docs/specs/bugs/BUG-XXX-<slug>.md` に置く。

## 記録するタイミング

- fix / bugfix / hotfix 系ブランチでのバグ修正時（必須 — pi-context-workflow が `bugs/BUG-*.md` の新規/更新とこの索引の更新をゲートする）
- ビルド・テスト・ランタイムのデバッグで得た再利用可能な知見
- 同じ失敗の再発を防ぐ具体的な予防知識

## ファイル形式（bugs/BUG-XXX-<slug>.md）

```md
# BUG-XXX: タイトル

- **Issue**: #
- **発見日**: YYYY-MM-DD
- **影響**:
- **原因**:
- **修正**:
- **検証**:
- **教訓**:
- **関連ADR / PR**:
```

## 索引

| ID | タイトル | 発見日 | ファイル |
|---|---|---|---|
| BUG-001 | deactivation時に未確定テキストが消える | 2026-03-17 | [BUG-001-input-loss-on-deactivation.md](bugs/BUG-001-input-loss-on-deactivation.md) |
| BUG-002 | deactivation確定でstudyDictに意図しない登録 | 2026-03-17 | [BUG-002-unintended-study-on-deactivation.md](bugs/BUG-002-unintended-study-on-deactivation.md) |
| BUG-003 | study辞書がファイルに保存されず学習が失われる | 2026-04-15 | [BUG-003-study-dict-not-persisted.md](bugs/BUG-003-study-dict-not-persisted.md) |
| BUG-004 | 完全一致reading優先が辞書をまたがず localDict exact が studyDict prefix に埋もれる | 2026-04-15 | [BUG-004-local-exact-buried-by-study-prefix.md](bugs/BUG-004-local-exact-buried-by-study-prefix.md) |
| BUG-005 | 複数インスタンスの studyDict が互いの学習データを上書きして消す | 2026-04-16 | [BUG-005-multi-instance-study-dict-overwrite.md](bugs/BUG-005-multi-instance-study-dict-overwrite.md) |
| BUG-006 | 候補ウィンドウが画面左下付近に表示される | 2026-05-05 | [BUG-006-candidate-window-bottom-left.md](bugs/BUG-006-candidate-window-bottom-left.md) |
| BUG-007 | ローカルXcodeでGyaimTests.xctestを読み込めない | 2026-05-05 | [BUG-007-local-xctest-not-loadable.md](bugs/BUG-007-local-xctest-not-loadable.md) |
| BUG-008 | Classic候補ウィンドウが白紙になる | 2026-05-07 | [BUG-008-classic-candidate-window-blank.md](bugs/BUG-008-classic-candidate-window-blank.md) |
| BUG-009 | 接続辞書インポートでGitHubリポジトリURLを指定すると失敗する | 2026-05-07 | [BUG-009-gictionary-repo-url-import-fails.md](bugs/BUG-009-gictionary-repo-url-import-fails.md) |
| BUG-010 | AI複合候補に数学記号segmentが混入する | 2026-05-22 | [BUG-010-math-symbol-segment-in-ai-compound.md](bugs/BUG-010-math-symbol-segment-in-ai-compound.md) |
| BUG-011 | 長文lattice候補で短い数値segmentと低順位同音語が上位化する | 2026-05-23 | [BUG-011-short-number-segment-wins-in-lattice.md](bugs/BUG-011-short-number-segment-wins-in-lattice.md) |
| BUG-012 | 長文phraseで自然な助詞分割候補が人名prefix複合に負ける | 2026-05-23 | [BUG-012-person-name-compound-beats-particle-split.md](bugs/BUG-012-person-name-compound-beats-particle-split.md) |
| BUG-013 | 誤学習した複数行テキストが候補・ログに露出する | 2026-05-24 | [BUG-013-multi-line-text-leaks-into-candidates.md](bugs/BUG-013-multi-line-text-leaks-into-candidates.md) |
| BUG-014 | 外部候補が辞書候補の後ろに埋もれて単語登録しづらい | 2026-05-30 | [BUG-014-external-candidates-buried.md](bugs/BUG-014-external-candidates-buried.md) |
| BUG-015 | chrome-extension URL が選択テキスト候補として混入し誤学習される | 2026-06-17 | [BUG-015-chrome-extension-url-learned.md](bugs/BUG-015-chrome-extension-url-learned.md) |
| BUG-016 | 接続辞書の内部ラベルが候補 surface に混入する | 2026-06-18 | [BUG-016-internal-label-in-candidate-surface.md](bugs/BUG-016-internal-label-in-candidate-surface.md) |
| BUG-017 | fast-context Zenz review が1文字 prefix で広すぎる置換を行う | 2026-06-19 | [BUG-017-zenz-review-too-broad-on-single-prefix.md](bugs/BUG-017-zenz-review-too-broad-on-single-prefix.md) |
| BUG-018 | 途中入力で polite negative 候補が先頭化する | 2026-06-19 | [BUG-018-polite-negative-tops-mid-input.md](bugs/BUG-018-polite-negative-tops-mid-input.md) |
| BUG-019 | 設定画面で標準Commandショートカットが効かない | 2026-06-19 | [BUG-019-command-shortcuts-dead-in-preferences.md](bugs/BUG-019-command-shortcuts-dead-in-preferences.md) |
| BUG-020 | fast-context model reviewがexact同音異義語を比較できない | 2026-06-22 | [BUG-020-model-review-missed-exact-homophones.md](bugs/BUG-020-model-review-missed-exact-homophones.md) |
| BUG-021 | `ha?` で長いlocal候補が `は？` より上位化する | 2026-06-23 | [BUG-021-long-local-beats-ha-question.md](bugs/BUG-021-long-local-beats-ha-question.md) |
| BUG-022 | exact-homophone review が `ください` を `くださ` へ再短縮する | 2026-07-01 | [BUG-022-exact-review-recontracts-kudasai.md](bugs/BUG-022-exact-review-recontracts-kudasai.md) |
| BUG-023 | 句読点付き読みでコード風clipboardが外部候補登録される | 2026-07-01 | [BUG-023-code-clipboard-registered-on-punct-reading.md](bugs/BUG-023-code-clipboard-registered-on-punct-reading.md) |
| BUG-024 | 同音異義語レビューがひらがな候補を漢字候補より昇格させる | 2026-07-05 | [BUG-024-hiragana-promoted-over-kanji.md](bugs/BUG-024-hiragana-promoted-over-kanji.md) |
| BUG-025 | typo由来の「+い」学習エントリが完成語をincompleteStemPenaltyで沈める | 2026-07-06 | [BUG-025-typo-plus-i-sinks-complete-word.md](bugs/BUG-025-typo-plus-i-sinks-complete-word.md) |
| BUG-026 | n/nnのローマ字揺れで頻出語「更新」が「行進」に負ける | 2026-07-07 | [BUG-026-n-nn-ambiguity-koushin.md](bugs/BUG-026-n-nn-ambiguity-koushin.md) |
| BUG-027 | 設定ファイルの毎回読込でfast-contextレイテンシが4倍化 | 2026-07-11 | [BUG-027-settings-reread-4x-latency.md](bugs/BUG-027-settings-reread-4x-latency.md) |
| BUG-028 | 辞書制約付き選択が一度も候補を出せていなかった | 2026-07-14 | [BUG-028-constrained-selection-never-produced.md](bugs/BUG-028-constrained-selection-never-produced.md) |
| BUG-029 | Zenzスコア加算が採点済み候補を一律減点し、未採点ゴミが上位化 | 2026-07-16 | [BUG-029-zenz-score-penalized-scored-cands.md](bugs/BUG-029-zenz-score-penalized-scored-cands.md) |
| BUG-030 | `文章` の反復学習が生ひらがなに負け、`yonndeite` で学習済み候補を取得できない | 2026-08-03 | [BUG-030-bunshou-learning-loses-to-raw-kana.md](bugs/BUG-030-bunshou-learning-loses-to-raw-kana.md) |
| BUG-031 | 記号候補がexact同音異義語レビューで毎回漢字に上書きされ、学習しても直らない | 2026-07-29 | [BUG-031-symbol-candidate-overwritten-by-kanji.md](bugs/BUG-031-symbol-candidate-overwritten-by-kanji.md) |
| BUG-032 | 未入力のdeactivationで空文字を毎回確定する | 2026-08-06 | [BUG-032-empty-commit-on-deactivation.md](bugs/BUG-032-empty-commit-on-deactivation.md) |
| BUG-033 | コントローラinitの無条件resetで接続辞書の共有が無効化 | 2026-08-10 | [BUG-033-init-reset-disabled-shared-connection-dict.md](bugs/BUG-033-init-reset-disabled-shared-connection-dict.md) |
| BUG-034 | streaming全件学習がデータ終端でfinalを保存せず異常終了する | 2026-09-01 | [BUG-034-streaming-study-missed-final-save.md](bugs/BUG-034-streaming-study-missed-final-save.md) |
| BUG-035 | 淘汰方式「淘汰なし」が MRU と同じ10,000件切り詰めをしていた |  | [BUG-035-no-eviction-still-truncated.md](bugs/BUG-035-no-eviction-still-truncated.md) |
| BUG-036 | 同音異義語レビューがユーザーの頻出語を低頻度語で上書きしていた |  | [BUG-036-homophone-review-overrode-frequent-word.md](bugs/BUG-036-homophone-review-overrode-frequent-word.md) |
| BUG-037 | クリップボードの内容がログに生で残っていた |  | [BUG-037-clipboard-raw-in-logs.md](bugs/BUG-037-clipboard-raw-in-logs.md) |
| BUG-038 | rerankの先頭変更率と評価traceの世代が不正確だった |  | [BUG-038-rerank-head-change-rate-wrong-generation.md](bugs/BUG-038-rerank-head-change-rate-wrong-generation.md) |
| BUG-039 | clientなしの確定試行もacceptedログに含まれていた |  | [BUG-039-clientless-commits-counted-as-accepted.md](bugs/BUG-039-clientless-commits-counted-as-accepted.md) |
