# BUG-038: rerankの先頭変更率と評価traceの世代が不正確だった

- **日付**: 2026-09-13
- **症状**: `topChanged` を先頭変更率として集計していたが、実装は上位8件全体の比較だった。また引き継いだ未コミットtraceではprereviewの後に予約処理が世代を進め、review/確定とIDが一致しなかった。タグ追加後のログは旧正規表現で読めなくなっていた。
- **修正**: topChangedと新旧ログの集計をbefore/afterの先頭比較に統一。検索開始前にリクエスト世代を割り当て、予約では進めず、確定キーのcancel後もtraceの識別子を保持する。controller UUIDで別クライアント/再起動のID衝突を防ぐ。集計・レビュー抽出の両parserを新旧形式対応にした。
- **関連改善**: 同期モデル実行にもheuristic比較順位を持たせ、skip/fallbackと実採点の承認を分離。raw/不正rankと提案・適用順位の不整合を比較から除外する。
- **検証**: FastContextTraceTests / FastContextReviewSchedulingTests / Python ModelEffectTests・RerankParsingTests。
- **教訓**: 非同期/遅延処理の相関IDは予約前に確定する。指標名だけで意味を推測せず、実装とparserの双方をテストする。
