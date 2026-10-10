@testable import Gyaim
import XCTest

/// Left context survives IMK recreating the controller (ADR-035).
final class CommittedContextStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFreshEntryIsInheritedPerBundle() {
        let store = CommittedContextStore()
        store.record(text: "どちらのサービスを", bundle: "com.google.Chrome", now: t0)
        store.record(text: "使っている", bundle: "com.google.Chrome", now: t0.addingTimeInterval(1))
        store.record(text: "ls -la", bundle: "com.mitchellh.ghostty", now: t0)

        XCTAssertEqual(store.inheritableContext(bundle: "com.google.Chrome",
                                                now: t0.addingTimeInterval(15), carryOverSeconds: 300),
                       "どちらのサービスを使っている")
        XCTAssertEqual(store.inheritableContext(bundle: "com.mitchellh.ghostty",
                                                now: t0.addingTimeInterval(15), carryOverSeconds: 300),
                       "ls -la")
        XCTAssertEqual(store.inheritableContext(bundle: "com.tinyspeck.slackmacgap",
                                                now: t0, carryOverSeconds: 300), "")
    }

    func testStaleEntryAndDisabledWindowAreNotInherited() {
        let store = CommittedContextStore()
        store.record(text: "文脈", bundle: "app", now: t0)
        XCTAssertEqual(store.inheritableContext(bundle: "app", now: t0.addingTimeInterval(300), carryOverSeconds: 300),
                       "文脈", "age equal to the window is still fresh")
        XCTAssertEqual(store.inheritableContext(bundle: "app", now: t0.addingTimeInterval(301), carryOverSeconds: 300),
                       "")
        XCTAssertEqual(store.inheritableContext(bundle: "app", now: t0.addingTimeInterval(1), carryOverSeconds: 0), "",
                       "0 disables inheritance")
        XCTAssertEqual(store.inheritableContext(bundle: "app", now: t0.addingTimeInterval(-5), carryOverSeconds: 300),
                       "", "clock going backwards is treated as stale")
    }

    func testRecordKeepsOnlyTheTailAndIgnoresEmptyInput() {
        let store = CommittedContextStore(maxCharacters: 5)
        store.record(text: "あいうえお", bundle: "app", now: t0)
        store.record(text: "かき", bundle: "app", now: t0)
        store.record(text: "", bundle: "app", now: t0)
        store.record(text: "x", bundle: "", now: t0)
        XCTAssertEqual(store.entry(for: "app")?.text, "うえおかき")
        XCTAssertNil(store.entry(for: ""))
    }

    func testCarryOverSecondsDefaultAndClamp() {
        XCTAssertEqual(CommittedContextStore.carryOverSeconds(configured: nil), 300)
        XCTAssertEqual(CommittedContextStore.carryOverSeconds(configured: -1), 0)
        XCTAssertEqual(CommittedContextStore.carryOverSeconds(configured: 60), 60)
        XCTAssertEqual(CommittedContextStore.carryOverSeconds(configured: 10_000), 3600)
    }

    func testCommitPayloadsFlagInheritedContextOnlyWhenSet() throws {
        let plain = try XCTUnwrap(GyaimController.commitOutcomePayload(
            path: "prefix", chosenWord: "合っている", context: "が", prefixWords: ["atteiru", "合っている"], trace: nil))
        XCTAssertFalse(plain.contains("contextInherited"))
        let inherited = try XCTUnwrap(GyaimController.commitOutcomePayload(
            path: "prefix", chosenWord: "合っている", context: "サービスを使っているか",
            prefixWords: ["atteiru", "合っている"], trace: nil, contextInherited: true))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(inherited.utf8)) as? [String: Any])
        XCTAssertEqual(json["contextInherited"] as? Bool, true)

        let candidates = [SearchCandidate(word: "合っている", reading: "atteiru", source: .study, kind: .exact)]
        let detail = try XCTUnwrap(GyaimController.acceptedDetailPayload(
            candidates: candidates, chosenIndex: 0, context: "か", contextInherited: true))
        let detailJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any])
        XCTAssertEqual(detailJSON["contextInherited"] as? Bool, true)
    }
}
