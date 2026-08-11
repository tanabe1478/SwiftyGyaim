import XCTest

/// Secure Event Input残留診断（issue #85）の純粋ロジック検証。
/// 実際のIsSecureEventInputEnabled/IORegistry呼び出しはOSセッション状態に
/// 依存するため、メッセージ組み立てと再ログ判定のみをテストする。
final class SecureInputDiagnosticsTests: XCTestCase {

    // MARK: - message(for:)

    func testMessageWithAliveOwnerIncludesPIDAndName() {
        let owner = SecureInputDiagnostics.OwnerInfo(pid: 415, processName: "loginwindow")
        let msg = SecureInputDiagnostics.message(for: owner)
        XCTAssertTrue(msg.contains("pid=415 (loginwindow)"))
        XCTAssertTrue(msg.contains("Ctrl+Cmd+Q"))
    }

    func testMessageWithTerminatedOwnerMarksStaleState() {
        let owner = SecureInputDiagnostics.OwnerInfo(pid: 840, processName: nil)
        let msg = SecureInputDiagnostics.message(for: owner)
        XCTAssertTrue(msg.contains("pid=840"))
        XCTAssertTrue(msg.contains("already terminated"))
    }

    func testMessageWithUnknownOwner() {
        let msg = SecureInputDiagnostics.message(for: nil)
        XCTAssertTrue(msg.contains("owner unknown"))
        XCTAssertTrue(msg.contains("Secure Event Input is active"))
    }

    // MARK: - shouldLog(...)

    func testFirstDetectionAlwaysLogs() {
        XCTAssertTrue(SecureInputDiagnostics.shouldLog(
            ownerPID: 415, lastLoggedOwnerPID: nil,
            elapsedSinceLastLog: 0, firstDetection: true))
    }

    func testSameOwnerWithinIntervalDoesNotRelog() {
        XCTAssertFalse(SecureInputDiagnostics.shouldLog(
            ownerPID: 415, lastLoggedOwnerPID: 415,
            elapsedSinceLastLog: 5, firstDetection: false))
    }

    func testOwnerChangeRelogsImmediately() {
        XCTAssertTrue(SecureInputDiagnostics.shouldLog(
            ownerPID: 999, lastLoggedOwnerPID: 415,
            elapsedSinceLastLog: 5, firstDetection: false))
    }

    func testSameOwnerRelogsAfterInterval() {
        XCTAssertTrue(SecureInputDiagnostics.shouldLog(
            ownerPID: 415, lastLoggedOwnerPID: 415,
            elapsedSinceLastLog: SecureInputDiagnostics.relogInterval + 1,
            firstDetection: false))
    }

    // MARK: - processName(pid:)

    func testProcessNameForCurrentProcess() {
        let name = SecureInputDiagnostics.processName(pid: getpid())
        XCTAssertNotNil(name)
        XCTAssertFalse(name!.isEmpty)
    }

    func testProcessNameForTerminatedPIDReturnsNil() {
        // PID 99999台の空きを探す確実な方法はないが、負のPIDは常に無効
        XCTAssertNil(SecureInputDiagnostics.processName(pid: -1))
    }
}
