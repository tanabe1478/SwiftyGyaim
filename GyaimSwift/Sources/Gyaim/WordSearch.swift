import Foundation

/// A search result candidate.
struct SearchCandidate: Equatable {
    let word: String
    let reading: String?

    init(word: String, reading: String? = nil) {
        self.word = word
        self.reading = reading
    }
}

/// Three-tier dictionary search system.
/// Priority: study dict > local dict > connection dict.
/// Ported from WordSearch.rb (Toshiyuki Masui, 2011-2015)
class WordSearch {
    // MARK: - Exact Reading Match Priority Setting

    private static let exactReadingMatchPriorityKey = "exactReadingMatchPriority"

    /// When enabled, candidates with exact reading match are prioritized over prefix-only matches.
    /// Default: false (preserves existing MRU-only behavior).
    static var isExactReadingMatchPriority: Bool {
        UserDefaults.standard.bool(forKey: exactReadingMatchPriorityKey)
    }

    static func setExactReadingMatchPriority(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: exactReadingMatchPriorityKey)
    }

    // MARK: - Study Hiragana Setting

    private static let studyHiraganaKey = "studyHiraganaEnabled"

    static var isStudyHiraganaEnabled: Bool {
        UserDefaults.standard.object(forKey: studyHiraganaKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: studyHiraganaKey)
    }

    static func setStudyHiraganaEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: studyHiraganaKey)
    }

    /// Returns true if the string consists entirely of hiragana characters (U+3040-U+309F).
    static func isAllHiragana(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 0x3040 && $0.value <= 0x309F }
    }

    private let connectionDict: ConnectionDict
    private let localDictFile: String
    private let studyDictFile: String
    private var localDict: [[String]]   // [[yomi, word], ...]
    private var studyDict: [StudyEntry]
    private var localDictTime: Date
    private var searchMode: Int = 0

    init(connectionDictFile: String, localDictFile: String, studyDictFile: String) {
        self.localDictFile = localDictFile
        self.studyDictFile = studyDictFile
        self.connectionDict = PerfLog.measure("ConnectionDict load", logger: Log.dict) {
            ConnectionDict(dictFile: connectionDictFile)
        }
        self.localDict = Self.loadDict(dictFile: localDictFile)
        self.localDictTime = Self.fileModTime(localDictFile)
        self.studyDict = Self.loadStudyDict(dictFile: studyDictFile)
        Log.dict.info("WordSearch initialized: local=\(localDict.count), study=\(studyDict.count) entries")
    }

    /// Main search method.
    /// - Parameters:
    ///   - query: Input romaji pattern
    ///   - searchMode: 0 = prefix, 1 = exact, 2 = Google Transliterate (handled by Controller)
    ///   - limit: Max results (0 = unlimited)
    /// - Returns: Array of SearchCandidate
    func search(query: String, searchMode: Int, limit: Int = 0) -> [SearchCandidate] {
        self.searchMode = searchMode
        guard !query.isEmpty else { return [] }

        // Reload local dict if modified externally
        let currentMtime = Self.fileModTime(localDictFile)
        if currentMtime > localDictTime {
            localDict = Self.loadDict(dictFile: localDictFile)
            localDictTime = currentMtime
            Log.dict.info("Local dict hot-reloaded: \(localDict.count) entries")
        }

        var q = query
        var candfound: Set<String> = []
        var candidates: [SearchCandidate] = []

        // Special: Google transliteration (configurable suffix trigger)
        // The actual Google API call is handled by GyaimController;
        // WordSearch returns empty so the controller can fire the async request.
        if GoogleTransliterate.hasTriggerSuffix(q) {
            return candidates
        }

        // Special: color image (#suffix)
        if q.count > 1, q.hasSuffix("#") {
            q.removeLast()
            // Image generation — placeholder
            return candidates
        }

        // Special: image search (!suffix)
        if q.count > 1, q.hasSuffix("!") {
            q.removeLast()
            return candidates
        }

        // Special: timestamp
        if q == "ds" {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
            candidates.append(SearchCandidate(word: formatter.string(from: Date())))
            return candidates
        }

        // Special: uppercase → pass through
        if q.range(of: "[A-Z]", options: .regularExpression) != nil {
            candidates.append(SearchCandidate(word: q, reading: q))
            return candidates
        }

        // Normal search
        let escaped = NSRegularExpression.escapedPattern(for: q)
        let pattern = searchMode > 0 ? "^\(escaped)$" : "^\(escaped)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return candidates }

        let exactPriority = searchMode == 0 && Self.isExactReadingMatchPriority

        // Search study dict
        if exactPriority {
            // Pass 1: exact reading matches first
            for entry in studyDict {
                if entry.reading == q, !candfound.contains(entry.word) {
                    candidates.append(SearchCandidate(word: entry.word, reading: entry.reading))
                    candfound.insert(entry.word)
                    if limit > 0, candidates.count >= limit { break }
                }
            }
            // Pass 2: prefix-only matches
            if limit == 0 || candidates.count < limit {
                for entry in studyDict {
                    let range = NSRange(entry.reading.startIndex..., in: entry.reading)
                    if regex.firstMatch(in: entry.reading, range: range) != nil,
                       !candfound.contains(entry.word) {
                        candidates.append(SearchCandidate(word: entry.word, reading: entry.reading))
                        candfound.insert(entry.word)
                        if limit > 0, candidates.count >= limit { break }
                    }
                }
            }
        } else {
            for entry in studyDict {
                let range = NSRange(entry.reading.startIndex..., in: entry.reading)
                if regex.firstMatch(in: entry.reading, range: range) != nil {
                    if !candfound.contains(entry.word) {
                        candidates.append(SearchCandidate(word: entry.word, reading: entry.reading))
                        candfound.insert(entry.word)
                        if limit > 0, candidates.count >= limit { break }
                    }
                }
            }
        }

        // Search local dict
        if limit == 0 || candidates.count < limit {
            if exactPriority {
                // Pass 1: exact reading matches first
                for entry in localDict {
                    guard entry.count >= 2 else { continue }
                    let yomi = entry[0]
                    let word = entry[1]
                    if yomi == q, !candfound.contains(word) {
                        candidates.append(SearchCandidate(word: word, reading: yomi))
                        candfound.insert(word)
                        if limit > 0, candidates.count >= limit { break }
                    }
                }
                // Pass 2: prefix-only matches
                if limit == 0 || candidates.count < limit {
                    for entry in localDict {
                        guard entry.count >= 2 else { continue }
                        let yomi = entry[0]
                        let word = entry[1]
                        let range = NSRange(yomi.startIndex..., in: yomi)
                        if regex.firstMatch(in: yomi, range: range) != nil,
                           !candfound.contains(word) {
                            candidates.append(SearchCandidate(word: word, reading: yomi))
                            candfound.insert(word)
                            if limit > 0, candidates.count >= limit { break }
                        }
                    }
                }
            } else {
                for entry in localDict {
                    guard entry.count >= 2 else { continue }
                    let yomi = entry[0]
                    let word = entry[1]
                    let range = NSRange(yomi.startIndex..., in: yomi)
                    if regex.firstMatch(in: yomi, range: range) != nil {
                        if !candfound.contains(word) {
                            candidates.append(SearchCandidate(word: word, reading: yomi))
                            candfound.insert(word)
                            if limit > 0, candidates.count >= limit { break }
                        }
                    }
                }
            }
        }

        // Search connection dict
        connectionDict.search(pat: q, searchMode: searchMode) { word, pat, _ in
            if limit > 0 { guard candidates.count < limit else { return } }
            var w = word
            if w.hasSuffix("*") { return }
            w = w.replacingOccurrences(of: "*", with: "")
            if !candfound.contains(w) {
                candidates.append(SearchCandidate(word: w, reading: pat))
                candfound.insert(w)
            }
        }
        // Limit results
        if limit > 0, candidates.count > limit {
            candidates = Array(candidates.prefix(limit))
        }

        return candidates
    }

    /// Register a word to the user's local dictionary.
    func register(word: String, reading: String) {
        localDict.removeAll { $0 == [reading, word] }
        localDict.insert([reading, word], at: 0)
        Self.saveDict(dictFile: localDictFile, dict: localDict)
        localDictTime = Self.fileModTime(localDictFile)
    }

    /// Learn a word to the study dictionary.
    func study(word: String, reading: String) {
        if !Self.isStudyHiraganaEnabled && Self.isAllHiragana(word) {
            Log.dict.debug("Study skipped (hiragana): \"\(word)\" (reading: \"\(reading)\")")
            return
        }
        if reading.count > 1 {
            var registered = false
            connectionDict.search(pat: reading, searchMode: searchMode) { w, _, _ in
                var cleaned = w
                if cleaned.hasSuffix("*") { return }
                cleaned = cleaned.replacingOccurrences(of: "*", with: "")
                if cleaned == word {
                    registered = true
                }
            }
            if !registered {
                // If in study dict but not connection dict, promote to local dict
                if studyDict.contains(where: { $0.reading == reading && $0.word == word }) {
                    register(word: word, reading: reading)
                }
            }
        }

        let now = Date().timeIntervalSince1970
        if let idx = studyDict.firstIndex(where: { $0.reading == reading && $0.word == word }) {
            var entry = studyDict.remove(at: idx)
            entry.lastAccessTime = now
            entry.frequency += 1
            studyDict.insert(entry, at: 0)
        } else {
            studyDict.insert(StudyEntry(reading: reading, word: word,
                                         lastAccessTime: now, frequency: 1), at: 0)
        }

        evict()
    }

    private static let maxStudyEntries = 10_000

    private func evict() {
        switch EvictionMode.current {
        case .mru, .none:
            if studyDict.count > Self.maxStudyEntries {
                studyDict = Array(studyDict.prefix(Self.maxStudyEntries))
            }
        case .scoreBased:
            if studyDict.count > Self.maxStudyEntries {
                let protectedCount = min(100, studyDict.count)
                let range = protectedCount..<studyDict.count
                if let minIdx = range.min(by: { studyDict[$0].score() < studyDict[$1].score() }) {
                    studyDict.remove(at: minIdx)
                }
            }
        }
    }

    func start() {
        // Intentionally empty — reloading study dict caused input lag in original
    }

    func finish() {
        Self.saveStudyDict(dictFile: studyDictFile, dict: studyDict)
    }

    // MARK: - File I/O

    static func loadDict(dictFile: String) -> [[String]] {
        var dict: [[String]] = []
        let content: String
        do {
            content = try String(contentsOfFile: dictFile, encoding: .utf8)
        } catch {
            Log.dict.error("Failed to load dict \(dictFile): \(error.localizedDescription)")
            return dict
        }
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("#") || s.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = s.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count >= 2 {
                dict.append([String(parts[0]), String(parts[1])])
            }
        }
        return dict
    }

    static func saveDict(dictFile: String, dict: [[String]]) {
        var saved: Set<String> = []
        var lines: [String] = []
        for entry in dict {
            guard entry.count >= 2 else { continue }
            let s = "\(entry[0])\t\(entry[1])"
            if !saved.contains(s) {
                lines.append(s)
                saved.insert(s)
            }
        }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        do {
            try content.write(toFile: dictFile, atomically: true, encoding: .utf8)
        } catch {
            Log.dict.error("Failed to save dict \(dictFile): \(error.localizedDescription)")
        }
    }

    // MARK: - Study Dict I/O

    static func loadStudyDict(dictFile: String) -> [StudyEntry] {
        var entries: [StudyEntry] = []
        let content: String
        do {
            content = try String(contentsOfFile: dictFile, encoding: .utf8)
        } catch {
            Log.dict.error("Failed to load study dict \(dictFile): \(error.localizedDescription)")
            return entries
        }
        let now = Date().timeIntervalSince1970
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("#") || s.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = s.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count >= 4,
               let timestamp = Double(parts[2]),
               let freq = Int(parts[3]) {
                // New 4-column format
                entries.append(StudyEntry(reading: String(parts[0]), word: String(parts[1]),
                                          lastAccessTime: timestamp, frequency: freq))
            } else if parts.count >= 2 {
                // Legacy 2-column format
                entries.append(StudyEntry(reading: String(parts[0]), word: String(parts[1]),
                                          lastAccessTime: now, frequency: 1))
            }
        }
        return entries
    }

    static func saveStudyDict(dictFile: String, dict: [StudyEntry]) {
        var saved: Set<String> = []
        var lines: [String] = []
        for entry in dict {
            let key = "\(entry.reading)\t\(entry.word)"
            if !saved.contains(key) {
                lines.append("\(entry.reading)\t\(entry.word)\t\(entry.lastAccessTime)\t\(entry.frequency)")
                saved.insert(key)
            }
        }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        do {
            try content.write(toFile: dictFile, atomically: true, encoding: .utf8)
        } catch {
            Log.dict.error("Failed to save study dict \(dictFile): \(error.localizedDescription)")
        }
    }

    private static func fileModTime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date.distantPast
    }
}
