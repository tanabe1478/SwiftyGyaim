# BUG-042: ONNX共有重みのIdentity別名がINT8量子化を妨げる

Last updated: 2026-09-19

Decision encoderを状態と候補で共有すると、legacy ONNX exporterが一部の
定数重みをIdentityノードで別名参照する。ORT dynamic quantizationの
MatMulConstBOnlyではその側が定数と認識されず、元のFP32重みと量子化した重みが
両方残った。実測12.14 MBでサイズ目標を超過した。

export.pyでinitializerに由来するIdentityのみを参照先に置き換えてから量子化する。
graph出力のIdentityは保持する。元のFP32 ONNXファイルは保持し、モデル構造や
選定重みを変えない。修正後INT8は6.84 MB、validation Top-1差0、argmax一致99.93%。

共有重みを2回利用する小さなグラフで数値一致とサイズ削減をテストし、実モデルの
validation全件でも精度差を記録する。量子化の成功は本番品質の達成を意味しない。
