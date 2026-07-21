# BUG-005: studyDict lost update の TLA+ モデル

## 目的

BUG-005 を、2つの `WordSearch` インスタンスによる read-modify-write として最小化し、次の不変条件を TLC で検査する。

```tla
NoLostUpdate == learned \subseteq disk
```

`learned` は完了済みの `study()` 呼び出し、`disk` は `studydict.txt` に保存されている項目を表す。一度完了した学習項目がディスクから消えないことが期待する性質である。

各インスタンスが学習する項目は、そのインスタンス識別子（`A` または `B`）で表す。頻度、MRU順、ファイル形式、原子的ファイル置換は lost update の成立に影響しないため抽象化している。

## モデルと実装の対応

| モデル | `SharedMemory` | 対応する実装 |
|---|---:|---|
| `Buggy.cfg` | `FALSE` | BUG-005修正前。各 `WordSearch` が初期化時に独立した `studyDict` snapshot を持つ |
| `Fixed.cfg` | `TRUE` | 現行実装。同一IMEプロセスの全 `WordSearch` が static `studyDict` を共有する |

旧方式では、AとBがともに空のファイルを読み、Aが `{A}`、続いてBが古いsnapshotを基に `{B}` を保存できる。この時点で `learned = {A, B}`、`disk = {B}` となり、`NoLostUpdate` に違反する。

現方式では、Aの更新後に共有状態が `{A}` となり、Bは同じ状態へ追加して `{A, B}` を保存する。

## TLCで検査する

TLA+ tools 1.8.0 の `tla2tools.jar` を用いる例:

```bash
cd /absolute/path/to/SwiftyGyaim/docs/formal/bug-005
curl -fL -o /tmp/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
java -jar /tmp/tla2tools.jar -noGenerateSpecTE \
  -metadir /tmp/tlc-bug-005-buggy \
  -config Buggy.cfg StudyDictLostUpdate.tla
java -jar /tmp/tla2tools.jar -noGenerateSpecTE \
  -metadir /tmp/tlc-bug-005-fixed \
  -config Fixed.cfg StudyDictLostUpdate.tla
```

`-metadir` で TLC の状態探索ファイルを作業ツリー外へ出し、`-noGenerateSpecTE` で反例用の一時spec生成を抑止する。

期待結果:

- `Buggy.cfg`: `Invariant NoLostUpdate is violated.` と反例トレースが出る
- `Fixed.cfg`: `Model checking completed. No error has been found.` と表示される

`Buggy.cfg` が非zeroで終了するのは、この教材では期待される検査結果である。

## モデルの境界

現行修正は **mtimeベースではない**。BUG-005の修正コミット `8233174` は `studyDict` をプロセス内 static 状態へ変更した。mtime無効化キャッシュは別件の BUG-027（`GyaimSettings`）である。

このモデルの fixed 側は、同一IMEプロセス内の `study()` action が直列に実行されることを仮定する。したがって次は証明していない。

- 複数のOSプロセスが同じ `studydict.txt` を更新する場合
- 複数スレッドが static `studyDict` を同時更新する場合
- mtimeを確認してから保存するまでの競合

特にmtime再検証だけでは、2者が同じmtimeを確認してから別々に書けるため、一般の lost update 防止にはならない。これらを保証するには、ファイルロック、世代番号付きcompare-and-swap、単一writerなど別の同期方式と、その方式を表す追加モデルが必要になる。

## 関連資料

- `docs/specs/bug-memory.md` — BUG-005
- `docs/specs/dictionary-system.md` — studyDict のプロセス内共有
- 修正コミット: `8233174`
