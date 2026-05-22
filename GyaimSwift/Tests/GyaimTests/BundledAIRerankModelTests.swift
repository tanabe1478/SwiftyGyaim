@testable import Gyaim
import XCTest

final class BundledAIRerankModelTests: XCTestCase {
    func testBundledModelResourceExists() throws {
        let url = try XCTUnwrap(BundledAIRerankModel.resolveModelURL(bundle: Bundle(for: type(of: self))))
        XCTAssertEqual(url.lastPathComponent, "ggml-model-Q5_K_M.gguf")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertGreaterThan(size?.intValue ?? 0, 1_000_000)
    }
}
