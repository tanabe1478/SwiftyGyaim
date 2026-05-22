@testable import Gyaim
import XCTest

final class InProcessAIRerankerTests: XCTestCase {
    func testInProcessRerankerReturnsBundledModelMappedLabelWhenResourceExists() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "henkan",
            hiragana: "へんかん",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "henkan",
                                  reading: "henkan",
                                  source: "synthetic",
                                  kind: "raw"),
                AIRerankCandidate(index: 1,
                                  text: "変換",
                                  reading: "henkan",
                                  source: "connection",
                                  kind: "exact")
            ]
        )

        let reranker = InProcessAIReranker(bundle: Bundle(for: type(of: self)))
        let response = reranker.rerank(request)
        XCTAssertEqual(response.order.first, 1)
        XCTAssertEqual(response.model, "swift-local-heuristic+bundled-zenz-v3.1-xsmall-mapped")
    }
}
