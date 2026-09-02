import XCTest

/// カスタムモデル選択（customModelPath）のテスト。
/// gyaim-lm等の自前GGUFを同梱zenzより優先してロードする経路と、
/// ログ集計用のモデルラベル導出を検証する。
final class ModelSelectionTests: XCTestCase {
    private var tempModelURL: URL!

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: BundledAIRerankModel.customModelPathKey)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempModelURL = dir.appendingPathComponent("gyaim-lm-small-public-v1-Q5_K_M.gguf")
        try Data("GGUF".utf8).write(to: tempModelURL)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: BundledAIRerankModel.customModelPathKey)
        try? FileManager.default.removeItem(at: tempModelURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testDefaultUsesBundledLabel() {
        XCTAssertNil(BundledAIRerankModel.customModelURL())
        XCTAssertEqual(BundledAIRerankModel.activeModelLabel, "bundled-zenz-v3.1-small")
    }

    func testCustomPathPreferredWhenFileExists() {
        UserDefaults.standard.set(tempModelURL.path, forKey: BundledAIRerankModel.customModelPathKey)
        XCTAssertEqual(BundledAIRerankModel.customModelURL()?.path, tempModelURL.path)
        XCTAssertEqual(BundledAIRerankModel.resolveModelURL(bundle: Bundle(for: type(of: self)))?.path,
                       tempModelURL.path)
        XCTAssertEqual(BundledAIRerankModel.activeModelLabel,
                       "custom-gyaim-lm-small-public-v1-Q5_K_M")
    }

    func testMissingCustomPathFallsBackToBundled() {
        UserDefaults.standard.set("/nonexistent/model.gguf", forKey: BundledAIRerankModel.customModelPathKey)
        XCTAssertNil(BundledAIRerankModel.customModelURL())
        XCTAssertEqual(BundledAIRerankModel.activeModelLabel, "bundled-zenz-v3.1-small")
        // テストバンドルには同梱GGUFが含まれるため、fallback解決が非nilであること
        XCTAssertNotNil(BundledAIRerankModel.resolveModelURL(bundle: Bundle(for: type(of: self))))
    }

    func testTildeExpansion() {
        UserDefaults.standard.set("~/nonexistent-gyaim-test.gguf", forKey: BundledAIRerankModel.customModelPathKey)
        // 存在しないのでnilだが、チルダ展開でクラッシュしないこと
        XCTAssertNil(BundledAIRerankModel.customModelURL())
    }
}
