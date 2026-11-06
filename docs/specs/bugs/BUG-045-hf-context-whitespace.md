# BUG-045: HF文脈評価とnative採点の空白前処理の差

- **Issue**: #125
- **発見日**: 2026-11-04
- **影響**: HF-proxyの候補順位は、半角空白を含む文脈・候補でMacの入力トークン列と異なり得る。数件単位の改善をnative改善として解釈できない。
- **原因**: `LlamaZenzContext.preprocess`は半角空白を全角空白に置換しLFを削除する。PythonのHF評価は文字列を直接tokenizerに渡していた。公開モデルのtokenizerは半角空白と全角空白を同じ列にしない。
- **修正**: `evaluate_context_cases.py`に明示的な`--text-preprocessing native-whitespace`を追加。文脈短縮・prompt組立後にpromptと候補の双方を変換する。既存実験を保持するため既定は従来の`hf`。export/reportに処理名を保存し、比較時に不一致を拒否する。
- **検証**: 合成文字列で制御タグ・全角空白の保持、半角空白/LFの変換を確認。異なる処理モード間の比較を拒否するテストを追加。実tokenizerでも合成例のトークン差を確認。
- **制約**: native-whitespaceでもHF-proxyであり、GGUFのtokenizer/BOS/量子化やMacの本番順位・速度を検証したことにはならない。既存学習データとSFTの前処理は変更していない。
- **教訓**: 比較はデータhashだけでなく、精度と前処理条件も一致させる。数値上の微差を実用改善と同一視しない。
- **関連ADR / PR**: Issue #125、PR #126のnative評価ハーネス
