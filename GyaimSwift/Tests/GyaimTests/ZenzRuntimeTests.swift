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

    func testExactHomophoneCandidateIndicesSelectsProtectedExactCandidatesOnly() {
        let request = makeExactHomophoneRequest(context: "どちらの")

        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request,
                                                                        localOrder: [0, 1, 2])

        // 向こう (prefix prediction) must never enter the comparison set.
        XCTAssertEqual(indices, [0, 1])
    }

    func testExactHomophoneCandidateIndicesRespectsLocalOrderAndLimit() {
        let request = makeExactHomophoneRequest(context: "どちらの")

        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request,
                                                                        localOrder: [1, 0, 2],
                                                                        limit: 1)

        XCTAssertEqual(indices, [1])
    }

    func testExactHomophoneCandidateIndicesExcludesIncompleteHiraganaISuffixRegression() {
        let request = makeKudasaRegressionRequest()

        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request,
                                                                        localOrder: [2, 1, 0])

        // くださ (index 1) is a truncation of ください (index 0) and must be
        // excluded, while ください and 下さ can still be compared.
        XCTAssertFalse(indices.contains(1))
        XCTAssertTrue(indices.contains(0))
        XCTAssertTrue(indices.contains(2))
    }

    func testExactHomophoneCandidateIndicesAllowsOtherHiraganaShortening() {
        let request = makeTameniRequest()

        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request,
                                                                        localOrder: [0, 1, 2])

        // ため / ために is a legitimate shortening, not a broken stem.
        XCTAssertEqual(indices, [0, 1, 2])
    }

    func testSelectExactHomophoneWinnerRequiresMargin() {
        // Winner must beat the current best by at least the margin.
        XCTAssertEqual(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -2.0, 1: -1.0],
                                                                     currentBest: 0,
                                                                     margin: 0.10), 1)
        XCTAssertNil(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -1.05, 1: -1.0],
                                                                   currentBest: 0,
                                                                   margin: 0.10))
        // Current best already winning → no change.
        XCTAssertNil(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -1.0, 1: -2.0],
                                                                   currentBest: 0,
                                                                   margin: 0.10))
        // Missing score for the current best → cannot compare safely.
        XCTAssertNil(BundledZenzRuntime.selectExactHomophoneWinner(scores: [1: -1.0],
                                                                   currentBest: 0,
                                                                   margin: 0.10))
    }

    func testSelectExactHomophoneWinnerRespectsAffinityAdvantage() {
        // Dogfood 2026-07-14: the model demoted user-learned homophones
        // (使用 over learned 仕様) when context matched only partially.
        // An affinity advantage on the current best raises the required
        // log-probability margin (affinity 0.5 → +1.0 at weight 2.0).
        let scores: [Int: Double] = [0: -2.0, 1: -1.2]

        // Without affinity, a 0.8 advantage clears the 0.10 margin.
        XCTAssertEqual(BundledZenzRuntime.selectExactHomophoneWinner(scores: scores,
                                                                     currentBest: 0,
                                                                     margin: 0.10), 1)
        // The user's partial-context history on the best blocks the override.
        XCTAssertNil(BundledZenzRuntime.selectExactHomophoneWinner(scores: scores,
                                                                   currentBest: 0,
                                                                   margin: 0.10,
                                                                   affinities: [0: 0.5]))
        // A decisive model advantage can still win past the history.
        XCTAssertEqual(BundledZenzRuntime.selectExactHomophoneWinner(scores: [0: -3.5, 1: -1.2],
                                                                     currentBest: 0,
                                                                     margin: 0.10,
                                                                     affinities: [0: 0.5]), 1)
        // Affinity on the winner itself does not raise the bar.
        XCTAssertEqual(BundledZenzRuntime.selectExactHomophoneWinner(scores: scores,
                                                                     currentBest: 0,
                                                                     margin: 0.10,
                                                                     affinities: [1: 0.5]), 1)
    }

    func testSelectExactHomophoneWinnerPicksHighestScoreAmongMany() {
        let scores: [Int: Double] = [0: -3.0, 1: -1.5, 2: -0.5]

        XCTAssertEqual(BundledZenzRuntime.selectExactHomophoneWinner(scores: scores,
                                                                     currentBest: 0,
                                                                     margin: 0.10), 2)
    }

    func testExactHomophoneCandidateIndicesExcludesRawKanaSpelling() {
        // BUG-024: the char-level LM promoted "こみ" over "込み" and "いっか"
        // over "一家". The raw kana spelling of the input must not enter the
        // comparison unless it is already the best.
        let request = makeKanaBiasRequest()

        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request,
                                                                        localOrder: [0, 1, 2])

        XCTAssertEqual(indices, [0, 2])
    }

    func testExactHomophoneCandidateIndicesKeepsRawKanaSpellingWhenItIsBest() {
        // When the user's own history made the kana spelling the best, kanji
        // homophones can still be compared against (and promoted over) it.
        let request = makeKanaBiasRequest()

        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request,
                                                                        localOrder: [1, 0, 2])

        XCTAssertEqual(indices, [1, 0, 2])
    }

    func testExactHomophoneCandidateIndicesIncludesKanaEquivalentReadingVariant() {
        // BUG-026: 更新 (study reading "kousinn") is the same kana reading as
        // typed "kousin" and must join the homophone comparison against 行進.
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "kousin",
            hiragana: "こうしん",
            context: "アプリを",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "行進",
                                  reading: "kousin",
                                  source: "study",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "更新",
                                  reading: "kousinn",
                                  source: "study",
                                  kind: "exact"),
                AIRerankCandidate(index: 2,
                                  text: "こうしんして",
                                  reading: "kousinsite",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )

        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request,
                                                                        localOrder: [0, 1, 2])

        XCTAssertEqual(indices, [0, 1])
    }

    func testExactHomophoneCandidateIndicesKeepsHiraganaWordThatIsNotRawSpelling() {
        // "ください" (input kudasa → raw spelling くださ) is a legitimate
        // hiragana word and must stay comparable (BUG-022 regression intent).
        let request = makeKudasaRegressionRequest()

        let indices = BundledZenzRuntime.exactHomophoneCandidateIndices(request: request,
                                                                        localOrder: [2, 1, 0])

        XCTAssertTrue(indices.contains(0))
    }

    func testSingleCharacterPrefixPromotesExactTextMatchOnly() {
        // Dogfood 2026-07-05: ~48% of normal reviews ended kept-local on
        // single-kanji prefixes like "書". Allow only the exact-text,
        // exact-reading candidate for a 1-char prefix.
        let request = makeSingleKanjiRequest()

        XCTAssertEqual(BundledZenzRuntime.fastContextReplacementIndex(forFixRequiredPrefix: "書",
                                                                      localOrder: [0, 1, 2],
                                                                      request: request), 1)
        // hasPrefix-style matches (書き) must not be promoted from a 1-char prefix.
        XCTAssertNil(BundledZenzRuntime.fastContextReplacementIndex(forFixRequiredPrefix: "描",
                                                                    localOrder: [0, 1, 2],
                                                                    request: request))
    }

    func testSingleCharacterPrefixRejectsNonProtectedExactTextMatch() {
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "kak",
            hiragana: "かk",
            context: "文脈あり",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "書く",
                                  reading: "kaku",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 1,
                                  text: "書",
                                  reading: "kaku",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )

        // "書" has reading "kaku" != inputPat "kak" → not protected exact → nil.
        XCTAssertNil(BundledZenzRuntime.fastContextReplacementIndex(forFixRequiredPrefix: "書",
                                                                    localOrder: [0, 1],
                                                                    request: request))
    }

    func testRankConstrainedSurfacesOrdersByScoreWithStableTies() {
        // Issue #59 / ADR-022: highest conditional log probability first;
        // ties keep the dictionary enumeration order.
        let ranked = BundledZenzRuntime.rankConstrainedSurfaces([
            (surface: "教会線", score: -3.0),
            (surface: "境界線", score: -0.5),
            (surface: "協会線", score: -3.0),
        ])

        XCTAssertEqual(ranked, ["境界線", "教会線", "協会線"])
        XCTAssertEqual(BundledZenzRuntime.rankConstrainedSurfaces([]), [])
    }

    func testShouldRunNormalReviewRequiresMinimumInputLength() {
        // Dogfood 2026-07-08: normal reviews at input length 4 produced 81
        // events with 0 fixes. The homophone path keeps its own (shorter) gate.
        XCTAssertFalse(BundledZenzRuntime.shouldRunNormalReview(inputPat: "sima", minimumLength: 5))
        XCTAssertTrue(BundledZenzRuntime.shouldRunNormalReview(inputPat: "surun", minimumLength: 5))
        XCTAssertTrue(BundledZenzRuntime.shouldRunNormalReview(inputPat: "sima", minimumLength: 4))
    }

    func testShouldSkipHomophoneReviewForAffinity() {
        let strongAffinity = AIRerankCandidate(index: 0,
                                               text: "向き",
                                               reading: "muki",
                                               source: "study",
                                               kind: "exact",
                                               contextAffinity: 0.75)
        let weakAffinity = AIRerankCandidate(index: 0,
                                             text: "向き",
                                             reading: "muki",
                                             source: "study",
                                             kind: "exact",
                                             contextAffinity: 0.5)
        let noAffinity = AIRerankCandidate(index: 0,
                                           text: "向き",
                                           reading: "muki",
                                           source: "study",
                                           kind: "exact")

        XCTAssertTrue(BundledZenzRuntime.shouldSkipHomophoneReviewForAffinity(best: strongAffinity,
                                                                              threshold: 0.75))
        XCTAssertFalse(BundledZenzRuntime.shouldSkipHomophoneReviewForAffinity(best: weakAffinity,
                                                                               threshold: 0.75))
        XCTAssertFalse(BundledZenzRuntime.shouldSkipHomophoneReviewForAffinity(best: noAffinity,
                                                                               threshold: 0.75))
        XCTAssertFalse(BundledZenzRuntime.shouldSkipHomophoneReviewForAffinity(best: strongAffinity,
                                                                               threshold: 0))
    }

    private func makeKanaBiasRequest() -> AIRerankRequest {
        AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "komi",
            hiragana: "こみ",
            context: "レビューして",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "込み",
                                  reading: "komi",
                                  source: "study",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "こみ",
                                  reading: "komi",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 2,
                                  text: "混み",
                                  reading: "komi",
                                  source: "connection",
                                  kind: "exact")
            ]
        )
    }

    private func makeSingleKanjiRequest() -> AIRerankRequest {
        AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "kaku",
            hiragana: "かく",
            context: "文脈あり",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "書く",
                                  reading: "kakutei",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 1,
                                  text: "書",
                                  reading: "kaku",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 2,
                                  text: "書き",
                                  reading: "kaki",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )
    }

    func testShouldReviewExactHomophonesRequiresContextAndAlternative() {
        let request = makeExactHomophoneRequest(context: "どちらの")
        let best = request.candidates[0]

        XCTAssertTrue(BundledZenzRuntime.shouldReviewExactHomophones(best: best,
                                                                     request: request,
                                                                     localOrder: [0, 1, 2]))
        XCTAssertFalse(BundledZenzRuntime.shouldReviewExactHomophones(best: best,
                                                                      request: makeExactHomophoneRequest(context: ""),
                                                                      localOrder: [0, 1, 2]))
        XCTAssertFalse(BundledZenzRuntime.shouldReviewExactHomophones(best: best,
                                                                      request: request,
                                                                      localOrder: [0, 2]))
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

    private func makeExactHomophoneRequest(context: String) -> AIRerankRequest {
        AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "muki",
            hiragana: "むき",
            context: context,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "無機",
                                  reading: "muki",
                                  source: "study",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "向き",
                                  reading: "muki",
                                  source: "study",
                                  kind: "exact"),
                AIRerankCandidate(index: 2,
                                  text: "向こう",
                                  reading: "mukou",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )
    }

    private func makeKudasaRegressionRequest() -> AIRerankRequest {
        AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "kudasa",
            hiragana: "くださ",
            context: "文脈あり",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "ください",
                                  reading: "kudasa",
                                  source: "connection",
                                  kind: "compound"),
                AIRerankCandidate(index: 1,
                                  text: "くださ",
                                  reading: "kudasa",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 2,
                                  text: "下さ",
                                  reading: "kudasa",
                                  source: "connection",
                                  kind: "exact")
            ]
        )
    }

    private func makeTameniRequest() -> AIRerankRequest {
        AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "tameni",
            hiragana: "ために",
            context: "文脈あり",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "ために",
                                  reading: "tameni",
                                  source: "connection",
                                  kind: "compound"),
                AIRerankCandidate(index: 1,
                                  text: "ため",
                                  reading: "tameni",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 2,
                                  text: "溜めに",
                                  reading: "tameni",
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
