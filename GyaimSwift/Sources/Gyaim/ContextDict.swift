import Foundation

/// Context-conditioned learning dictionary (Mozc-style context bigram).
///
/// Records `(left-context suffix, reading, committed word)` at commit time and
/// returns a context affinity score at rerank time so that exact-reading
/// homophones (e.g. "向き" / "無機") can be chosen from the user's own history
/// without calling the model. Entries live in `~/.gyaim/contextdict.txt`.
///
/// Like WordSearch.studyDict, state is process-wide: InputMethodKit creates a
/// controller per client app, and per-instance storage would let one instance
/// overwrite another's entries on save (BUG-005).
final class ContextDict {
    struct Entry: Equatable {
        var contextKey: String
        var reading: String
        var word: String
        var lastAccessTime: TimeInterval
        var count: Int
    }

    static let shared = ContextDict()

    // MARK: - Enable Setting (issue #58 / #61)

    private static let enabledKey = "contextLearningEnabled"

    /// Context-conditioned learning can be disabled from Preferences. When
    /// off, nothing is recorded and affinity always returns 0 — existing
    /// entries are kept so re-enabling restores the learned preferences.
    static var isEnabled: Bool {
        GyaimSettings.bool(forKey: enabledKey, default: true)
    }

    static func setEnabled(_ value: Bool) {
        GyaimSettings.set(value, forKey: enabledKey)
    }

    static let maxEntries = 5_000
    /// Stored context is limited to the trailing characters that carry the
    /// selectional preference (e.g. "どちらの", "この素材は").
    static let maxContextKeyLength = 8
    /// A suffix overlap below this length is treated as noise.
    static let minAffinityMatchLength = 2
    /// Overlap length at which affinity saturates to 1.0.
    static let fullAffinityMatchLength = 4

    private let lock = NSLock()
    private var entries: [Entry] = []
    /// word+reading → entry indices, rebuilt on mutation. Keeps affinity lookup
    /// O(1) per candidate so the fast-context path stays within its latency gate.
    private var indexByWordReading: [String: [Int]] = [:]
    private var file: String = Config.contextDictFile
    private var loaded = false

    /// Test hook: point at a different file and drop in-memory state.
    func configure(file: String) {
        lock.lock()
        defer { lock.unlock() }
        self.file = file
        entries = []
        indexByWordReading = [:]
        loaded = false
    }

    // MARK: - Recording

    func record(context: String,
                reading: String,
                word: String,
                now: TimeInterval = Date().timeIntervalSince1970) {
        guard Self.isEnabled else { return }
        let key = Self.contextKey(from: context)
        guard !key.isEmpty, !reading.isEmpty, !word.isEmpty,
              !reading.contains("\t"), !word.contains("\t") else { return }

        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        if let index = entries.firstIndex(where: {
            $0.contextKey == key && $0.reading == reading && $0.word == word
        }) {
            var entry = entries.remove(at: index)
            entry.lastAccessTime = now
            entry.count += 1
            entries.insert(entry, at: 0)
        } else {
            entries.insert(Entry(contextKey: key,
                                 reading: reading,
                                 word: word,
                                 lastAccessTime: now,
                                 count: 1), at: 0)
        }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        rebuildIndex()
        save()
        Log.dict.debug("ContextDict recorded: key=\"\(key)\" reading=\"\(reading)\" word=\"\(word)\"")
    }

    // MARK: - Affinity

    /// Returns 0.0...1.0 describing how strongly the user's history binds this
    /// (reading, word) pair to the current left context. 0 means no evidence.
    func affinity(context: String?, reading: String?, word: String) -> Double {
        guard Self.isEnabled, let reading, !reading.isEmpty else { return 0 }
        let currentKey = Self.contextKey(from: context ?? "")
        guard currentKey.count >= Self.minAffinityMatchLength else { return 0 }

        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        guard let indices = indexByWordReading[Self.indexKey(reading: reading, word: word)] else { return 0 }
        var best = 0.0
        for index in indices {
            let entry = entries[index]
            let matchLength = Self.commonSuffixLength(entry.contextKey, currentKey)
            guard matchLength >= Self.minAffinityMatchLength else { continue }
            best = max(best, Self.affinityScore(matchLength: matchLength))
        }
        return best
    }

    // MARK: - Deletion

    /// Purge all context entries for a (word, reading) pair. Called from the
    /// candidate deletion UI so context memory cannot resurrect a deleted word.
    @discardableResult
    func deleteEntries(word: String, reading: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        let before = entries.count
        entries.removeAll { $0.word == word && $0.reading == reading }
        guard entries.count < before else { return false }
        rebuildIndex()
        save()
        Log.dict.info("Deleted from context dict: \"\(word)\" (reading: \"\(reading)\")")
        return true
    }

    /// Number of learned context entries (for the Preferences UI).
    func entryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return entries.count
    }

    /// Remove all learned context entries (Preferences "clear" button).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        entries = []
        rebuildIndex()
        save()
        Log.dict.info("ContextDict cleared")
    }

    // MARK: - Pure helpers (testable)

    static func contextKey(from context: String) -> String {
        let sanitized = context
            .replacingOccurrences(of: "\t", with: "")
            .components(separatedBy: .newlines)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(sanitized.suffix(maxContextKeyLength))
    }

    static func commonSuffixLength(_ lhs: String, _ rhs: String) -> Int {
        var length = 0
        var leftIndex = lhs.endIndex
        var rightIndex = rhs.endIndex
        while leftIndex > lhs.startIndex, rightIndex > rhs.startIndex {
            leftIndex = lhs.index(before: leftIndex)
            rightIndex = rhs.index(before: rightIndex)
            guard lhs[leftIndex] == rhs[rightIndex] else { break }
            length += 1
        }
        return length
    }

    static func affinityScore(matchLength: Int) -> Double {
        guard matchLength >= minAffinityMatchLength else { return 0 }
        return min(1.0, Double(matchLength) / Double(fullAffinityMatchLength))
    }

    // MARK: - File I/O

    private static func indexKey(reading: String, word: String) -> String {
        "\(reading)\t\(word)"
    }

    private func rebuildIndex() {
        indexByWordReading = [:]
        for (offset, entry) in entries.enumerated() {
            indexByWordReading[Self.indexKey(reading: entry.reading, word: entry.word), default: []].append(offset)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        entries = Self.load(file: file)
        rebuildIndex()
        Log.dict.info("ContextDict loaded: \(self.entries.count) entries")
    }

    private func save() {
        Self.save(file: file, entries: entries)
    }

    static func load(file: String) -> [Entry] {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        var entries: [Entry] = []
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 5,
                  let timestamp = Double(parts[3]),
                  let count = Int(parts[4]) else { continue }
            entries.append(Entry(contextKey: String(parts[0]),
                                 reading: String(parts[1]),
                                 word: String(parts[2]),
                                 lastAccessTime: timestamp,
                                 count: count))
        }
        return entries
    }

    static func save(file: String, entries: [Entry]) {
        let lines = entries.map { entry in
            "\(entry.contextKey)\t\(entry.reading)\t\(entry.word)\t\(entry.lastAccessTime)\t\(entry.count)"
        }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        do {
            try content.write(toFile: file, atomically: true, encoding: .utf8)
        } catch {
            Log.dict.error("Failed to save context dict \(file): \(error.localizedDescription)")
        }
    }
}
