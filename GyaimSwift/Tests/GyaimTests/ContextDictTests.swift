@testable import Gyaim
import XCTest

final class ContextDictTests: XCTestCase {
    private var dict: ContextDict!
    private var file: String!

    override func setUp() {
        super.setUp()
        file = NSTemporaryDirectory() + "gyaim-test-contextdict-\(UUID().uuidString).txt"
        dict = ContextDict()
        dict.configure(file: file)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: file)
        super.tearDown()
    }

    func testContextKeyTrimsAndLimitsSuffix() {
        XCTAssertEqual(ContextDict.contextKey(from: "どちらの"), "どちらの")
        XCTAssertEqual(ContextDict.contextKey(from: "とても長い左文脈がここにある"), "文脈がここにある")
        XCTAssertEqual(ContextDict.contextKey(from: "  タブ\tと改行\nを含む  "), "タブと改行を含む")
        XCTAssertEqual(ContextDict.contextKey(from: "   "), "")
    }

    func testCommonSuffixLength() {
        XCTAssertEqual(ContextDict.commonSuffixLength("どちらの", "どちらの"), 4)
        XCTAssertEqual(ContextDict.commonSuffixLength("素材はどちらの", "どちらの"), 4)
        XCTAssertEqual(ContextDict.commonSuffixLength("あちらの", "どちらの"), 3)
        XCTAssertEqual(ContextDict.commonSuffixLength("この素材は", "どちらの"), 0)
    }

    func testAffinityRequiresMinimumSuffixOverlap() {
        dict.record(context: "どちらの", reading: "muki", word: "向き")

        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "muki", word: "向き"), 1.0, accuracy: 1e-6)
        XCTAssertEqual(dict.affinity(context: "ではどちらの", reading: "muki", word: "向き"), 1.0, accuracy: 1e-6)
        // Partial 3-char suffix overlap ("ちらの") scales down.
        XCTAssertEqual(dict.affinity(context: "あちらの", reading: "muki", word: "向き"), 0.75, accuracy: 1e-6)
        // 1-char overlap ("の") is noise.
        XCTAssertEqual(dict.affinity(context: "こちらとしての", reading: "muki", word: "向き"), 0.0)
        XCTAssertEqual(dict.affinity(context: "全く別の文脈だ", reading: "muki", word: "向き"), 0.0)
        // Different word / reading never matches.
        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "muki", word: "無機"), 0.0)
        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "kinou", word: "向き"), 0.0)
        // Missing context or reading is no evidence.
        XCTAssertEqual(dict.affinity(context: nil, reading: "muki", word: "向き"), 0.0)
        XCTAssertEqual(dict.affinity(context: "どちらの", reading: nil, word: "向き"), 0.0)
    }

    func testAffinityScoreScalesWithMatchLength() {
        XCTAssertEqual(ContextDict.affinityScore(matchLength: 1), 0.0)
        XCTAssertEqual(ContextDict.affinityScore(matchLength: 2), 0.5)
        XCTAssertEqual(ContextDict.affinityScore(matchLength: 3), 0.75)
        XCTAssertEqual(ContextDict.affinityScore(matchLength: 4), 1.0)
        XCTAssertEqual(ContextDict.affinityScore(matchLength: 8), 1.0)
    }

    func testRecordPersistsAndReloads() {
        dict.record(context: "この素材は", reading: "muki", word: "無機", now: 1000)
        dict.record(context: "この素材は", reading: "muki", word: "無機", now: 2000)
        dict.record(context: "どちらの", reading: "muki", word: "向き", now: 3000)

        let reloaded = ContextDict()
        reloaded.configure(file: file)
        XCTAssertEqual(reloaded.affinity(context: "この素材は", reading: "muki", word: "無機", now: 2000), 1.0)
        XCTAssertEqual(reloaded.affinity(context: "どちらの", reading: "muki", word: "向き", now: 3000), 1.0)

        let entries = ContextDict.load(file: file)
        XCTAssertEqual(entries.count, 2)
        // Duplicate (context, reading, word) increments count and moves to front.
        XCTAssertEqual(entries.first?.word, "向き")
        XCTAssertEqual(entries.last?.count, 2)
        XCTAssertEqual(entries.last?.lastAccessTime, 2000)
    }

    func testRecordSkipsEmptyOrUnsafeInput() {
        dict.record(context: "", reading: "muki", word: "向き")
        dict.record(context: "どちらの", reading: "", word: "向き")
        dict.record(context: "どちらの", reading: "muki", word: "")
        dict.record(context: "どちらの", reading: "mu\tki", word: "向き")

        XCTAssertTrue(ContextDict.load(file: file).isEmpty)
    }

    func testDeleteEntriesRemovesAllContextsForWordReading() {
        dict.record(context: "どちらの", reading: "muki", word: "向き")
        dict.record(context: "テーブルの", reading: "muki", word: "向き")
        dict.record(context: "この素材は", reading: "muki", word: "無機")

        XCTAssertTrue(dict.deleteEntries(word: "向き", reading: "muki"))

        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "muki", word: "向き"), 0.0)
        XCTAssertEqual(dict.affinity(context: "テーブルの", reading: "muki", word: "向き"), 0.0)
        XCTAssertEqual(dict.affinity(context: "この素材は", reading: "muki", word: "無機"), 1.0, accuracy: 1e-6)
        XCTAssertFalse(dict.deleteEntries(word: "向き", reading: "muki"))
    }

    func testDisabledSettingBlocksRecordingAndAffinity() {
        UserDefaults.standard.set(false, forKey: "contextLearningEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "contextLearningEnabled") }

        dict.record(context: "どちらの", reading: "muki", word: "向き")
        XCTAssertTrue(ContextDict.load(file: file).isEmpty)

        UserDefaults.standard.removeObject(forKey: "contextLearningEnabled")
        dict.record(context: "どちらの", reading: "muki", word: "向き")
        UserDefaults.standard.set(false, forKey: "contextLearningEnabled")
        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "muki", word: "向き"), 0.0,
                       "existing entries stay on disk but affinity is off")
    }

    func testClearRemovesAllEntries() {
        dict.record(context: "どちらの", reading: "muki", word: "向き")
        dict.record(context: "この素材は", reading: "muki", word: "無機")
        XCTAssertEqual(dict.entryCount(), 2)

        dict.clear()

        XCTAssertEqual(dict.entryCount(), 0)
        XCTAssertTrue(ContextDict.load(file: file).isEmpty)
        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "muki", word: "向き"), 0.0)
    }

    func testAffinityDecaysWithEntryAge() {
        // Issue #58: half-life 30 days, floor 0.25 — an old one-off choice
        // cannot keep overriding fresh behavior, but never fully vanishes.
        let base: TimeInterval = 1_000_000
        dict.record(context: "どちらの", reading: "muki", word: "向き", now: base)

        let halfLife = ContextDict.decayHalfLifeSeconds
        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "muki", word: "向き", now: base), 1.0)
        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "muki", word: "向き", now: base + halfLife),
                       0.5, accuracy: 1e-6)
        XCTAssertEqual(dict.affinity(context: "どちらの", reading: "muki", word: "向き", now: base + halfLife * 12),
                       ContextDict.decayFloor, accuracy: 1e-6)
    }

    func testEntriesAreCappedAtMaxEntries() throws {
        // Pre-build an over-capacity file so the cap is exercised without
        // thousands of synchronous saves.
        let lines = (0..<(ContextDict.maxEntries + 10)).map { "文脈\($0)\tr\($0)\tw\($0)\t1000.0\t1" }
        try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        dict.configure(file: file)

        dict.record(context: "新しい文脈", reading: "atarasii", word: "新しい")

        XCTAssertEqual(ContextDict.load(file: file).count, ContextDict.maxEntries)
    }
}
