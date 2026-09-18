# BUG-007: ローカルXcodeでGyaimTests.xctestを読み込めない

- **発見日**: 2026-05-05
- **症状**: ローカル環境で `xcodebuild -project Gyaim.xcodeproj -scheme GyaimTests -derivedDataPath .build test` を実行すると、`GyaimTests.xctest` の `Contents/MacOS/GyaimTests` は存在するにもかかわらず `Cannot find executable for CFBundle` / `Failed to load the test bundle` で失敗する
- **影響**: ローカルでユニットテストが実行できず、修正確認が困難になる。GitHub Actions では通る場合があり、環境差分として見落としやすい
- **原因**:
  - XcodeGen生成プロジェクトでテストターゲットにもアプリ用 `Resources/Info.plist` が `INFOPLIST_FILE` として入っており、テストバンドルにIMEアプリ用のInfo.plistキーが混入していた
  - ローカルmacOS/Xcodeの組み合わせで生成直後の `.xctest` に `com.apple.provenance` 拡張属性が付き、`xcodebuild test` のローダーが実行ファイルなしとして誤報するケースがある
- **修正**:
  - `project.yml` の `GyaimTests` / `GyaimE2ETests` に `INFOPLIST_FILE: ""` を明示し、生成Info.plistだけを使う
  - `Scripts/run-unit-tests.sh` を追加し、`build-for-testing` → `.xctest` のxattrクリア → `xcrun xctest` の順で実行する
  - CI/Release workflow と agent向けテストコマンドを新スクリプトへ更新
- **検証**: `./Scripts/run-unit-tests.sh` で 222 tests / 0 failures を確認
- **教訓**:
  - 「実行ファイルが見つからない」エラーでも、実際にはInfo.plist混入や拡張属性が原因のローダー失敗である場合がある
  - XcodeGenでアプリソース/リソースをテストターゲットにも含める場合、アプリ用Info.plistをテストバンドルに流用しないこと
  - macOSのローカルセキュリティ属性に起因するテスト実行問題は、`build-for-testing` と `xcrun xctest` の分離で切り分けやすい
