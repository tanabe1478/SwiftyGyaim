import XCTest

/// Secure Event Input残留診断（issue #85）の純粋ロジック検証。
/// 実際のIsSecureEventInputEnabled/IORegistry呼び出しはOSセッション状態に
/// 依存するため、メッセージ組み立てと再ログ判定のみをテストする。
final class SecureInputDiagnosticsTests: XCTestCase {

    func testMessageDescribesOwnerState() {
        let alive = SecureInputDiagnostics.message(
            for: SecureInputDiagnostics.OwnerInfo(pid: 415, processName: "loginwindow"))
        XCTAssertTrue(alive.contains("pid=415 (loginwindow)"))
        XCTAssertTrue(alive.contains("Ctrl+Cmd+Q"))

        let terminated = SecureInputDiagnostics.message(
            for: SecureInputDiagnostics.OwnerInfo(pid: 840, processName: nil))
        XCTAssertTrue(terminated.contains("pid=840"))
        XCTAssertTrue(terminated.contains("already terminated"))

        let unknown = SecureInputDiagnostics.message(for: nil)
        XCTAssertTrue(unknown.contains("owner unknown"))
        XCTAssertTrue(unknown.contains("Secure Event Input is active"))
    }

    func testShouldLogOnFirstDetectionOwnerChangeOrAfterInterval() {
        // First detection always logs.
        XCTAssertTrue(SecureInputDiagnostics.shouldLog(
            ownerPID: 415, lastLoggedOwnerPID: nil,
            elapsedSinceLastLog: 0, firstDetection: true))
        // Same owner within the interval stays quiet.
        XCTAssertFalse(SecureInputDiagnostics.shouldLog(
            ownerPID: 415, lastLoggedOwnerPID: 415,
            elapsedSinceLastLog: 5, firstDetection: false))
        // Owner change relogs immediately.
        XCTAssertTrue(SecureInputDiagnostics.shouldLog(
            ownerPID: 999, lastLoggedOwnerPID: 415,
            elapsedSinceLastLog: 5, firstDetection: false))
        // Same owner relogs once the interval has passed.
        XCTAssertTrue(SecureInputDiagnostics.shouldLog(
            ownerPID: 415, lastLoggedOwnerPID: 415,
            elapsedSinceLastLog: SecureInputDiagnostics.relogInterval + 1,
            firstDetection: false))
    }
}
