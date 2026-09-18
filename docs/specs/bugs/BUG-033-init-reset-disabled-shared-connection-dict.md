# BUG-033: コントローラinitの無条件resetで接続辞書の共有が無効化

- **発見日**: 2026-08-10
- **症状**: 「変換が遅くなった」調査中に、`ConnectionDict loaded: 40904 entries`（Release約90ms/Debug約190ms）がアプリ切替のたびに記録されていることを発見。30秒間に3回再ロードすることもあった。PR #83で接続辞書をプロセス共有にしたはずなのに効いていない。
- **影響**: アプリ/入力フィールド切替直後の初回変換が辞書再パース分（約90〜190ms）遅延。共有前と同じ状態。
- **原因**: `GyaimController.init` → `reloadConnectionDictionary()` が**無条件に** `WordSearch.resetConnectionDict()` を呼んでいた。resetはGictionaryインポート（同一パスへの上書き）用なのに、IMKがクライアントごとに再生成するコントローラのinitパスに置かれていたため、生成のたびに共有キャッシュが破棄→再ロード。
- **修正**: init用の `setupWordSearch()`（resetなし、パス一致なら共有再利用）と、明示リロード用の `static reloadConnectionDictionary()`（reset+setup、PreferencesWindowのインポート後にのみ呼ぶ）に分離。
- **検証**: `WordSearchTests.testInitReusesSharedConnectionDictForSamePath`（同一パス再initで共有インスタンスの同一性を確認）
- **教訓**: 「キャッシュ+明示invalidate」を導入するときは、invalidateが**通常パス（init等）から呼ばれていないか**を必ず確認する。ログの `loaded` 行の頻度が共有の実効性を直接示す——共有導入時はログ頻度の before/after を検証に含めること。また、性能退行の調査はまずログの実測値（PerfLog）を新旧期間で比較するのが最短。
