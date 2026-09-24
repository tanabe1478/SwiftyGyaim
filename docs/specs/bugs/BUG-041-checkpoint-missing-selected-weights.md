# BUG-041: 単独checkpointにvalidation選定済み重みが含まれない

- **発見日**: 2026-09-19
- **影響**: Decision Modelのcheckpointを元runから切り離すと、以前のvalidationで最良だった
  重みを復元できない。学習途中の重み・optimizer・RNGは復元できても、最終exportに必要な
  best.ptが元runにしか存在しなかった。
- **原因**: checkpointにはbest scoreだけを保存し、対応する重みを同梱していなかった。
- **修正**: checkpointのbest_modelに選定済み重みを保存して再開時に復元する。
  tokenizerも元パスが失われた場合はcheckpoint同梱ファイルへfallbackする。
  古い形式で元best.ptが存在しない場合は、黙って別の重みをexportせず明示的に失敗する。
- **検証**: memory/indexed両モードでcheckpointをコピーして元runを移動し、dropout有効の
  学習を再開。連続実行と最終stateがbit単位で一致することをCPUテストで確認。
- **教訓**: 「学習を続行できるstate」と「同じ選定結果を再現できるstate」は両方必要。
- **関連仕様**: [decision-model.md](../decision-model.md)
