import Carbon
import Foundation
import IOKit

/// Secure Event Input残留の診断（issue #85, ADR-023）。
///
/// Secure Event Inputが有効な間、キーイベントはIMEをバイパスし日本語変換が
/// 不能になる。他プロセスが所有するSecure InputをIMEから解除する手段はなく、
/// 他のIME（Mozc/macSKK等）も検出を実装していないため黙って入力不能になる。
/// Gyaimは activateServer 到達時に状態を検出し、原因（所有PID・プロセス名・
/// 生死）と復旧手順をログへ記録して調査時間を短縮する。UIには何も出さない。
enum SecureInputDiagnostics {

    struct OwnerInfo: Equatable {
        let pid: pid_t
        /// nil の場合、所有プロセスはすでに終了している（WindowServer残留）。
        let processName: String?
    }

    /// 同一所有者の再ログを抑制する間隔。activateServerはフォーカス移動の
    /// たびに呼ばれるため、所有者が変わらない限りこの間隔でしか出力しない。
    static let relogInterval: TimeInterval = 600

    private static var lastLoggedOwnerPID: pid_t?
    private static var lastLoggedAt: CFAbsoluteTime = 0
    private static var wasActive = false

    /// activateServer から呼ぶエントリポイント。Secure Inputが無効なら
    /// Bool判定1回だけで即リターンする（通常パスのコストはほぼゼロ）。
    static func checkAndLog() {
        guard IsSecureEventInputEnabled() else {
            if wasActive {
                Log.input.notice("Secure Event Input cleared")
                wasActive = false
                lastLoggedOwnerPID = nil
                lastLoggedAt = 0
            }
            return
        }
        let owner = currentOwner()
        let now = CFAbsoluteTimeGetCurrent()
        guard shouldLog(ownerPID: owner?.pid,
                        lastLoggedOwnerPID: wasActive ? lastLoggedOwnerPID : nil,
                        elapsedSinceLastLog: now - lastLoggedAt,
                        firstDetection: !wasActive) else { return }
        wasActive = true
        lastLoggedOwnerPID = owner?.pid
        lastLoggedAt = now
        Log.input.notice(message(for: owner))
    }

    /// 再ログ判定（純粋関数、SecureInputDiagnosticsTestsで検証）。
    static func shouldLog(ownerPID: pid_t?,
                          lastLoggedOwnerPID: pid_t?,
                          elapsedSinceLastLog: TimeInterval,
                          firstDetection: Bool) -> Bool {
        if firstDetection { return true }
        if ownerPID != lastLoggedOwnerPID { return true }
        return elapsedSinceLastLog >= relogInterval
    }

    /// ログメッセージ組み立て（純粋関数、SecureInputDiagnosticsTestsで検証）。
    static func message(for owner: OwnerInfo?) -> String {
        let ownerDescription: String
        switch owner {
        case let .some(info) where info.processName != nil:
            ownerDescription = "pid=\(info.pid) (\(info.processName!))"
        case let .some(info):
            ownerDescription = "pid=\(info.pid) (already terminated; stale WindowServer state)"
        case .none:
            ownerDescription = "unknown"
        }
        return "Secure Event Input is active: owner \(ownerDescription). "
            + "Key events bypass the IME, so Japanese conversion is unavailable. "
            + "Recovery: quit the owner app; if it persists, lock the screen "
            + "(Ctrl+Cmd+Q) and unlock."
    }

    /// WindowServerが保持する所有PIDをIORegistryから取得し、生死を添える。
    /// `ioreg -l | grep kCGSSessionSecureInputPID` と同じ情報源。
    static func currentOwner() -> OwnerInfo? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? pid_t {
                return OwnerInfo(pid: pid, processName: processName(pid: pid))
            }
        }
        return nil
    }

    /// PIDからプロセス名を引く。終了済みならnil。
    static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
