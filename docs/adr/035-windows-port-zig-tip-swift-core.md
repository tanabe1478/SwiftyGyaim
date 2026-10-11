# ADR-035: Windows 版は Zig 製の TSF TIP と Swift 製の変換サーバに分けて移植する

## Status

Accepted (2026-10-11)

## Decision

Windows 版 Gyaim は別リポジトリ `tanabe1478/WinGyaim` で開発し、3 つのプロセスに分けて作る。`GyaimCore` が独立リポジトリになるまでは、WinGyaim が SwiftyGyaim を submodule として取り込み `path:` 依存で参照する。

| 部品 | 言語 / 技術 | 役割 |
|---|---|---|
| TIP DLL（Text Input Processor） | Zig 0.17 + zigwin32 | TSF の COM インターフェースを実装し、キーイベントの受信・composition の制御・候補ウィンドウ位置の取得だけを行う。全アプリのプロセス内にロードされるため依存ゼロで薄く保つ |
| 変換サーバ | Swift on Windows（swift.org 公式ツールチェーン） | 辞書検索・学習・heuristic / モデル rerank・Google 変換・候補ウィンドウの描画を担う常駐プロセス。Foundation だけに依存する既存の変換ロジックを `GyaimCore` パッケージとして切り出し、Mac 版と同じソースを使う |
| 設定画面・辞書エディタ | 別 exe（言語は TIP に揃えて Zig を第一候補） | `settings.json` を共有し、変更はパイプでサーバに通知する |

TIP とサーバは名前付きパイプで通信する。メッセージはキー入力、未確定文字列の更新、確定、候補一覧、設定リロード、バージョン確認の 6 種類程度に絞り、バージョン番号を持たせる。TSF 側は UTF-16、パイプ側は UTF-8 とし、変換は IPC 層で 1 回だけ行う。モデル採点は ADR-029 と同じくサーバで非同期に走らせ、結果はサーバから TIP へ押し込み、TIP は受信スレッドから TSF スレッドへ PostMessage して非同期の edit session で候補を差し替える。

モデル推論は llama.cpp を Vulkan バックエンドでビルドし、CPU フォールバックを持つ。GGUF（`gyaim-lm-small-public-v1`、Q5_K_M）はそのまま使う。C++ は採用しない。Rust も採用しない（Rust のコードを読み書きできる前提を置けないため）。

進め方は次の順とする。

1. `GyaimCore`（WordSearch、ConnectionDict、RomaKana、AIReranker、ContextDict、ZenzRuntime 系、GoogleTransliterate、GyaimSettings 等、Foundation 依存のみの約 5,000 行）を SwiftPM パッケージに切り出し、Mac 版もそれに依存させる。Windows の Swift ツールチェーンで `swift test` を通し、WordSearchTests と DictionarySearchGoldenTests を緑にする。llama.cpp の Vulkan ビルドを modulemap 経由でリンクし、採点が動くことを確認する。
2. 汎用 TSF TIP の PIME をそのまま入れ、Swift サーバを PIME のバックエンドとして接続してメモ帳で変換が動くことを確認する。Windows 上の辞書検索と採点の体感速度をここで測る。IPC 層は薄く分離し、PIME のプロトコルにサーバ設計を引きずられないようにする。
3. Zig で自前 TIP を書き、PIME を置き換える。順に、(a) DllRegisterServer と RegisterProfile だけの空 TIP が入力ソース一覧に出る、(b) ITfKeyEventSink でキーを拾い固定文字列を composition として挿入できる、(c) 名前付きパイプでサーバに接続する、(d) 候補ウィンドウ位置通知・UI-less モード（ITfCandidateListUIElement）・入力モードの compartments・Deactivate 時の確定（ADR-012 / 023 相当）を足す。
4. x86 / x64 / ARM64 のビルド、WiX v5 の MSI、Authenticode 署名を整える。

## Context

Gyaim は macOS 専用（InputMethodKit、AppKit）で、Windows 版の要望がある。コードベースを確認したところ、約 9,300 行のうち変換ロジックは Foundation だけに依存しており、macOS 固有なのは GyaimController（IMK）、4 つのウィンドウ、AppDelegate / main、SecureInputDiagnostics（Carbon / IOKit）、KeyBindings（NSEvent）、Crypt / ImageManager（CryptoKit）に限られる。モデル推論は llama.cpp の C API を xcframework 経由で呼んでいるだけで、Windows でも同じ GGUF が使える。学習・評価ツール（`Tools/decision-model`、`docs/gyaim-lm-windows-training-guide.md`）は既に Windows（Ryzen + Radeon RX 9070 XT）で運用している。

Windows の IME は TSF の TIP DLL として実装する必要があり、TIP は全アプリのプロセス内にロードされ、UWP の AppContainer ではファイルやネットワークのアクセスが制限される。71 MB のモデルと 14 MB の辞書を全アプリに読み込ませられないため、Mozc や Microsoft IME と同じく「薄い TIP + 別プロセスの変換サーバ」の構成が前提になる。現在の Mac 版も IMKServer 経由の別プロセス構成なので、構造は変わらない。

TIP の実装言語は、ランタイムを持ち込まず C ABI の COM を実装できるものに限られる。参考実装（Microsoft の SampleIME、Mozc、Weasel、PIME）はすべて C++ だが、C++ は採用したくないという方針があり、Rust は読み書きの前提を置けない。

## Consideration

TIP の言語について。

- C++（MSVC）: 参考実装が最も多く最も低リスクだが、言語として採用しない方針のため不採用。
- Rust + windows-rs: saschanaz/ime-rs（SampleIME の移植）、unispim-rs などの実例があり、`#[implement]` マクロで COM 実装が省力化でき、panic を `catch_unwind` で捕捉できる唯一の選択肢。技術的には最有力だったが、コードを読めないという理由で不採用。
- Zig + zigwin32（採用）: zigwin32 は windows-rs と同じ win32metadata から生成され、`ui.text_services` に TSF の全インターフェースの vtable 構造体がある。ランタイムゼロ、`zig build -Dtarget=...` だけで x86 / x64 / ARM64 を Mac からクロスコンパイルでき、Windows SDK も Visual Studio も要らない（COM は C ABI なので gnu ターゲットでよい）。署名も osslsigncode で Mac から打てる。欠点は、TSF の実装例が見つからないこと、unwinding がなく panic から回復できないこと、pre-1.0 で半年ごとに破壊的変更があること（0.16 で `@cImport` 非推奨、0.17 で削除）、COM 実装のマクロがなく vtable 組み立てのヘルパを自作すること。
- Swift（swift-com）: Swift ランタイム DLL 群が全アプリのプロセスに入り、x86 ターゲットがない。不採用。
- C# NativeAOT（`GeneratedComClass` + `UnmanagedCallersOnly`）: CLR なしの COM DLL は作れるが、TSF インターフェースを ComWrappers 互換で用意する手間、全プロセスに数 MB のランタイムと GC が載ること、x86 非対応、前例がほぼないことから不採用。
- PIME（汎用 TIP + 外部バックエンド）: 自分で C++ を書かずに済み、バックエンドは任意の言語でよい。候補ウィンドウの見た目と IPC プロトコルが固定され、保守が止まる可能性がある（最終更新は約 11 か月前）ため、最終形ではなく手順 2 のスパイクにだけ使う。

変換サーバの言語について。

- Swift on Windows（採用）: 既存の変換ロジックと 300 超のテストをそのまま持ち込め、Mac 側の辞書・rerank の改良（ADR-030〜034 など）が Windows にも自動的に反映される。Windows のツールチェーンは Visual Studio Build Tools 込みで数 GB あり、成熟度が最大の不確定要素なので、手順 1 を最初に置いて検証する。直す箇所は `os.Logger` の抽象化、CryptoKit から swift-crypto への差し替え、KeyBindings の NSEvent 依存のプラットフォーム非依存化の 3 点に限られる見込み。
- 全部 Zig: 日本語文字列処理が低レベル（UTF-8 のバイトスライス）になり、辞書・rerank を丸ごと書き直すことになる。不採用。
- 全部 Rust: ツールチェーンを 1 つにできるが、Rust を採用しない方針と矛盾する。不採用。

言語とプロセスをまたぐオーバーヘッドについて。ローカルの名前付きパイプの往復と小さな JSON の変換は 0.1 ms 未満で、辞書検索の数 ms（ADR-033 / 034）、1 打鍵の体感予算 16 ms に対して無視できる。プロセス分離は言語に関係なく必須なので、言語境界が足す実行時コストは実質ない。開発側のコストは、ツールチェーンが 2 つになること、境界をまたぐデバッグ、プロトコルの契約化で、相関 ID 付きのログ（FastContextTrace の拡張）とフィクスチャ化した往復サンプルで対処する。

## Consequences

- Mac 版と Windows 版が変換ロジックを `GyaimCore` で共有し、ゴールデンテストと typing corpus（`Tools/eval`）が両プラットフォームで同じ結果を保証する。Mac 版の IME 本体は `GyaimCore` に依存する形にリファクタリングされる。
- TIP は 2〜3 千行程度の TSF 配管で、固まった後はほとんど変更されない。頻繁に手が入るのはサーバ側の Swift に集中する。
- Zig の panic はホストアプリ（Word やブラウザ）ごと落とす。TIP 内は error union のみで書き、ReleaseSafe でビルドし、カスタム panic ハンドラでクラッシュログを書いて TIP 無効化フラグを立てる。それでも当該スレッドは止まるため、この点では C++ と同等、Rust より劣る。
- Zig と zigwin32、translate-c パッケージのバージョンを固定し、Zig 本体の新版への追従は年 1 回まとめて行う。新版リリース直後は zigwin32 の追従を待つ期間が生じ得る。
- サーバが落ちてもホストアプリは無傷で、TIP は再接続するだけで済む。サーバはログイン時に常駐起動し、TIP は未接続ならサーバを起動しつつキーを素通しにして最初の一打を固めない。
- 32 bit アプリ向けに x86 版 TIP が必要になるが、Zig のクロスコンパイルで同じソースから出せる。
- Secure Event Input 診断（IOKit / Carbon）は Windows に相当概念がなく、パスワード欄は TSF の InputScope で判定するため Windows 版では持たない。クリップボード候補は Win32 クリップボード API、選択テキスト候補は ITfContext::GetSelection で実現できる。
- E2E テストは CGEvent + TextEdit の代わりに SendInput + メモ帳 + UI Automation で組む。TSF の統合テストホスト（ITfThreadMgr を自前で起動する）は重いので後回しにする。
- Windows 向けの CI は Zig（クロスコンパイルなら Mac ランナーでも可）と Swift on Windows（Windows ランナー必須）の 2 系統になる。
- ADR-034 で「ADR-035 予定」としていたモデル生成による語彙補完は、次の番号（ADR-036 以降）で記録する。
- 手順 1 の実装（2026-10-11）: `Packages/GyaimCore` に Foundation 依存のみの 27 ファイルと 26 テストスイートを移した。Mac アプリと Xcode の test target は当面この同じソースを自モジュールにコンパイルし（project.yml の sources に追加。二重ビルド）、`Package.swift` は `swift test` と Windows / Linux 用。public API 化とモジュール依存化は Windows サーバの着手時に行う。Windows の Swift 6.4 で 183 テストが通った。
- 移植で必要だった修正は 5 点: `os.Logger` の条件コンパイル、`URLSession` の `FoundationNetworking`、`CFAbsoluteTimeGetCurrent` → `Date().timeIntervalSinceReferenceDate`、辞書パーサの CRLF 耐性（autocrlf の checkout で `dict.txt` が CRLF になり、末尾フィールドの CR で合成候補が全滅した）、Mach API のメモリ計測を Darwin 限定に。リポジトリに `.gitattributes`（`* text=auto eol=lf`）を追加した。
- CI に ubuntu / windows で `swift test --package-path GyaimSwift/Packages/GyaimCore` を走らせるジョブを追加し、コアへの AppKit / IMK 混入を検出する。

## References

- Microsoft Learn: [ITfTextInputProcessorEx](https://learn.microsoft.com/en-us/windows/win32/api/msctf/nn-msctf-itftextinputprocessorex)、[DllGetClassObject](https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-dllgetclassobject)
- Zig: [0.17.0 Release Notes](https://ziglang.org/download/0.17.0/release-notes.html)、[0.16.0 Release Notes](https://ziglang.org/download/0.16.0/release-notes.html)
- zigwin32: https://github.com/marlersoft/zigwin32
- Rust の参考実装（読み替え用）: [saschanaz/ime-rs](https://github.com/saschanaz/ime-rs)、[bipinnatus2k/unispim-rs](https://github.com/bipinnatus2k/unispim-rs)
- PIME: https://github.com/EasyIME/PIME
- Mozc の TIP / サーバ分離構成: https://github.com/google/mozc
- 関連 ADR: ADR-012（切替時の確定）、ADR-023（非表示英数モード）、ADR-029（非同期モデルレビュー）、ADR-033 / 034（辞書）
- Windows での学習基盤: `GyaimSwift/Tools/decision-model/README.md`、`docs/gyaim-lm-windows-training-guide.md`
