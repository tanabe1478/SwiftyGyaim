import Foundation

struct DictEntry {
    let pat: String
    let rawWord: String
    let word: String
    let inConnection: Int
    let outConnection: Int
    let canStart: Bool
    let canTerminate: Bool
    let contributesSurface: Bool
    var keyLink: Int?
    var connectionLink: Int?

    init(pat: String, word: String, inConnection: Int, outConnection: Int) {
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
/// Ported from ConnectionDict.rb (Toshiyuki Masui, 2011)
class ConnectionDict {
    private var dict: [DictEntry] = []
    private var keyLink: [Int: Int] = [:]        // first char unicode scalar -> dict index
    private var connectionLink: [Int: Int] = [:]  // inConnection value -> dict index

    init(dictFile: String) {
        readDict(dictFile)
        initLink()
        Log.dict.info("ConnectionDict loaded: \(dict.count) entries")
    }

    private func readDict(_ path: String) {
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            Log.dict.error("Failed to read connection dict \(path): \(error.localizedDescription)")
            return
        }
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("#") || s.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = s.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let pat = String(parts[0])
            let word = String(parts[1])
            let inConn = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            let outConn = parts.count > 3 ? Int(parts[3]) ?? 0 : 0
            dict.append(DictEntry(pat: pat, word: word,
                                  inConnection: inConn, outConnection: outConn))
        }
    }

    private func initLink() {
        // Build keyLink: first character → linked list through dict
        var curKey: [Int: Int] = [:]
        for i in 0..<dict.count {
            if !dict[i].canStart { continue }
            guard let firstScalar = dict[i].pat.unicodeScalars.first else { continue }
            let ind = Int(firstScalar.value)
            if keyLink[ind] == nil {
                keyLink[ind] = i
                curKey[ind] = i
            } else {
                dict[curKey[ind]!].keyLink = i
                curKey[ind] = i
            }
            dict[i].keyLink = nil
        }

        // Build connectionLink: inConnection → linked list through dict
        var curConn: [Int: Int] = [:]
        for i in 0..<dict.count {
            let ind = dict[i].inConnection
            if connectionLink[ind] == nil {
                connectionLink[ind] = i
                curConn[ind] = i
            } else {
                dict[curConn[ind]!].connectionLink = i
                curConn[ind] = i
            }
            dict[i].connectionLink = nil
        }
    }

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
    func searchDetailed(pat: String, searchMode: Int,
                        callback: (_ result: ConnectionSearchResult) -> Void) {
        generateCand(connection: nil, pat: pat, foundWord: "", foundPat: "", depth: 0,
                     searchMode: searchMode, callback: callback)
    }

    /// Enumerate complete compositions of `pat` with bounded work (issue #59,
    /// ADR-022). Unlike `searchDetailed`, this emits only exact full-reading
    /// conversions, deduplicates surfaces, and stops at `maxResults` /
    /// `maxDepth` so long or ambiguous readings cannot explode the recursion.
    /// The result set is the "grammar" for dictionary-constrained generation:
    /// the model may only choose among these surfaces.
    /// `excluding` surfaces are skipped during enumeration without consuming
    /// result slots (BUG-028): capping first and filtering afterwards returned
    /// an empty set, because the bounded enumeration walks the same dictionary
    /// in the same order as normal search and its first N compositions are
    /// exactly the candidates the caller already has.
    func constrainedCompositions(pat: String,
                                 maxResults: Int = 12,
                                 maxDepth: Int = 8,
                                 excluding: Set<String> = []) -> [ConnectionComposition] {
        guard maxResults > 0, maxDepth > 0 else { return [] }
        var seen = excluding
        var results: [ConnectionComposition] = []
        enumerateCompositions(connection: nil, pat: pat, foundWord: "", depth: 0,
                              maxResults: maxResults, maxDepth: maxDepth,
                              seen: &seen, results: &results)
        return results
    }

    private func enumerateCompositions(connection: Int?, pat: String,
                                       foundWord: String, depth: Int,
                                       maxResults: Int, maxDepth: Int,
                                       seen: inout Set<String>,
                                       results: inout [ConnectionComposition]) {
        guard results.count < maxResults, depth < maxDepth,
              let firstScalar = pat.unicodeScalars.first else { return }
        var d: Int?
        if let conn = connection {
            d = connectionLink[conn]
        } else {
            d = keyLink[Int(firstScalar.value)]
        }

        while let idx = d {
            guard results.count < maxResults else { return }
            let entry = dict[idx]
            let nextWord = entry.contributesSurface ? foundWord + entry.word : foundWord
            if pat == entry.pat {
                if entry.canTerminate, !nextWord.isEmpty, seen.insert(nextWord).inserted {
                    results.append(ConnectionComposition(word: nextWord, depth: depth + 1))
                }
            } else if pat.hasPrefix(entry.pat), !entry.pat.isEmpty {
                enumerateCompositions(connection: entry.outConnection,
                                      pat: String(pat.dropFirst(entry.pat.count)),
                                      foundWord: nextWord,
                                      depth: depth + 1,
                                      maxResults: maxResults, maxDepth: maxDepth,
                                      seen: &seen, results: &results)
            }

            if connection != nil {
                d = dict[idx].connectionLink
            } else {
                d = dict[idx].keyLink
            }
        }
    }

    private func generateCand(connection: Int?, pat: String,
                               foundWord: String, foundPat: String, depth: Int,
                               searchMode: Int,
                               callback: (_ result: ConnectionSearchResult) -> Void) {
        guard let firstScalar = pat.unicodeScalars.first else { return }
        var d: Int?
        if let conn = connection {
            d = connectionLink[conn]
        } else {
            d = keyLink[Int(firstScalar.value)]
        }

        while let idx = d {
            let entry = dict[idx]
            let nextWord = entry.contributesSurface ? foundWord + entry.word : foundWord
            let nextPat = foundPat + entry.pat
            let nextDepth = depth + 1
            if pat == entry.pat {
                // Exact match
                if entry.canTerminate {
                    callback(ConnectionSearchResult(word: nextWord,
                                                    pat: nextPat,
                                                    outConnection: entry.outConnection,
                                                    depth: nextDepth))
                }
            } else if entry.pat.hasPrefix(pat) {
                // Dict entry starts with pattern (prefix match)
                if searchMode == 0, entry.canTerminate {
                    callback(ConnectionSearchResult(word: nextWord,
                                                    pat: nextPat,
                                                    outConnection: entry.outConnection,
                                                    depth: nextDepth))
                }
            } else if pat.hasPrefix(entry.pat) {
                // Pattern starts with dict entry (potential compound via connection)
                let restPat = String(pat.dropFirst(entry.pat.count))
                generateCand(connection: entry.outConnection, pat: restPat,
                             foundWord: nextWord,
                             foundPat: nextPat,
                             depth: nextDepth,
                             searchMode: searchMode, callback: callback)
            }

            if connection != nil {
                d = dict[idx].connectionLink
            } else {
                d = dict[idx].keyLink
            }
        }
    }
}
