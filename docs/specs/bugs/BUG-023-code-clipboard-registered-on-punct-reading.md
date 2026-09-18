# BUG-023: 句読点付き読みでコード風clipboardが外部候補登録される

- **発見日**: 2026-07-01
- **症状**: `sns_origination_identity_arn` をコピーした状態で `korejjanaino?` を入力すると、clipboard候補として表示・確定され `localdict` に登録された。
- **影響**: snake_case 風の識別子やARN断片が日本語IME候補・ユーザー辞書に混入する。句読点付きの自然文入力では外部候補登録の意図が薄いのに、候補ウィンドウ先頭付近に出る。
- **原因**: 外部候補検証が URL / Gyazo hash には対応していたが、ASCII snake_case 風識別子を許可していた。また `inputPat` に `?` が含まれていても外部候補を挿入・登録していた。
- **修正**: 外部候補検証で snake_case 風ASCII識別子を除外する。`inputPat` に `?` / `!` / `？` / `！` が含まれる場合は外部候補の挿入・登録をしない。確定時にも同じ条件で登録を再検証する。
- **検証**: `ExternalCandidateTests` に snake_case 風識別子の除外、句読点付き入力でのclipboard候補非挿入を追加。
- **教訓**: clipboard/選択テキストはコード・設定値・secret断片を含みうる。外部候補はURL以外のコード風文字列も疑い、句読点付き自然文入力では登録UXより誤登録防止を優先する。
