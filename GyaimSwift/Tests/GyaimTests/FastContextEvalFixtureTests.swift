@testable import Gyaim
import XCTest

final class FastContextEvalFixtureTests: XCTestCase {
    struct EvalCase: Decodable {
        struct Candidate: Decodable {
            let text: String
            let reading: String
            let source: String
            let kind: String
        }

        let id: String
        let inputPat: String
        let inputKana: String
        let context: String
        let candidates: [Candidate]
        let expectedTop: String
        let expectedTopWithoutContext: String?
        let mustNotTop: [String]
        let tags: [String]
        let reason: String
    }

    func testFastContextEvalFixtureSchema() throws {
        let cases = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 10)

        var seen = Set<String>()
        for item in cases {
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertTrue(seen.insert(item.id).inserted, "duplicate id: \(item.id)")
            XCTAssertFalse(item.inputPat.isEmpty, item.id)
            XCTAssertFalse(item.inputKana.isEmpty, item.id)
            XCTAssertGreaterThanOrEqual(item.candidates.count, 2, item.id)
            XCTAssertFalse(item.tags.isEmpty, item.id)
            XCTAssertTrue(item.tags.contains("fast-context"), item.id)
            XCTAssertFalse(item.reason.isEmpty, item.id)

            let candidateTexts = Set(item.candidates.map(\.text))
            XCTAssertTrue(candidateTexts.contains(item.expectedTop), item.id)
            for word in item.mustNotTop {
                XCTAssertTrue(candidateTexts.contains(word), "\(item.id): missing mustNotTop candidate \(word)")
            }
            if let expectedTopWithoutContext = item.expectedTopWithoutContext {
                XCTAssertTrue(candidateTexts.contains(expectedTopWithoutContext), item.id)
            }

            for candidate in item.candidates {
                XCTAssertFalse(candidate.text.isEmpty, item.id)
                XCTAssertFalse(candidate.reading.isEmpty, item.id)
                XCTAssertFalse(candidate.source.isEmpty, item.id)
                XCTAssertTrue(Self.validCandidateKinds.contains(candidate.kind), "\(item.id): \(candidate.kind)")
            }
        }
    }

    private static let validCandidateKinds: Set<String> = [
        CandidateKind.raw.rawValue,
        CandidateKind.exact.rawValue,
        CandidateKind.prefix.rawValue,
        CandidateKind.compound.rawValue,
        CandidateKind.lattice.rawValue,
        CandidateKind.completion.rawValue,
        CandidateKind.zenz.rawValue,
        CandidateKind.google.rawValue,
        CandidateKind.kana.rawValue,
    ]

    private func loadCases() throws -> [EvalCase] {
        let fixture = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fast-context-eval-cases.jsonl")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8))
        }
    }
}
