import Foundation

/// One entry of the connection dictionary, keyed by its kana reading (ADR-033).
struct DictEntry {
    /// Reading as hiragana. Romaji rows are converted at load; several romaji
    /// spellings of one reading (shuusei / syuusei) collapse into one entry.
    let kana: String
    let word: String
    let inConnection: Int
    let outConnection: Int
    let canStart: Bool
    let canTerminate: Bool
    let contributesSurface: Bool

    init(kana: String, word: String, inConnection: Int, outConnection: Int) {
        self.kana = kana
        self.word = word.utf8.contains(UInt8(ascii: "*")) ? word.replacingOccurrences(of: "*", with: "") : word
        self.inConnection = inConnection
        self.outConnection = outConnection
        let internalLabel = Self.isInternalConnectionLabel(word)
        self.canStart = !word.hasPrefix("*") && !internalLabel
        self.canTerminate = !word.hasSuffix("*") && !internalLabel
        self.contributesSurface = !internalLabel
    }

    private static func isInternalConnectionLabel(_ word: String) -> Bool {
        [
            "い形容詞",
            "な形容詞",
            "形容詞語尾",
            "動詞語尾",
            "名詞接続",
            "終止接続",
            "連用接続",
        ].contains(word)
    }
}

struct ConnectionSearchResult {
    let word: String
    let pat: String
    let outConnection: Int
    let depth: Int
}

/// A complete, connection-grammatical composition of a reading (issue #59).
struct ConnectionComposition: Equatable {
    let word: String
    let depth: Int
}

/// Morphological connection dictionary for compound word matching.
/// Ported from ConnectionDict.rb (Toshiyuki Masui, 2011). Since ADR-033 the
/// entries are indexed by kana: a typed romaji query is converted to kana (plus
/// the incomplete trailing letters) and matched against every spelling at once.
///
/// Memory (ADR-034, 340k entries): each group keeps only an array of entry
/// indices in kana order, searched by bisection, and per-first-kana lists in
/// dictionary order. Hash maps keyed by kana cost ~70 MB more.
class ConnectionDict {
    /// Kana lookup over one group of entries: everything that can start a
    /// composition, or everything a connection class accepts.
    struct KanaIndex {
        /// Entry indices ordered by kana (scalar order), then dictionary order.
        var sorted: [Int] = []
        /// Entry indices in dictionary order, by first kana scalar.
        var byFirstScalar: [UInt32: [Int]] = [:]
    }

    private struct Query {
        let romaji: String
        let scalars: [UInt32]
        let tail: String
        let romajiEnds: [Int]
        let predictions: Bool

        /// The typed romaji that produced the first `count` kana characters.
        func typedRomaji(upToKana count: Int) -> String {
            guard count > 0, count <= romajiEnds.count else { return "" }
            return String(romaji.prefix(romajiEnds[count - 1]))
        }
    }

    struct Step {
        let offset: Int
        let foundWord: String
        let depth: Int
    }

    private enum MatchKind {
        case exact
        case prediction
        case compound(length: Int)
    }

    private struct EntryKey: Hashable {
        let kana: String
        let word: String
        let inConnection: Int
        let outConnection: Int
    }

    private(set) var dict: [DictEntry] = []
    private(set) var startIndex = KanaIndex()
    private(set) var connectionIndex: [Int: KanaIndex] = [:]
    let romaKana = RomaKana()

    convenience init(dictFile: String) {
        self.init(dictFiles: [dictFile])
    }

    /// Later files extend earlier ones; entries keep file order, which is the
    /// order results are emitted in.
    init(dictFiles: [String]) {
        var seen: Set<EntryKey> = []  // across all files: the first file's row wins
        for file in dictFiles { readDict(file, seen: &seen) }
        buildIndex()
        Log.dict.info("ConnectionDict loaded: \(dict.count) entries from \(dictFiles.count) file(s)")
    }

    var entryCount: Int { dict.count }

    private func readDict(_ path: String, seen: inout Set<EntryKey>) {
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            Log.dict.error("Failed to read connection dict \(path): \(error.localizedDescription)")
            return
        }
        // Byte-level splitting: Character iteration over a 12 MB file costs
        // hundreds of milliseconds at IME start-up.
        let newline = UInt8(ascii: "\n"), tab = UInt8(ascii: "\t"), hash = UInt8(ascii: "#")
        for line in content.utf8.split(separator: newline, omittingEmptySubsequences: true) {
            guard line.first != hash, line.contains(where: { $0 != 32 && $0 != 9 && $0 != 13 }) else { continue }
            let fields = line.split(separator: tab, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            guard let reading = String(fields[0]), let word = String(fields[1]) else { continue }
            let inConn = fields.count > 2 ? Int(String(fields[2]) ?? "") ?? 0 : 0
            let outConn = fields.count > 3 ? Int(String(fields[3]) ?? "") ?? 0 : 0
            let kana = romaKana.roma2kanaKey(reading)
            guard !kana.isEmpty,
                  seen.insert(EntryKey(kana: kana, word: word, inConnection: inConn, outConnection: outConn)).inserted
            else { continue }
            dict.append(DictEntry(kana: kana, word: word, inConnection: inConn, outConnection: outConn))
        }
    }

    private func buildIndex() {
        for (index, entry) in dict.enumerated() {
            guard let first = entry.kana.unicodeScalars.first?.value else { continue }
            if entry.canStart { startIndex.byFirstScalar[first, default: []].append(index) }
            connectionIndex[entry.inConnection, default: KanaIndex()].byFirstScalar[first, default: []].append(index)
        }
        // One global kana sort on temporary scalar arrays, then one pass
        // distributing the order to every group.
        let keys = dict.map { $0.kana.unicodeScalars.map(\.value) }
        let order = dict.indices.sorted { lhs, rhs in Self.precedes(keys[lhs], keys[rhs], tieBreak: lhs < rhs) }
        for index in order {
            let entry = dict[index]
            if entry.canStart { startIndex.sorted.append(index) }
            connectionIndex[entry.inConnection]?.sorted.append(index)
        }
    }

    private static func precedes(_ lhs: [UInt32], _ rhs: [UInt32], tieBreak: @autoclosure () -> Bool) -> Bool {
        let count = min(lhs.count, rhs.count)
        var position = 0
        while position < count {
            if lhs[position] != rhs[position] { return lhs[position] < rhs[position] }
            position += 1
        }
        return lhs.count == rhs.count ? tieBreak() : lhs.count < rhs.count
    }

    /// Lexicographic comparison of an entry's kana with query scalars:
    /// negative when the kana sorts first, zero when equal.
    private static func compare(_ kana: String, with target: ArraySlice<UInt32>) -> Int {
        var targetIndex = target.startIndex
        for scalar in kana.unicodeScalars {
            guard targetIndex < target.endIndex else { return 1 }
            if scalar.value != target[targetIndex] { return scalar.value < target[targetIndex] ? -1 : 1 }
            targetIndex += 1
        }
        return targetIndex == target.endIndex ? 0 : -1
    }

    private static func hasPrefix(_ kana: String, _ prefix: ArraySlice<UInt32>) -> Bool {
        var prefixIndex = prefix.startIndex
        for scalar in kana.unicodeScalars {
            if prefixIndex == prefix.endIndex { return true }
            if scalar.value != prefix[prefixIndex] { return false }
            prefixIndex += 1
        }
        return prefixIndex == prefix.endIndex
    }

    /// Position of the first entry of `sorted` whose kana is not before `target`.
    private func lowerBound(_ sorted: [Int], _ target: ArraySlice<UInt32>) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if Self.compare(dict[sorted[mid]].kana, with: target) < 0 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Entries of `index` whose kana equals `target`, in dictionary order.
    func entries(in index: KanaIndex, matching target: ArraySlice<UInt32>) -> [Int] {
        var position = lowerBound(index.sorted, target)
        var result: [Int] = []
        while position < index.sorted.count, Self.compare(dict[index.sorted[position]].kana, with: target) == 0 {
            result.append(index.sorted[position])
            position += 1
        }
        return result
    }

    /// Entries whose kana extends `prefix` and whose next kana unit can be
    /// spelled starting with `tail`, in dictionary order. Entries that share the
    /// next unit are adjacent in kana order, so a unit is checked once per run.
    private func longerEntries(in index: KanaIndex, prefix: ArraySlice<UInt32>, tail: String) -> [Int] {
        var position = lowerBound(index.sorted, prefix)
        var result: [Int] = []
        var currentUnit: KanaUnit?
        var unitMatches = true
        while position < index.sorted.count {
            let entry = dict[index.sorted[position]]
            position += 1
            guard Self.hasPrefix(entry.kana, prefix) else { break }
            guard let unit = RomaKana.kanaUnit(in: entry.kana.unicodeScalars, at: prefix.count) else { continue }
            if unit != currentUnit {
                currentUnit = unit
                unitMatches = romaKana.unitMatches(tail: tail, unit: unit)
            }
            if unitMatches { result.append(index.sorted[position - 1]) }
        }
        return result.sorted()
    }

    /// Entries whose first kana unit can be spelled starting with `tail`, in
    /// dictionary order, at most `limit` (a one-letter query on a large
    /// dictionary has tens of thousands; only the head is ever shown).
    private func entriesStarting(in index: KanaIndex, tail: String, limit: Int) -> [Int] {
        let lists = romaKana.firstScalars(compatibleWith: tail).compactMap { index.byFirstScalar[$0] }
        var positions = [Int](repeating: 0, count: lists.count)
        var result: [Int] = []
        while result.count < limit {
            var best: Int?
            for listIndex in lists.indices where positions[listIndex] < lists[listIndex].count {
                let candidate = lists[listIndex][positions[listIndex]]
                if let current = best, lists[current][positions[current]] <= candidate { continue }
                best = listIndex
            }
            guard let best else { break }
            let candidate = lists[best][positions[best]]
            positions[best] += 1
            if let unit = RomaKana.kanaUnit(in: dict[candidate].kana.unicodeScalars, at: 0),
               romaKana.unitMatches(tail: tail, unit: unit) {
                result.append(candidate)
            }
        }
        return result
    }

    // MARK: - Search

    /// Search the dictionary for matches.
    /// - Parameters:
    ///   - pat: Input romaji pattern
    ///   - searchMode: 0 = prefix matching, 1 = exact matching
    ///   - callback: (word, matchedPat, outConnection) for each result
    func search(pat: String, searchMode: Int,
                callback: (_ word: String, _ pat: String, _ outConnection: Int) -> Void) {
        searchDetailed(pat: pat, searchMode: searchMode) { result in
            callback(result.word, result.pat, result.outConnection)
        }
    }

    /// Search the dictionary and include metadata about the connection path.
    /// Results come in dictionary order, depth first, as the original linked-list
    /// walk emitted them; `maxResults` stops the walk (the tail of a one-letter
    /// query is never displayed).
    func searchDetailed(pat: String, searchMode: Int, maxResults: Int = .max,
                        callback: (_ result: ConnectionSearchResult) -> Void) {
        let conversion = searchMode == 0
            ? romaKana.roma2kanaPrefix(pat)
            : KanaPrefixConversion(kana: romaKana.roma2kanaKey(pat), tail: "", romajiEnds: [])
        guard !conversion.kana.isEmpty || !conversion.tail.isEmpty else { return }
        let query = Query(romaji: pat, scalars: conversion.kana.unicodeScalars.map(\.value), tail: conversion.tail,
                          romajiEnds: conversion.romajiEnds, predictions: searchMode == 0)
        var budget = maxResults
        generate(startIndex, query, Step(offset: 0, foundWord: "", depth: 0), budget: &budget, callback: callback)
    }

    private func matches(in index: KanaIndex, _ query: Query, offset: Int,
                         limit: Int) -> [(entry: Int, kind: MatchKind)] {
        var found: [(entry: Int, kind: MatchKind)] = []
        let remainingCount = query.scalars.count - offset
        if remainingCount > 0 {
            let remaining = query.scalars[offset...]
            if query.tail.isEmpty {
                found += entries(in: index, matching: remaining).map { ($0, .exact) }
            }
            // An entry that consumes the whole remaining kana continues the
            // composition only while incomplete letters are still pending.
            let longestCompound = query.tail.isEmpty ? remainingCount - 1 : remainingCount
            for length in stride(from: 1, through: longestCompound, by: 1) {
                found += entries(in: index, matching: query.scalars[offset..<(offset + length)])
                    .map { ($0, .compound(length: length)) }
            }
            if query.predictions {
                found += longerEntries(in: index, prefix: remaining, tail: query.tail).prefix(limit).map { ($0, .prediction) }
            }
        } else if query.predictions, !query.tail.isEmpty {
            found += entriesStarting(in: index, tail: query.tail, limit: limit).map { ($0, .prediction) }
        }
        return found.sorted { $0.entry < $1.entry }
    }

    private func generate(_ index: KanaIndex, _ query: Query, _ step: Step, budget: inout Int,
                          callback: (_ result: ConnectionSearchResult) -> Void) {
        for match in matches(in: index, query, offset: step.offset, limit: budget) {
            guard budget > 0 else { return }
            let entry = dict[match.entry]
            let nextWord = entry.contributesSurface ? step.foundWord + entry.word : step.foundWord
            switch match.kind {
            case .exact:
                guard entry.canTerminate else { continue }
                budget -= 1
                callback(ConnectionSearchResult(word: nextWord, pat: query.romaji,
                                                outConnection: entry.outConnection, depth: step.depth + 1))
            case .prediction:
                guard entry.canTerminate else { continue }
                budget -= 1
                let pat = query.typedRomaji(upToKana: step.offset) + romaKana.canonicalRomaji(ofKana: entry.kana)
                callback(ConnectionSearchResult(word: nextWord, pat: pat,
                                                outConnection: entry.outConnection, depth: step.depth + 1))
            case .compound(let length):
                guard let next = connectionIndex[entry.outConnection] else { continue }
                generate(next, query, Step(offset: step.offset + length, foundWord: nextWord, depth: step.depth + 1),
                         budget: &budget, callback: callback)
            }
        }
    }
}
