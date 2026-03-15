import XCTest
@testable import Gyaim

final class ExternalCommandTests: XCTestCase {

    // MARK: - Encrypt Trigger

    func testHasEncryptTrigger_withDefaultTrigger() {
        XCTAssertTrue(ExternalCommand.hasEncryptTrigger("4111@e"))
    }

    func testHasEncryptTrigger_triggerOnly_returnsFalse() {
        // Need at least 1 char of plaintext + trigger
        XCTAssertFalse(ExternalCommand.hasEncryptTrigger("@e"))
    }

    func testHasEncryptTrigger_noTrigger_returnsFalse() {
        XCTAssertFalse(ExternalCommand.hasEncryptTrigger("4111"))
    }

    func testHasEncryptTrigger_emptyString_returnsFalse() {
        XCTAssertFalse(ExternalCommand.hasEncryptTrigger(""))
    }

    // MARK: - Decrypt Trigger

    func testHasDecryptTrigger_triggerOnly() {
        // "@d" alone triggers decrypt list
        XCTAssertTrue(ExternalCommand.hasDecryptTrigger("@d"))
    }

    func testHasDecryptTrigger_withLabel() {
        XCTAssertTrue(ExternalCommand.hasDecryptTrigger("card@d"))
    }

    func testHasDecryptTrigger_noTrigger_returnsFalse() {
        XCTAssertFalse(ExternalCommand.hasDecryptTrigger("card"))
    }

    func testHasDecryptTrigger_emptyString_returnsFalse() {
        XCTAssertFalse(ExternalCommand.hasDecryptTrigger(""))
    }

    // MARK: - Extract Plaintext

    func testExtractPlaintext_basic() {
        XCTAssertEqual(ExternalCommand.extractPlaintext("4111-2222@e"), "4111-2222")
    }

    func testExtractPlaintext_noTrigger_returnsOriginal() {
        XCTAssertEqual(ExternalCommand.extractPlaintext("hello"), "hello")
    }

    func testExtractPlaintext_japanese() {
        XCTAssertEqual(ExternalCommand.extractPlaintext("秘密のテキスト@e"), "秘密のテキスト")
    }

    // MARK: - Extract Decrypt Label

    func testExtractDecryptLabel_withLabel() {
        XCTAssertEqual(ExternalCommand.extractDecryptLabel("card@d"), "card")
    }

    func testExtractDecryptLabel_triggerOnly_returnsNil() {
        // "@d" alone means "list all", no specific label
        XCTAssertNil(ExternalCommand.extractDecryptLabel("@d"))
    }

    func testExtractDecryptLabel_noTrigger_returnsNil() {
        XCTAssertNil(ExternalCommand.extractDecryptLabel("card"))
    }

    // MARK: - Shell Escape

    func testShellEscape_basic() {
        XCTAssertEqual(ExternalCommand.shellEscape("hello"), "'hello'")
    }

    func testShellEscape_withSingleQuote() {
        XCTAssertEqual(ExternalCommand.shellEscape("it's"), "'it'\\''s'")
    }

    func testShellEscape_empty() {
        XCTAssertEqual(ExternalCommand.shellEscape(""), "''")
    }

    func testShellEscape_withSpaces() {
        XCTAssertEqual(ExternalCommand.shellEscape("hello world"), "'hello world'")
    }

    // MARK: - Build Candidates

    func testBuildCandidates_basic() {
        let results = ["4111-2222-3333-4444"]
        let candidates = ExternalCommand.buildCandidates(results: results, source: "card")
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].word, "card")
        XCTAssertEqual(candidates[1].word, "4111-2222-3333-4444")
    }

    func testBuildCandidates_multipleResults() {
        let results = ["result1", "result2", "result3"]
        let candidates = ExternalCommand.buildCandidates(results: results, source: "query")
        XCTAssertEqual(candidates.count, 4) // source + 3 results
    }

    func testBuildCandidates_deduplicates() {
        let results = ["card", "other"] // "card" duplicates source
        let candidates = ExternalCommand.buildCandidates(results: results, source: "card")
        XCTAssertEqual(candidates.count, 2) // "card" + "other"
        XCTAssertEqual(candidates[0].word, "card")
        XCTAssertEqual(candidates[1].word, "other")
    }

    func testBuildCandidates_emptyResults() {
        let candidates = ExternalCommand.buildCandidates(results: [], source: "card")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].word, "card")
    }

    // MARK: - Build Pending Candidates

    func testBuildPendingCandidates_containsMessage() {
        let candidates = ExternalCommand.buildPendingCandidates(source: "card")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].word.contains("実行中"))
    }

    // MARK: - Decrypt List Candidates

    func testBuildDecryptListCandidates_basic() {
        let labels = ["card", "gmail", "bank"]
        let candidates = ExternalCommand.buildDecryptListCandidates(labels: labels)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].word, "card")
        XCTAssertEqual(candidates[1].word, "gmail")
        XCTAssertEqual(candidates[2].word, "bank")
    }

    func testBuildDecryptListCandidates_hasDecryptReading() {
        let labels = ["card"]
        let candidates = ExternalCommand.buildDecryptListCandidates(labels: labels)
        XCTAssertEqual(candidates[0].reading, "@decrypt:card")
    }

    func testBuildDecryptListCandidates_empty() {
        let candidates = ExternalCommand.buildDecryptListCandidates(labels: [])
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - isDecryptListCandidate

    func testIsDecryptListCandidate_true() {
        let candidate = SearchCandidate(word: "card", reading: "@decrypt:card")
        XCTAssertTrue(ExternalCommand.isDecryptListCandidate(candidate))
    }

    func testIsDecryptListCandidate_false_normalCandidate() {
        let candidate = SearchCandidate(word: "card", reading: "かーど")
        XCTAssertFalse(ExternalCommand.isDecryptListCandidate(candidate))
    }

    func testIsDecryptListCandidate_false_noReading() {
        let candidate = SearchCandidate(word: "card")
        XCTAssertFalse(ExternalCommand.isDecryptListCandidate(candidate))
    }

    // MARK: - Extract Label from Decrypt Reading

    func testDecryptLabelFromReading_basic() {
        XCTAssertEqual(ExternalCommand.decryptLabelFromReading("@decrypt:card"), "card")
    }

    func testDecryptLabelFromReading_notDecryptReading() {
        XCTAssertNil(ExternalCommand.decryptLabelFromReading("かーど"))
    }

    func testDecryptLabelFromReading_nil() {
        XCTAssertNil(ExternalCommand.decryptLabelFromReading(nil))
    }
}
