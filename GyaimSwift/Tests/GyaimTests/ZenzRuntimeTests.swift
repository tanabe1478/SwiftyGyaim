@testable import Gyaim
import XCTest

private struct StubZenzRuntime: ZenzRuntime {
    let identifier = "stub-zenz"
    let status: ZenzRuntimeStatus
    let response: AIRerankResponse?

    func prepare() -> ZenzRuntimeStatus { status }
    func rerank(_ request: AIRerankRequest) -> AIRerankResponse? { response }
}

final class ZenzRuntimeTests: XCTestCase {
    func testRuntimeStatusReadiness() {
        XCTAssertTrue(ZenzRuntimeStatus.ready.isReady)
        XCTAssertFalse(ZenzRuntimeStatus.unavailable("missing").isReady)
    }

    func testBundledZenzBackendUsesRuntimeResponseWhenAvailable() {
        let expected = AIRerankResponse(order: [1, 0], scores: ["1": 1.0], model: "stub-llama")
        let backend = BundledZenzAIRerankBackend(runtime: StubZenzRuntime(status: .ready, response: expected))

        XCTAssertEqual(backend.rerank(makeRequest()), expected)
    }

    func testBundledZenzBackendFallsBackToHeuristicWhenRuntimeDoesNotScoreYet() {
        let backend = BundledZenzAIRerankBackend(runtime: StubZenzRuntime(status: .ready, response: nil))
        let response = backend.rerank(makeRequest())

        XCTAssertEqual(response.order.first, 1)
        XCTAssertEqual(response.model, "swift-local-heuristic+bundled-zenz-v3.1-xsmall-mapped")
    }

    func testFastContextReplacementRejectsSingleCharacterPrefix() {
        let request = makeFastContextRequest()

        let replacement = BundledZenzRuntime.fastContextReplacementIndex(forFixRequiredPrefix: "高",
                                                                         localOrder: [0, 1, 2],
                                                                         request: request)

        XCTAssertNil(replacement)
    }

    func testFastContextReplacementUsesMultiCharacterPrefix() {
        let request = makeFastContextRequest()

        let replacement = BundledZenzRuntime.fastContextReplacementIndex(forFixRequiredPrefix: "高品",
                                                                         localOrder: [0, 1, 2],
                                                                         request: request)

        XCTAssertEqual(replacement, 1)
    }

    func testFastContextReplacementDoesNotReturnCurrentBest() {
        let request = makeFastContextRequest()

        let replacement = BundledZenzRuntime.fastContextReplacementIndex(forFixRequiredPrefix: "候補",
                                                                         localOrder: [0, 1, 2],
                                                                         request: request)

        XCTAssertNil(replacement)
    }

    private func makeRequest() -> AIRerankRequest {
        AIRerankRequest(
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
    }

    private func makeFastContextRequest() -> AIRerankRequest {
        AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "kouh",
            hiragana: "こうほ",
            context: "文脈あり",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "候補",
                                  reading: "kouho",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 1,
                                  text: "高品質",
                                  reading: "kouhinshitsu",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 2,
                                  text: "こうほ",
                                  reading: "kouho",
                                  source: "synthetic",
                                  kind: "kana")
            ]
        )
    }
}
