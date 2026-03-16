import Foundation

/// External command integration for encryption/decryption.
/// Follows the same architectural pattern as GoogleTransliterate:
/// trigger detection, async execution, candidate building.
enum ExternalCommand {

    // MARK: - Trigger Configuration

    private static let encryptTriggerKey = "externalCommandEncryptTrigger"
    private static let decryptTriggerKey = "externalCommandDecryptTrigger"
    private static let commandPathKey = "externalCommandPath"
    private static let defaultEncryptTrigger = "@e"
    private static let defaultDecryptTrigger = "@d"

    static var encryptTrigger: String {
        UserDefaults.standard.string(forKey: encryptTriggerKey) ?? defaultEncryptTrigger
    }

    static func setEncryptTrigger(_ value: String) {
        UserDefaults.standard.set(value, forKey: encryptTriggerKey)
    }

    static var decryptTrigger: String {
        UserDefaults.standard.string(forKey: decryptTriggerKey) ?? defaultDecryptTrigger
    }

    static func setDecryptTrigger(_ value: String) {
        UserDefaults.standard.set(value, forKey: decryptTriggerKey)
    }

    static var commandPath: String {
        UserDefaults.standard.string(forKey: commandPathKey) ?? "\(Config.gyaimDir)/secret.sh"
    }

    static func setCommandPath(_ value: String) {
        UserDefaults.standard.set(value, forKey: commandPathKey)
    }

    // MARK: - Trigger Detection

    /// Check if query ends with the encrypt trigger (e.g. "4111@e").
    /// Requires at least 1 char of plaintext + trigger length.
    static func hasEncryptTrigger(_ query: String) -> Bool {
        let trigger = encryptTrigger
        return query.count > trigger.count && query.hasSuffix(trigger)
    }

    /// Check if query ends with the decrypt trigger (e.g. "@d" or "card@d").
    /// Unlike encrypt, trigger alone is valid (triggers list mode).
    static func hasDecryptTrigger(_ query: String) -> Bool {
        let trigger = decryptTrigger
        return !query.isEmpty && query.hasSuffix(trigger)
    }

    /// Extract plaintext from an encrypt-triggered query (strip trigger suffix).
    static func extractPlaintext(_ query: String) -> String {
        guard hasEncryptTrigger(query) else { return query }
        return String(query.dropLast(encryptTrigger.count))
    }

    /// Extract label from a decrypt-triggered query, or nil if trigger-only (list mode).
    static func extractDecryptLabel(_ query: String) -> String? {
        guard hasDecryptTrigger(query) else { return nil }
        let label = String(query.dropLast(decryptTrigger.count))
        return label.isEmpty ? nil : label
    }

    // MARK: - Decrypt List Candidate Marker

    private static let decryptReadingPrefix = "@decrypt:"

    /// Check if a candidate is from the decrypt list (2-step flow marker).
    static func isDecryptListCandidate(_ candidate: SearchCandidate) -> Bool {
        candidate.reading?.hasPrefix(decryptReadingPrefix) == true
    }

    /// Extract the label from a decrypt list candidate's reading.
    static func decryptLabelFromReading(_ reading: String?) -> String? {
        guard let reading, reading.hasPrefix(decryptReadingPrefix) else { return nil }
        return String(reading.dropFirst(decryptReadingPrefix.count))
    }

    // MARK: - Candidate Building

    /// Build candidates from external command results.
    static func buildCandidates(results: [String], source: String) -> [SearchCandidate] {
        var candidates: [SearchCandidate] = []
        candidates.append(SearchCandidate(word: source))
        for line in results {
            candidates.append(SearchCandidate(word: line, reading: source))
        }
        var seen: Set<String> = []
        candidates = candidates.filter { c in
            if seen.contains(c.word) { return false }
            seen.insert(c.word)
            return true
        }
        return candidates
    }

    /// Build a pending (loading) candidate while waiting for command output.
    static func buildPendingCandidates(source: String) -> [SearchCandidate] {
        [SearchCandidate(word: "\(source) (実行中...)")]
    }

    /// Build candidates for the decrypt list (labels with special reading marker).
    static func buildDecryptListCandidates(labels: [String]) -> [SearchCandidate] {
        labels.map { label in
            SearchCandidate(word: label, reading: "\(decryptReadingPrefix)\(label)")
        }
    }

    // MARK: - Shell Escape

    /// Shell-escape a string for safe use as a single-quoted argument.
    static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Async Execution

    /// Timeout for external command execution.
    static var commandTimeout: TimeInterval = 60.0

    /// Execute the external command with a subcommand and optional argument.
    /// Completion is called on the main thread with stdout lines.
    static func execute(subcommand: String, argument: String? = nil, completion: @escaping ([String]) -> Void) {
        let path = commandPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: path), fm.isExecutableFile(atPath: path) else {
            Log.input.error("External command not found or not executable: \(path)")
            DispatchQueue.main.async { completion([]) }
            return
        }

        var cmd = "\(shellEscape(path)) \(shellEscape(subcommand))"
        if let arg = argument {
            cmd += " \(shellEscape(arg))"
        }

        Log.input.info("External command: \(cmd)")
        let startTime = CFAbsoluteTimeGetCurrent()

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", cmd]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            let timeoutItem = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + commandTimeout, execute: timeoutItem)

            do {
                try process.run()
                process.waitUntilExit()
                timeoutItem.cancel()
            } catch {
                timeoutItem.cancel()
                Log.input.error("External command failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion([]) }
                return
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { !$0.isEmpty }

            Log.input.info("External command completed: \(lines.count) lines, elapsed=\(String(format: "%.0f", elapsed))ms")
            DispatchQueue.main.async { completion(lines) }
        }
    }

    /// Encrypt plaintext via external command.
    static func encrypt(plaintext: String, completion: @escaping ([String]) -> Void) {
        execute(subcommand: "encrypt", argument: plaintext, completion: completion)
    }

    /// List available decrypt labels via external command.
    static func list(completion: @escaping ([String]) -> Void) {
        execute(subcommand: "list", completion: completion)
    }

    /// Decrypt a specific label via external command.
    static func decrypt(label: String, completion: @escaping ([String]) -> Void) {
        execute(subcommand: "decrypt", argument: label, completion: completion)
    }

    /// Interactive decrypt: shows GUI for label selection, then decrypts.
    static func decryptInteractive(completion: @escaping ([String]) -> Void) {
        execute(subcommand: "decrypt-interactive", completion: completion)
    }
}
