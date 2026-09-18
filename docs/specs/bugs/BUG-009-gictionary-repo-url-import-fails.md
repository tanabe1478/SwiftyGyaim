# BUG-009: 接続辞書インポートでGitHubリポジトリURLを指定すると失敗する

- **発見日**: 2026-05-07
- **症状**: 設定画面の接続辞書URLに `https://github.com/masui/Gictionary` を入力してインポートすると「Gictionary JSONまたは接続辞書TSVとして解釈できません」と表示される
- **影響**: UI上はGictionaryのURLを指定できそうに見えるが、実際にはGitHubのHTMLページをダウンロードしてしまいインポートできない
- **原因**: `GictionaryConnectionImporter.importFromURL` が入力URLをそのまま `URLSession` に渡しており、GitHubリポジトリURLや `/blob/...` URLをrawファイルURLへ変換していなかった。UIの説明も `dict2.txt` raw URLが必要であることを明示していなかった
- **修正**:
  - `normalizedSourceURL(from:)` を追加し、`https://github.com/<owner>/<repo>` を `https://raw.githubusercontent.com/<owner>/<repo>/master/dict2.txt` へ正規化
  - `https://github.com/<owner>/<repo>/blob/<branch>/<path>` もraw URLへ正規化
  - URL欄が空の場合は推奨raw URLを使う
  - UI文言とspecに、指定できるURL例と使い方を明記
- **検証**: `testGitHubRepositoryURLNormalizesToRecommendedDict2RawURL`, `testGitHubBlobURLNormalizesToRawURL`, PreferencesWindowのURL説明テストを追加
- **教訓**:
  - URL入力UIでは「人間が貼りがちなURL」と「機械が取得すべきraw URL」を区別し、内部で正規化する
  - 外部リポジトリ連携は、成功パスだけでなく実際にユーザーが貼るURL形式でテストする
