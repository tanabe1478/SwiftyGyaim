import Foundation
#if canImport(os)
import os
#endif

// MARK: - Log (Entry Point)

enum Log {
    static let subsystem = "com.pitecan.inputmethod.SwiftyGyaim"

    static var isEnabled: Bool {
        GyaimSettings.bool(forKey: "loggingEnabled")
    }

    static func setEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: "loggingEnabled")
    }

    // Public category loggers
    static let input      = GLogger(category: "input")
    static let dict       = GLogger(category: "dict")
    static let conversion = GLogger(category: "conversion")
    static let ui         = GLogger(category: "ui")
    static let config     = GLogger(category: "config")
}

// MARK: - GLogger (Wrapper)

/// Category logger that respects Log.isEnabled and writes to FileLogger.
/// On Apple platforms it also forwards to os.Logger (unified logging); on
/// other platforms (Windows/Linux server, ADR-035) the file log is the only sink.
struct GLogger {
    private let category: String
    #if canImport(os)
    private let logger: Logger
    #endif

    init(category: String) {
        self.category = category
        #if canImport(os)
        self.logger = Logger(subsystem: Log.subsystem, category: category)
        #endif
    }

    func debug(_ message: @autoclosure () -> String) {
        guard Log.isEnabled else { return }
        let msg = message()
        #if canImport(os)
        logger.debug("\(msg)")
        #endif
    }

    func info(_ message: @autoclosure () -> String) {
        guard Log.isEnabled else { return }
        let msg = message()
        #if canImport(os)
        logger.info("\(msg)")
        #endif
        FileLogger.shared.write(category: category, level: "info", message: msg)
    }

    /// Logs regardless of Log.isEnabled (os_log notice + file).
    /// Reserved for rare, high-diagnostic-value events (e.g. Secure Event
    /// Input residue, issue #85) that must leave a trace even when the user
    /// has logging turned off. Keep the call volume near zero.
    func notice(_ message: @autoclosure () -> String) {
        let msg = message()
        #if canImport(os)
        logger.notice("\(msg)")
        #endif
        FileLogger.shared.write(category: category, level: "notice", message: msg)
    }

    func warning(_ message: @autoclosure () -> String) {
        guard Log.isEnabled else { return }
        let msg = message()
        #if canImport(os)
        logger.warning("\(msg)")
        #endif
        FileLogger.shared.write(category: category, level: "warning", message: msg)
    }

    func error(_ message: @autoclosure () -> String) {
        guard Log.isEnabled else { return }
        let msg = message()
        #if canImport(os)
        logger.error("\(msg)")
        #endif
        FileLogger.shared.write(category: category, level: "error", message: msg)
    }
}

// MARK: - FileLogger

/// Writes info+ log lines to ~/.gyaim/gyaim.log with size-based rotation.
///
/// Rotation keeps `maxRotatedFiles` generations (gyaim.log.1 ... .7). With
/// one generation, ~4-5 MB/day of dogfood logging left only about two days
/// on disk, so the weekly aggregation (`aggregate-fast-context-log.py
/// --last-minutes 10080`) silently covered a fraction of the week.
final class FileLogger {
    static let shared = FileLogger()

    static let maxRotatedFiles = 7

    private let queue = DispatchQueue(label: "com.pitecan.inputmethod.SwiftyGyaim.filelogger")
    private let logPath: String
    private let maxSize: Int64 = 5 * 1024 * 1024  // 5 MB
    private var fileHandle: FileHandle?

    /// gyaim.log.1 (newest) ... gyaim.log.N (oldest)
    private var rotatedPaths: [String] {
        (1...Self.maxRotatedFiles).map { "\(logPath).\($0)" }
    }

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        logPath = "\(Config.gyaimDir)/gyaim.log"
    }

    func write(category: String, level: String, message: String) {
        queue.async { [self] in
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(category)] [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if fileHandle == nil {
                openFile()
            }
            fileHandle?.write(data)
            rotateIfNeeded()
        }
    }

    func flush() {
        queue.async { [self] in
            fileHandle?.synchronizeFile()
        }
    }

    /// Delete log files and reopen handle.
    func clearLog() {
        queue.async { [self] in
            fileHandle?.closeFile()
            fileHandle = nil
            let fm = FileManager.default
            try? fm.removeItem(atPath: logPath)
            for path in rotatedPaths {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// Returns the current log file size in bytes (synchronous, for UI).
    func logFileSize() -> Int64 {
        let fm = FileManager.default
        return ([logPath] + rotatedPaths).reduce(Int64(0)) { total, path in
            total + ((try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    // MARK: - Private

    private func openFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logPath)
        fileHandle?.seekToEndOfFile()
    }

    private func rotateIfNeeded() {
        guard let handle = fileHandle else { return }
        let size = handle.offsetInFile
        guard size > maxSize else { return }

        handle.closeFile()
        fileHandle = nil

        Self.shiftRotatedFiles(logPath: logPath, rotatedPaths: rotatedPaths)

        openFile()
    }

    /// Drop the oldest generation, shift .N-1 -> .N ... .1 -> .2, then move
    /// the live log to .1. Pure file-system step, exposed for tests.
    static func shiftRotatedFiles(logPath: String, rotatedPaths: [String], fileManager fm: FileManager = .default) {
        guard let oldest = rotatedPaths.last else { return }
        try? fm.removeItem(atPath: oldest)
        for index in stride(from: rotatedPaths.count - 1, to: 0, by: -1) {
            let from = rotatedPaths[index - 1]
            let to = rotatedPaths[index]
            if fm.fileExists(atPath: from) {
                try? fm.moveItem(atPath: from, toPath: to)
            }
        }
        try? fm.moveItem(atPath: logPath, toPath: rotatedPaths[0])
    }
}

// MARK: - PerfLog

enum PerfLog {
    static func measure<T>(_ label: String, logger: GLogger, _ block: () -> T) -> T {
        guard Log.isEnabled else { return block() }
        let start = Date().timeIntervalSinceReferenceDate
        let result = block()
        let elapsed = (Date().timeIntervalSinceReferenceDate - start) * 1000
        logger.info("\(label): \(String(format: "%.1f", elapsed))ms")
        return result
    }
}
