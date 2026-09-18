# ADR — Architecture Decision Records

重要な設計判断・トレードオフ・方針変更・廃止された決定を記録する。コードに残らない情報をドキュメントとして残すことが目的。

ADR はログ。新しい記録が積み重なるため、エージェントはこの目次とファイル名から今の作業に関係するものだけを読む（全件読み込みはしない）。

## ファイル名

```text
NNN-short-title.md   # 連番3桁（001-029 使用中）。テンプレは 000-template.md
```

## テンプレート

`000-template.md` をコピーして使う。Status は `Draft | Accepted | Rejected | Deprecated | Superseded by ADR-NNN`。

## ルール

- 既存 ADR の内容は書き換えず、変更時は新規 ADR を作成して旧版の Status を `Superseded by ADR-NNN` に更新する
- pi-context-workflow が非 main/master ブランチで ADR 作成をリマインドする（strong signal 設定は `.pi/context-workflow.json`）
