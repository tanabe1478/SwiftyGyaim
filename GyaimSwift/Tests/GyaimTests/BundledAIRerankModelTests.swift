@testable import Gyaim
import XCTest

final class BundledAIRerankModelTests: XCTestCase {
    /// 同梱モデルは公開データのみで学習した gyaim-lm-small-public-v1（再配布可）。
    /// ドメインデータ入りモデル（v2以降）は同梱せず customModelPath で指定する。
    func testBundledModelResourceExists() throws {
        UserDefaults.standard.removeObject(forKey: BundledAIRerankModel.customModelPathKey)
        let url = try XCTUnwrap(BundledAIRerankModel.resolveModelURL(bundle: Bundle(for: type(of: self))))
        XCTAssertEqual(url.lastPathComponent, "ggml-model-Q5_K_M.gguf")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 1_000_000)
    }
}
