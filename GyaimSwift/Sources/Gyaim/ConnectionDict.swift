import Foundation

/// One entry of the connection dictionary, keyed by its kana reading (ADR-033).
struct DictEntry {
    /// Reading as hiragana. Romaji rows are converted at load; several romaji
    /// spellings of one reading (shuusei / syuusei) collapse into one entry.
    let kana: String
    let kanaCharacters: [Character]
    /// First romaji spelling seen for this entry (tools and logs only).
    let pat: String
    let rawWord: String
    let word: String
    let inConnection: Int
    let outConnection: Int
    let canStart: Bool
    let canTerminate: Bool
    let contributesSurface: Bool

    init(kana: String, pat: String, word: String, inConnection: Int, outConnection: Int) {
        self.kana = kana
        self.kanaCharacters = Array(kana)
        self.pat = pat
        self.rawWord = word
        self.word = word.replacingOccurrences(of: "*", with: "")
        self.inConnection = inConnection
        self.outConnection = outConnection
        self.canStart = !word.hasPrefix("*") && !Self.isInternalConnectionLabel(word)
        self.canTerminate = !word.hasSuffix("*") && !Self.isInternalConnectionLabel(word)
        self.contributesSurface = !Self.isInternalConnectionLabel(word)
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
    private struct KanaIndex {
        var byKana: [String: [Int]] = [:]
        var sorted: [Int] = []
        var byFirstCharacter: [Character: [Int]] = [:]

        mutating func insert(_ index: Int, entry: DictEntry) {
            byKana[entry.kana, default: []].append(index)
            sorted.append(index)
            if let first = entry.kanaCharacters.first { byFirstCharacter[first, default: []].append(index) }
        }
    }

    private struct Query {
        let romaji: String
        let kana: [Character]
        let tail: String
        let romajiEnds: [Int]
        let predictions: Bool

        /// The typed romaji that produced the first `count` kana characters.
        func typedRomaji(upToKana count: Int) -> String {
            guard count > 0, count <= romajiEnds.count else { return "" }
            return String(romaji.prefix(romajiEnds[count - 1]))
        }
    }

    private struct Step {
        let offset: Int
        let foundWord: String
        let depth: Int
    }

    private enum MatchKind {
        case exact
        case prediction
        case compound(length: Int)
    }

    private struct Enumeration {
        let kana: [Character]
        let maxResults: Int
        let maxDepth: Int
        var seen: Set<String>
        var results: [ConnectionComposition] = []
    }

    private var dict: [DictEntry] = []
    private var startIndex = KanaIndex()
    private var connectionIndex: [Int: KanaIndex] = [:]
    private let romaKana = RomaKana()

    convenience init(dictFile: String) {
        self.init(dictFiles: [dictFile])
    }

    /// Later files extend earlier ones; entries keep file order, which is the
    /// order results are emitted in.
    init(dictFiles: [String]) {
        for file in dictFiles { readDict(file) }
        buildIndex()
        Log.dict.info("ConnectionDict loaded: \(dict.count) entries from \(dictFiles.count) file(s)")
    }

    var entryCount: Int { dict.count }

    private func readDict(_ path: String) {
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            Log.dict.error("Failed to read connection dict \(path): \(error.localizedDescription)")
            return
        }
        var seen: Set<String> = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("#") || s.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = s.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let pat = String(parts[0])
            let word = String(parts[1])
            let inConn = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            let outConn = parts.count > 3 ? Int(parts[3]) ?? 0 : 0
            let kana = romaKana.roma2kanaKey(pat)
            guard !kana.isEmpty, seen.insert("\(kana)\u{1}\(word)\u{1}\(inConn)\u{1}\(outConn)").inserted else { continue }
            dict.append(DictEntry(kana: kana, pat: pat, word: word, inConnection: inConn, outConnection: outConn))
        }
    }

    private func buildIndex() {
        for (index, entry) in dict.enumerated() {
            if entry.canStart { startIndex.insert(index, entry: entry) }
            connectionIndex[entry.inConnection, default: KanaIndex()].insert(index, entry: entry)
        }
        let order: (Int, Int) -> Bool = { [dict] lhs, rhs in
            let left = dict[lhs].kana.unicodeScalars, right = dict[rhs].kana.unicodeScalars
            return left.elementsEqual(right) ? lhs < rhs : left.lexicographicallyPrecedes(right)
        }
        startIndex.sorted.sort(by: order)
        for key in connectionIndex.keys { connectionIndex[key]?.sorted.sort(by: order) }
    }

    /// Entries of `index` whose kana starts with `prefix` and is longer than it.
    private func longerEntries(in index: KanaIndex, withPrefix prefix: [Character]) -> [Int] {
        let scalars = String(prefix).unicodeScalars
        var low = 0, high = index.sorted.count
        while low < high {
            let mid = (low + high) / 2
            if dict[index.sorted[mid]].kana.unicodeScalars.lexicographicallyPrecedes(scalars) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var result: [Int] = []
        while low < index.sorted.count, dict[index.sorted[low]].kana.unicodeScalars.starts(with: scalars) {
            if dict[index.sorted[low]].kanaCharacters.count > prefix.count { result.append(index.sorted[low]) }
            low += 1
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
        let query = Query(romaji: pat, kana: Array(conversion.kana), tail: conversion.tail,
                          romajiEnds: conversion.romajiEnds, predictions: searchMode == 0)
        var budget = maxResults
        generate(startIndex, query, Step(offset: 0, foundWord: "", depth: 0), budget: &budget, callback: callback)
    }

    private func matches(in index: KanaIndex, _ query: Query, offset: Int) -> [(entry: Int, kind: MatchKind)] {
        var found: [(entry: Int, kind: MatchKind)] = []
        let remainingCount = query.kana.count - offset
        if remainingCount > 0 {
            let remaining = Array(query.kana[offset...])
            if query.tail.isEmpty, let hits = index.byKana[String(remaining)] {
                found += hits.map { ($0, .exact) }
            }
            // An entry that consumes the whole remaining kana continues the
            // composition only while incomplete letters are still pending.
            let longestCompound = query.tail.isEmpty ? remainingCount - 1 : remainingCount
            for length in stride(from: 1, through: longestCompound, by: 1) {
                if let hits = index.byKana[String(remaining[..<length])] {
                    found += hits.map { ($0, .compound(length: length)) }
                }
            }
            if query.predictions {
                found += longerEntries(in: index, withPrefix: remaining)
                    .filter { romaKana.chunkMatches(tail: query.tail, in: dict[$0].kanaCharacters, at: remainingCount) }
                    .map { ($0, .prediction) }
            }
        } else if query.predictions, !query.tail.isEmpty {
            for first in romaKana.firstKanaCharacters(compatibleWith: query.tail) {
                found += (index.byFirstCharacter[first] ?? [])
                    .filter { romaKana.chunkMatches(tail: query.tail, in: dict[$0].kanaCharacters, at: 0) }
                    .map { ($0, .prediction) }
            }
        }
        return found.sorted { $0.entry < $1.entry }
    }

    private func generate(_ index: KanaIndex, _ query: Query, _ step: Step, budget: inout Int,
                          callback: (_ result: ConnectionSearchResult) -> Void) {
        for match in matches(in: index, query, offset: step.offset) {
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

    // MARK: - Bounded enumeration of complete compositions

    /// Enumerate complete compositions of `pat` with bounded work (issue #59,
    /// ADR-022). Unlike `searchDetailed`, this emits only exact full-reading
    /// conversions, deduplicates surfaces, and stops at `maxResults` /
    /// `maxDepth` so long or ambiguous readings cannot explode the recursion.
    /// `excluding` surfaces are skipped during enumeration without consuming
    /// result slots (BUG-028).
    func constrainedCompositions(pat: String,
                                 maxResults: Int = 12,
                                 maxDepth: Int = 8,
                                 excluding: Set<String> = []) -> [ConnectionComposition] {
        guard maxResults > 0, maxDepth > 0 else { return [] }
        let kana = Array(romaKana.roma2kanaKey(pat))
        guard !kana.isEmpty else { return [] }
        var enumeration = Enumeration(kana: kana, maxResults: maxResults, maxDepth: maxDepth, seen: excluding)
        enumerate(startIndex, Step(offset: 0, foundWord: "", depth: 0), &enumeration)
        return enumeration.results
    }

    private func enumerate(_ index: KanaIndex, _ step: Step, _ state: inout Enumeration) {
        guard state.results.count < state.maxResults, step.depth < state.maxDepth,
              step.offset < state.kana.count else { return }
        let remainingCount = state.kana.count - step.offset
        var found: [(entry: Int, length: Int)] = []
        for length in 1...remainingCount {
            if let hits = index.byKana[String(state.kana[step.offset..<(step.offset + length)])] {
                found += hits.map { ($0, length) }
            }
        }
        for match in found.sorted(by: { $0.entry < $1.entry }) {
            guard state.results.count < state.maxResults else { return }
            let entry = dict[match.entry]
            let nextWord = entry.contributesSurface ? step.foundWord + entry.word : step.foundWord
            if match.length == remainingCount {
                if entry.canTerminate, !nextWord.isEmpty, state.seen.insert(nextWord).inserted {
                    state.results.append(ConnectionComposition(word: nextWord, depth: step.depth + 1))
                }
            } else if let next = connectionIndex[entry.outConnection] {
                enumerate(next, Step(offset: step.offset + match.length, foundWord: nextWord, depth: step.depth + 1), &state)
            }
        }
    }
}
