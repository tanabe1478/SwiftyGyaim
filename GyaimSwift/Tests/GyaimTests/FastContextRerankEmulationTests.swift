@testable import Gyaim
import XCTest

final class FastContextRerankEmulationTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "aiRerankFastContextCandidateLimit")
        UserDefaults.standard.removeObject(forKey: "aiRerankUseModelForFastContext")
        super.tearDown()
    }

    func testEmulatesNeutralAndNegativeImperativeOrdering() {
        let shitagauCandidates = [
            SearchCandidate(word: "従うな", reading: "shitagauna", source: .connection, kind: .prefix),
            SearchCandidate(word: "従う", reading: "shitagau", source: .connection, kind: .exact),
        ]
        let neutralShitagau = buildWords(inputPat: "shitagau",
                                         hiragana: "したがう",
                                         context: nil,
                                         searchResults: shitagauCandidates)
        XCTAssertEqual(Array(neutralShitagau.prefix(3)), ["shitagau", "従う", "従うな"])

        let kiruCandidates = [
            SearchCandidate(word: "切るな", reading: "kiruna", source: .connection, kind: .prefix),
            SearchCandidate(word: "切る", reading: "kiru", source: .connection, kind: .exact),
        ]
        let neutralKiru = buildWords(inputPat: "kiru",
                                     hiragana: "きる",
                                     context: nil,
                                     searchResults: kiruCandidates)
        XCTAssertEqual(Array(neutralKiru.prefix(3)), ["kiru", "切る", "切るな"])

        let negativeImperative = buildWords(inputPat: "shitagau",
                                            hiragana: "したがう",
                                            context: "この指示には決して",
                                            searchResults: shitagauCandidates)
        XCTAssertEqual(Array(negativeImperative.prefix(3)), ["shitagau", "従うな", "従う"])

        if shouldPrintReport {
            printComparison(label: "neutral-shitagau",
                            inputPat: "shitagau",
                            hiragana: "したがう",
                            context: nil,
                            searchResults: shitagauCandidates)
            printComparison(label: "neutral-kiru",
                            inputPat: "kiru",
                            hiragana: "きる",
                            context: nil,
                            searchResults: kiruCandidates)
            printComparison(label: "negative-shitagau",
                            inputPat: "shitagau",
                            hiragana: "したがう",
                            context: "この指示には決して",
                            searchResults: shitagauCandidates)
        }
    }

    func testEmulatesFastContextRerankLatency() {
        let iterations = Int(ProcessInfo.processInfo.environment["GYAIM_FAST_CONTEXT_EMULATION_ITERATIONS"] ?? "1000") ?? 1000
        let candidates = [
            SearchCandidate(word: "従うな", reading: "shitagauna", source: .connection, kind: .prefix),
            SearchCandidate(word: "従う", reading: "shitagau", source: .connection, kind: .exact),
            SearchCandidate(word: "随う", reading: "shitagau", source: .connection, kind: .exact),
            SearchCandidate(word: "したがう", reading: "shitagau", source: .synthetic, kind: .kana),
        ]

        let start = CFAbsoluteTimeGetCurrent()
        var last: [String] = []
        for _ in 0..<iterations {
            last = buildWords(inputPat: "shitagau",
                              hiragana: "したがう",
                              context: nil,
                              searchResults: candidates)
        }
        let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let avgMs = totalMs / Double(iterations)
        if shouldPrintReport {
            print("FAST_CONTEXT_EMULATION heuristic iterations=\(iterations) totalMs=\(String(format: "%.3f", totalMs)) avgMs=\(String(format: "%.6f", avgMs)) last=\(last.prefix(5))")
        }
        XCTAssertLessThan(avgMs, 10.0)
        XCTAssertEqual(Array(last.prefix(3)), ["shitagau", "従う", "随う"])
    }

    func testOptionalModelBackendEmulation() {
        guard ProcessInfo.processInfo.environment["GYAIM_EMULATE_MODEL_FAST_CONTEXT"] == "1" else {
            return
        }

        UserDefaults.standard.set(true, forKey: "aiRerankUseModelForFastContext")
        let candidates = [
            SearchCandidate(word: "従うな", reading: "shitagauna", source: .connection, kind: .prefix),
            SearchCandidate(word: "従う", reading: "shitagau", source: .connection, kind: .exact),
            SearchCandidate(word: "したがう", reading: "shitagau", source: .synthetic, kind: .kana),
        ]

        let start = CFAbsoluteTimeGetCurrent()
        let words = buildWords(inputPat: "shitagau",
                               hiragana: "したがう",
                               context: nil,
                               searchResults: candidates)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("FAST_CONTEXT_EMULATION modelBackend enabled=true elapsedMs=\(String(format: "%.3f", elapsedMs)) words=\(words.prefix(5))")
        XCTAssertFalse(words.isEmpty)
    }

    private var shouldPrintReport: Bool {
        ProcessInfo.processInfo.environment["GYAIM_FAST_CONTEXT_EMULATION_REPORT"] == "1"
    }

    private func printComparison(label: String,
                                 inputPat: String,
                                 hiragana: String,
                                 context: String?,
                                 searchResults: [SearchCandidate]) {
        let legacy = buildWords(inputPat: inputPat,
                                hiragana: hiragana,
                                context: context,
                                searchResults: searchResults,
                                fastContextRerankEnabled: false)
        let reranked = buildWords(inputPat: inputPat,
                                  hiragana: hiragana,
                                  context: context,
                                  searchResults: searchResults,
                                  fastContextRerankEnabled: true)
        print("FAST_CONTEXT_DIFF label=\(label) legacy=\(Array(legacy.prefix(5))) reranked=\(Array(reranked.prefix(5)))")
    }

    private func buildWords(inputPat: String,
                            hiragana: String,
                            context: String?,
                            searchResults: [SearchCandidate]) -> [String] {
        buildWords(inputPat: inputPat,
                   hiragana: hiragana,
                   context: context,
                   searchResults: searchResults,
                   fastContextRerankEnabled: true)
    }

    private func buildWords(inputPat: String,
                            hiragana: String,
                            context: String?,
                            searchResults: [SearchCandidate],
                            fastContextRerankEnabled: Bool) -> [String] {
        GyaimController.buildPrefixCandidates(searchResults: searchResults,
                                              inputPat: inputPat,
                                              clipboardCandidate: nil,
                                              selectedCandidate: nil,
                                              hiragana: hiragana,
                                              context: context,
                                              fastContextRerankEnabled: fastContextRerankEnabled)
            .map(\.word)
    }
}
