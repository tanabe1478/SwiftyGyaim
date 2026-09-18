# BUG-034: streaming全件学習がデータ終端でfinalを保存せず異常終了する

- **発見日**: 2026-09-01
- **症状**: 188,981,342件の公開データを使う学習が、予定5,905,667 stepのうち5,905,652 stepまで進んだ直後、Transformersの`Batch does not contain any data`で終了し、`final/`が作られなかった。
- **影響**: 学習は99.9997%まで進みvalidation lossも正常なのに、配布・変換用の最終モデルが保存されない。最新定期checkpointから終了間際を再実行する必要がある。
- **原因**: `max_steps`は生の行数をbatch sizeで割って決めていたが、長期runで停止・再開を繰り返すと、Trainerのバッチ先読みとstreaming dataset state保存の境界によりstep数と残データ数にごく小さな差が生じる。ファイルの行数不足や破損ではなく、期待行数ぶんの読み取りを完了した後の正常なデータ終端だった。
- **修正**: streaming時に限り、Transformersのデータ終端固有メッセージと一致するValueErrorを正常完了として扱い、その時点のモデルを`final/`へ保存する。期待行数より短いファイルはdataset側が別のValueErrorを出すため、誤って完了扱いしない。非streamingと無関係なValueErrorも従来どおり再送出する。
- **検証**: `StreamingCompletionTests`に、streaming終端だけを完了扱いするケース、非streamingでは同じエラーを再送出するケース、無関係なValueErrorを再送出するケースを追加。
- **教訓**: 大規模IterableDatasetの完了条件をstep数だけに置かない。入力側で期待行数とファイル終端を検証したうえで、「検証済みデータを使い切った」ことを正常完了として扱う。また例外を完了へ変換するときは型だけで広く捕捉せず、発生源とメッセージを限定する。
