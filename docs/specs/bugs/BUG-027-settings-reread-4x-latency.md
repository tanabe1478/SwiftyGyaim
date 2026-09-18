# BUG-027: 設定ファイルの毎回読込でfast-contextレイテンシが4倍化

- **発見日**: 2026-07-11
- **症状**: dogfood集計で heuristic 経路の p50 が 2.1ms → 8.3ms に悪化（レイテンシゲート p95 < 2ms を大幅超過）。
- **影響**: 全キーストロークの体感。設定を読むすべての経路が対象で、今後設定キーが増えるたびに悪化する構造だった。
- **原因**: `GyaimSettings.loadDictionary()` が読み取りのたびに `~/.gyaim/settings.json` をディスクから読んでJSONパースしていた（キャッシュなし）。従来はrerank毎に数回で顕在化しなかったが、#70 で `ContextDict.isEnabled` を affinity 内（候補ごと＝キーストロークあたり最大24回）に置いたことで顕在化した。
- **修正**: 設定辞書を mtime 無効化付きでキャッシュ（localdictと同じホットリロード方式）。読み取りは stat() 1回+辞書lookupになり、外部編集の反映は維持。`saveDictionary` はキャッシュも同時更新。あわせてモデル無効時の outcome ラベルを `fallback` → `heuristic` に修正（Swift側 `fastContextRerankOutcome`）。
- **検証**: `GyaimSettingsTests` に外部編集の反映・パス切替追随・キャッシュ読み速度ガードを追加。
- **教訓**: 設定読み取りAPIは「軽い」と仮定されて呼び出し側で自由に使われる。ホットパスに入りうる共有APIはキャッシュを内蔵し、コスト特性をAPI側で保証する。dogfoodのレイテンシ集計（byOutcome p50）は機能バグだけでなく性能バグも1日で検出できた。
