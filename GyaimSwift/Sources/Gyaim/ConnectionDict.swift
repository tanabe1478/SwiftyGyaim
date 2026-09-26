import Foundation

/// One entry of the connection dictionary, keyed by its kana reading (ADR-033).
struct DictEntry {
    /// Reading as hiragana. Romaji rows are converted at load; several romaji
    /// spellings of one reading (shuusei / syuusei) collapse into one entry.
    let kana: String
    /// `kana` as unicode scalar values, for O(1) indexing and ordering.
    let scalars: [UInt32]
    let word: String
    let inConnection: Int
    let outConnection: Int
    let canStart: Bool
    let canTerminate: Bool
    let contributesSurface: Bool

    init(kana: String, word: String, inConnection: Int, outConnection: Int) {
        self.kana = kana
        self.scalars = kana.unicodeScalars.map(\.value)
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
class ConnectionDict {
    /// Kana lookup over one group of entries: everything that can start a
    /// composition, or everything a connection class accepts.
    struct KanaIndex {
        var byKana: [String: [Int]] = [:]
        /// Entry indices ordered by kana (scalar order), then dictionary order.
        var sorted: [Int] = []
        /// Entry indices in dictionary order, by first kana scalar.
        var byFirstScalar: [UInt32: [Int]] = [:]

        /// Dictionary-order lists; `sorted` is filled from the global kana order.
        mutating func insert(_ index: Int, entry: DictEntry) {
            byKana[entry.kana, default: []].append(index)
            if let first = entry.scalars.first { byFirstScalar[first, default: []].append(index) }
        }
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

        func kanaString(_ range: Range<Int>) -> String {
            String(String.UnicodeScalarView(scalars[range].compactMap(Unicode.Scalar.init)))
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

    private(set) var dict: [DictEntry] = []
    private(set) var startIndex = KanaIndex()
    private(set) var connectionIndex: [Int: KanaIndex] = [:]
    let romaKana = RomaKana()

    convenience init(dictFile: String) {
        self.init(dictFiles: [dictFile])
    }

    /// Later files extend earlier ones; entries keep file order, which is the
    /// order results are emitted in.
    private struct EntryKey: Hashable {
        let kana: String
        let word: String
        let inConnection: Int
        let outConnection: Int
    }

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
            if entry.canStart { startIndex.insert(index, entry: entry) }
            connectionIndex[entry.inConnection, default: KanaIndex()].insert(index, entry: entry)
        }
        // One global kana sort, then one pass distributing the order to every
        // group (sorting each of the ~300k-entry groups separately doubled load time).
        let order = dict.indices.sorted { [dict] lhs, rhs in
            Self.precedes(dict[lhs].scalars, dict[rhs].scalars, tieBreak: lhs < rhs)
        }
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

    /// Entries of `index` whose kana extends `prefix` and whose next kana unit
    /// can be spelled starting with `tail`, in dictionary order. Entries that
    /// share the next unit are adjacent in kana order, so the unit is checked
    /// once per run rather than once per entry.
    private func longerEntries(in index: KanaIndex, prefix: ArraySlice<UInt32>, tail: String) -> [Int] {
        var low = 0, high = index.sorted.count
        while low < high {
            let mid = (low + high) / 2
            if dict[index.sorted[mid]].scalars.lexicographicallyPrecedes(prefix) { low = mid + 1 } else { high = mid }
        }
        var result: [Int] = []
        var currentUnit: ArraySlice<UInt32>?
        var unitMatches = true
        while low < index.sorted.count {
            let entry = dict[index.sorted[low]]
            guard entry.scalars.starts(with: prefix) else { break }
            low += 1
            guard entry.scalars.count > prefix.count else { continue }
            let unit = RomaKana.kanaUnit(in: entry.scalars, at: prefix.count)
            if unit != currentUnit {
                currentUnit = unit
                unitMatches = romaKana.unitMatches(tail: tail, unit: unit)
            }
            if unitMatches { result.append(index.sorted[low - 1]) }
        }
        return result.sorted()
    }

    /// Entries whose first kana unit can be spelled starting with `tail`, in
    /// dictionary order, at most `limit` (a one-letter query on a large
    /// dictionary has tens of thousands; only the head is ever shown).
    private func entriesStarting(in index: KanaIndex, tail: String, limit: Int) -> [Int] {
        var lists: [[Int]] = []
        for scalar in romaKana.firstScalars(compatibleWith: tail) {
            if let list = index.byFirstScalar[scalar] { lists.append(list) }
        }
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
            let entry = dict[candidate]
            if romaKana.unitMatches(tail: tail, unit: RomaKana.kanaUnit(in: entry.scalars, at: 0)) {
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
            if query.tail.isEmpty, let hits = index.byKana[query.kanaString(offset..<query.scalars.count)] {
                found += hits.map { ($0, .exact) }
            }
            // An entry that consumes the whole remaining kana continues the
            // composition only while incomplete letters are still pending.
            let longestCompound = query.tail.isEmpty ? remainingCount - 1 : remainingCount
            for length in stride(from: 1, through: longestCompound, by: 1) {
                if let hits = index.byKana[query.kanaString(offset..<(offset + length))] {
                    found += hits.map { ($0, .compound(length: length)) }
                }
            }
            if query.predictions {
                found += longerEntries(in: index, prefix: query.scalars[offset...], tail: query.tail)
                    .prefix(limit).map { ($0, .prediction) }
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
