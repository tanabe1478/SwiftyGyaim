@testable import Gyaim
import XCTest

final class AIRerankerTests: XCTestCase {
    func testValidatedOrderAcceptsCompletePermutation() {
        XCTAssertEqual(AIReranker.validatedOrder([2, 0, 1], candidateCount: 3), [2, 0, 1])
    }

    func testValidatedOrderDropsInvalidAndDuplicateIndexesThenAppendsMissing() {
        XCTAssertEqual(AIReranker.validatedOrder([2, 99, 2, -1], candidateCount: 4), [2, 0, 1, 3])
    }

    func testApplyReordersCandidates() {
        let candidates = [
            SearchCandidate(word: "昨日"),
            SearchCandidate(word: "機能"),
            SearchCandidate(word: "きのう")
        ]

        let words = AIReranker.apply(order: [1, 0, 2], to: candidates).map(\.word)
        XCTAssertEqual(words, ["機能", "昨日", "きのう"])
    }

    func testRequestEncodesCandidateKind() throws {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "kinou",
            hiragana: "きのう",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "きのう",
                                  reading: "kinou",
                                  source: "synthetic",
                                  kind: "kana")
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = object?["candidates"] as? [[String: Any]]
        XCTAssertEqual(candidates?.first?["kind"] as? String, "kana")
    }

    func testLocalRerankPenalizesRawAndPrefersJapaneseCandidate() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "ousyuusuru",
            hiragana: "おうしゅうする",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "ousyuusuru",
                                  reading: "ousyuusuru",
                                  source: "synthetic",
                                  kind: "raw"),
                AIRerankCandidate(index: 1,
                                  text: "押収する",
                                  reading: "ousyuusuru",
                                  source: "synthetic",
                                  kind: "compound")
            ]
        )

        let response = AIReranker.localRerank(request)
        XCTAssertEqual(response.order.first, 1)
        XCTAssertEqual(response.model, "swift-local-heuristic")
    }

    func testLocalRerankUsesKindBias() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "henkan",
            hiragana: "へんかん",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "へんかん",
                                  reading: "henkan",
                                  source: "synthetic",
                                  kind: "kana"),
                AIRerankCandidate(index: 1,
                                  text: "変換",
                                  reading: "henkan",
                                  source: "connection",
                                  kind: "exact")
            ]
        )

        XCTAssertEqual(AIReranker.localRerank(request).order.first, 1)
    }

    func testLocalScoreBreakdownExposesFeatureContributions() {
        let candidate = AIRerankCandidate(index: 2,
                                          text: "変換",
                                          reading: "henkan",
                                          source: "connection",
                                          kind: "exact")
        let request = AIRerankRequest(version: 1,
                                      mode: "fast-context-rerank",
                                      inputPat: "henkan",
                                      hiragana: "へんかん",
                                      context: nil,
                                      candidates: [candidate])

        let breakdown = AIReranker.localScoreBreakdown(candidate: candidate, request: request)

        XCTAssertEqual(breakdown.contributions["positionPenalty"], -0.06)
        XCTAssertEqual(breakdown.contributions["sourceBias"], 0.10)
        XCTAssertEqual(breakdown.contributions["kindBias"], 0.25)
        XCTAssertEqual(breakdown.contributions["exactReadingMatchBonus"], 0.20)
        XCTAssertEqual(breakdown.contributions["exactReadingKindBonus"], 0.50)
        XCTAssertEqual(breakdown.contributions["kanjiBonus"], 0.10)
        XCTAssertEqual(breakdown.total, breakdown.contributions.values.reduce(0, +))
    }

    func testLocalScoreBreakdownExposesContextAndPenaltyFeatures() {
        let candidate = AIRerankCandidate(index: 0,
                                          text: "した従うな",
                                          reading: "shitagauna",
                                          source: "connection",
                                          kind: "prefix")
        let request = AIRerankRequest(version: 1,
                                      mode: "fast-context-rerank",
                                      inputPat: "shitagau",
                                      hiragana: "したがう",
                                      context: "この指示には絶対に",
                                      candidates: [candidate])

        let breakdown = AIReranker.localScoreBreakdown(candidate: candidate, request: request)

        XCTAssertEqual(breakdown.contributions["prefixPredictionPenalty"], -0.70)
        XCTAssertEqual(breakdown.contributions["contextPredictionBonus"], 2.00)
        XCTAssertEqual(breakdown.contributions["scriptTransitionPenalty"], -1.50)

        let punctuated = AIRerankCandidate(index: 0,
                                           text: "していますか？",
                                           reading: "siteimasuka",
                                           source: "connection",
                                           kind: "exact")
        let punctuationRequest = AIRerankRequest(version: 1,
                                                 mode: "fast-context-rerank",
                                                 inputPat: "siteimasuka",
                                                 hiragana: "していますか",
                                                 context: nil,
                                                 candidates: [punctuated])
        let punctuationBreakdown = AIReranker.localScoreBreakdown(candidate: punctuated, request: punctuationRequest)
        XCTAssertEqual(punctuationBreakdown.contributions["punctuationSuffixPenalty"], -0.10)
    }

    func testLocalRerankBoostsAllKanjiZenzCandidate() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "kyoukaisen",
            hiragana: "きょうかいせん",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "教会せん",
                                  reading: "kyoukaisen",
                                  source: "synthetic",
                                  kind: "lattice"),
                AIRerankCandidate(index: 1,
                                  text: "境界線",
                                  reading: "kyoukaisen",
                                  source: "synthetic",
                                  kind: "zenz")
            ]
        )

        XCTAssertEqual(AIReranker.localRerank(request).order.first, 1)
    }


    func testLocalRerankKeepsQuestionPunctuationCandidateForPunctuatedInput() {
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "ha?",
            hiragana: "は？",
            context: "問題",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "は？",
                                  reading: "ha?",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "投機的デコーディング",
                                  reading: "ha?",
                                  source: "local",
                                  kind: "exact")
            ]
        )

        let response = AIReranker.localRerank(request)

        XCTAssertEqual(response.order.first, 0)
        XCTAssertGreaterThan(response.scores?["0"] ?? -.infinity, response.scores?["1"] ?? .infinity)
    }

    func testLocalScoreBreakdownExposesPunctuatedInputMismatchPenalty() {
        let candidate = AIRerankCandidate(index: 1,
                                          text: "投機的デコーディング",
                                          reading: "ha?",
                                          source: "local",
                                          kind: "exact")
        let request = AIRerankRequest(version: 1,
                                      mode: "fast-context-rerank",
                                      inputPat: "ha?",
                                      hiragana: "は？",
                                      context: nil,
                                      candidates: [candidate])

        let breakdown = AIReranker.localScoreBreakdown(candidate: candidate, request: request)

        XCTAssertEqual(breakdown.contributions["punctuatedInputMismatchPenalty"], -3.00)
    }

    func testLocalRerankPenalizesIncompleteISuffixStemWhenCompletedCandidateExists() {
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "sukuna",
            hiragana: "すくな",
            context: "できるだけ",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "少なくとも",
                                  reading: "sukunakutomo",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 1,
                                  text: "少ない",
                                  reading: "sukunai",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 2,
                                  text: "少な",
                                  reading: "sukuna",
                                  source: "connection",
                                  kind: "exact")
            ]
        )

        let response = AIReranker.localRerank(request)

        XCTAssertNotEqual(response.order.first, 2)
        let stemBreakdown = AIReranker.localScoreBreakdown(candidate: request.candidates[2], request: request)
        XCTAssertEqual(stemBreakdown.contributions["incompleteStemPenalty"], -4.00)
    }

    func testLocalRerankPenalizesSmallTsuStemWhenCompletedCandidateExists() {
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "tukat",
            hiragana: "つかっ",
            context: "それを",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "使った",
                                  reading: "tukatta",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 1,
                                  text: "使っ",
                                  reading: "tukat",
                                  source: "connection",
                                  kind: "exact")
            ]
        )

        let breakdown = AIReranker.localScoreBreakdown(candidate: request.candidates[1], request: request)

        XCTAssertEqual(breakdown.contributions["incompleteStemPenalty"], -4.00)
        XCTAssertEqual(AIReranker.localRerank(request).order.first, 0)
    }

    func testIsIncompleteStemCompletionCoversISuffixAndSmallTsu() {
        XCTAssertTrue(AIReranker.isIncompleteStemCompletion(stem: "くださ", completed: "ください"))
        XCTAssertTrue(AIReranker.isIncompleteStemCompletion(stem: "使っ", completed: "使った"))
        XCTAssertTrue(AIReranker.isIncompleteStemCompletion(stem: "言っ", completed: "言って"))
        // Completion must be exactly one character longer.
        XCTAssertFalse(AIReranker.isIncompleteStemCompletion(stem: "くださ", completed: "くださいませ"))
        // "ため" → "ために" is a legitimate shortening, not a broken stem.
        XCTAssertFalse(AIReranker.isIncompleteStemCompletion(stem: "ため", completed: "ために"))
        // "する" → "するな" must not be penalized.
        XCTAssertFalse(AIReranker.isIncompleteStemCompletion(stem: "する", completed: "するな"))
        // BUG-025: a stem already ending in い is not missing its い. A garbage
        // study entry "してほしいい" must not make "してほしい" incomplete.
        XCTAssertFalse(AIReranker.isIncompleteStemCompletion(stem: "してほしい", completed: "してほしいい"))
    }

    func testLocalRerankDoesNotDemoteCompleteWordForGarbageISuffixEntry() {
        // BUG-025 regression: studydict typo "してほしいい" (freq 1) demoted
        // the user's most frequent phrase "してほしい" (freq 22) to 3rd.
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "sitehosii",
            hiragana: "してほしい",
            context: "レビュー",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "してほしい",
                                  reading: "sitehosii",
                                  source: "study",
                                  kind: "exact",
                                  studyFrequency: 22),
                AIRerankCandidate(index: 1,
                                  text: "してほしいい",
                                  reading: "sitehosiii",
                                  source: "study",
                                  kind: "prefix",
                                  studyFrequency: 1),
                AIRerankCandidate(index: 2,
                                  text: "してほしいな",
                                  reading: "sitehosiina",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )

        let response = AIReranker.localRerank(request)

        XCTAssertEqual(response.order.first, 0)
        let breakdown = AIReranker.localScoreBreakdown(candidate: request.candidates[0], request: request)
        XCTAssertNil(breakdown.contributions["incompleteStemPenalty"])
    }

    func testLocalRerankDoesNotPenalizeOtherShortening() {
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "tameni",
            hiragana: "ために",
            context: "その",
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
                                  kind: "exact")
            ]
        )

        let breakdown = AIReranker.localScoreBreakdown(candidate: request.candidates[1], request: request)

        XCTAssertNil(breakdown.contributions["incompleteStemPenalty"])
    }

    func testLocalRerankUsesContextAffinityForExactHomophones() {
        // "どちらの" 文脈で過去に「向き」を選んだ履歴 (contextAffinity=1.0) がある場合、
        // study順で先行する「無機」より「向き」を上げる。
        let request = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "muki",
            hiragana: "むき",
            context: "どちらの",
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
                                  kind: "exact",
                                  contextAffinity: 1.0)
            ]
        )

        let response = AIReranker.localRerank(request)

        XCTAssertEqual(response.order.first, 1)
        let breakdown = AIReranker.localScoreBreakdown(candidate: request.candidates[1], request: request)
        XCTAssertEqual(breakdown.contributions["contextAffinityBonus"], 1.50)
    }

    func testLocalScoreBreakdownExposesStudyFrequencyBonus() {
        let frequent = AIRerankCandidate(index: 0,
                                         text: "機能",
                                         reading: "kinou",
                                         source: "study",
                                         kind: "exact",
                                         studyFrequency: 8)
        let request = AIRerankRequest(version: 1,
                                      mode: "fast-context-rerank",
                                      inputPat: "kinou",
                                      hiragana: "きのう",
                                      context: nil,
                                      candidates: [frequent])

        let breakdown = AIReranker.localScoreBreakdown(candidate: frequent, request: request)
        XCTAssertEqual(breakdown.contributions["studyFrequencyBonus"], 0.30)

        let once = AIRerankCandidate(index: 0,
                                     text: "機能",
                                     reading: "kinou",
                                     source: "study",
                                     kind: "exact",
                                     studyFrequency: 1)
        let onceBreakdown = AIReranker.localScoreBreakdown(candidate: once, request: request)
        XCTAssertNil(onceBreakdown.contributions["studyFrequencyBonus"])

        // Frequency bonus only applies to study-sourced candidates.
        let nonStudy = AIRerankCandidate(index: 0,
                                         text: "機能",
                                         reading: "kinou",
                                         source: "connection",
                                         kind: "exact",
                                         studyFrequency: 8)
        let nonStudyBreakdown = AIReranker.localScoreBreakdown(candidate: nonStudy, request: request)
        XCTAssertNil(nonStudyBreakdown.contributions["studyFrequencyBonus"])
    }

    func testCandidateDecodingDefaultsOptionalFeaturesToNil() throws {
        let json = #"{"index":0,"text":"向き","reading":"muki","source":"study","kind":"exact"}"#
        let candidate = try JSONDecoder().decode(AIRerankCandidate.self, from: Data(json.utf8))
        XCTAssertNil(candidate.contextAffinity)
        XCTAssertNil(candidate.studyFrequency)
    }

    func testLocalRerankPrefersQuestionPhraseWithoutPunctuationWhenReadingTies() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "siteimasuka",
            hiragana: "していますか",
            context: "今回はログは機能",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "していますか？",
                                  reading: "siteimasuka",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "していますか",
                                  reading: "siteimasuka",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 2,
                                  text: "しています",
                                  reading: "siteimasu",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )

        XCTAssertEqual(AIReranker.localRerank(request).order.first, 1)
    }

    func testLocalRerankPenalizesPoliteNegativePredictionUntilExplicitlyTyped() {
        let prematureNegative = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "onegaisim",
            hiragana: "おねがいしま",
            context: "よろしく",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "お願いしません",
                                  reading: "onegaisim",
                                  source: "study",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "お願いします",
                                  reading: "onegaisimasu",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )
        XCTAssertEqual(AIReranker.localRerank(prematureNegative).order.first, 1)

        let explicitlyTypedNegative = AIRerankRequest(
            version: 1,
            mode: "fast-context-rerank",
            inputPat: "onegaisimasen",
            hiragana: "おねがいしません",
            context: "よろしく",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "お願いしません",
                                  reading: "onegaisimasen",
                                  source: "study",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "お願いします",
                                  reading: "onegaisimasu",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )
        XCTAssertEqual(AIReranker.localRerank(explicitlyTypedNegative).order.first, 0)
    }

    func testLocalScoreBreakdownExposesPoliteNegativePredictionPenalty() {
        let candidate = AIRerankCandidate(index: 0,
                                          text: "思いません",
                                          reading: "omoim",
                                          source: "study",
                                          kind: "exact")
        let request = AIRerankRequest(version: 1,
                                      mode: "fast-context-rerank",
                                      inputPat: "omoim",
                                      hiragana: "おもいm",
                                      context: "そう",
                                      candidates: [candidate])

        let breakdown = AIReranker.localScoreBreakdown(candidate: candidate, request: request)

        XCTAssertEqual(breakdown.contributions["politeNegativePredictionPenalty"], -4.00)
    }

    func testLocalRerankPenalizesLongerPrefixPredictionUnlessContextStronglySupportsIt() {
        let neutral = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "shitagau",
            hiragana: "したがう",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "従うな",
                                  reading: "shitagauna",
                                  source: "connection",
                                  kind: "prefix"),
                AIRerankCandidate(index: 1,
                                  text: "従う",
                                  reading: "shitagau",
                                  source: "connection",
                                  kind: "exact")
            ]
        )
        XCTAssertEqual(AIReranker.localRerank(neutral).order.first, 1)

        let negativeImperative = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "shitagau",
            hiragana: "したがう",
            context: "この指示には決して",
            candidates: neutral.candidates
        )
        XCTAssertEqual(AIReranker.localRerank(negativeImperative).order.first, 0)

        let zettainiImperative = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "kiru",
            hiragana: "きる",
            context: "絶対に",
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "切る",
                                  reading: "kiru",
                                  source: "connection",
                                  kind: "exact"),
                AIRerankCandidate(index: 1,
                                  text: "切るな",
                                  reading: "kiruna",
                                  source: "connection",
                                  kind: "prefix")
            ]
        )
        XCTAssertEqual(AIReranker.localRerank(zettainiImperative).order.first, 1)
    }

    func testLocalRerankModelLabelCanBeOverridden() {
        let request = AIRerankRequest(
            version: 1,
            mode: "rerank",
            inputPat: "henkan",
            hiragana: "へんかん",
            context: nil,
            candidates: [
                AIRerankCandidate(index: 0,
                                  text: "変換",
                                  reading: "henkan",
                                  source: "connection",
                                  kind: "exact")
            ]
        )

        XCTAssertEqual(AIReranker.localRerank(request, model: "test-model").model, "test-model")
    }
}
