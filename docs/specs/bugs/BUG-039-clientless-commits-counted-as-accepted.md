# BUG-039: clientなしの確定試行もacceptedログに含まれていた

- **日付**: 2026-09-13
- **原因**: `fix` がclientの解決・insertTextより前にaccepted/detailログを出していた。clientなしでresetして帰る場合も確定として記録された。
- **修正**: 通常の確定処理でclientを取得しinsertText等を呼んだ後、学習でfrequency/affinityを更新する前にaccepted/detailログを出す。deactivation除外とclientフォールバックは維持。
- **教訓**: 評価用の選択ラベルは「確定しようとした」ではなく、確定処理がclientへ届いた経路で採る。更新前の学習metadataをsnapshotする。

## パターン集

### パターン: IMKTextInputクライアント取得

**常にフォールバックを使う**:
```swift
let resolvedClient = (sender as? IMKTextInput) ?? (self.client() as? IMKTextInput)
guard let client = resolvedClient else { ... }
```

`sender` が nil や予期しない型の場合がある（特にライフサイクルメソッド）。

### パターン: ライフサイクルメソッドでの副作用

deactivateServer等のライフサイクルメソッドでは:
1. UIを先にクリーンアップ（hideWindow）
2. テキスト処理（fix）
3. リソース解放（ws?.finish）

の順で実行。テキスト処理でクライアントが取得できない場合でもUIクリーンアップは完了させる。
