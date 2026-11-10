import Foundation

/// Bounded enumeration of complete compositions (issue #59, ADR-022).
extension ConnectionDict {
    private struct Enumeration {
        let scalars: [UInt32]
        let maxResults: Int
        let maxDepth: Int
        var seen: Set<String>
        var results: [ConnectionComposition] = []
    }

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
        let scalars = romaKana.roma2kanaKey(pat).unicodeScalars.map(\.value)
        guard !scalars.isEmpty else { return [] }
        var enumeration = Enumeration(scalars: scalars, maxResults: maxResults, maxDepth: maxDepth, seen: excluding)
        enumerate(startIndex, Step(offset: 0, foundWord: "", depth: 0), &enumeration)
        return enumeration.results
    }

    private func enumerate(_ index: KanaIndex, _ step: Step, _ state: inout Enumeration) {
        guard state.results.count < state.maxResults, step.depth < state.maxDepth,
              step.offset < state.scalars.count else { return }
        let remainingCount = state.scalars.count - step.offset
        var found: [(entry: Int, length: Int)] = []
        for length in 1...remainingCount {
            found += entries(in: index, matching: state.scalars[step.offset..<(step.offset + length)])
                .map { ($0, length) }
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

    /// Surfaces of single dictionary entries read as `kana` that start with
    /// `previousWord`, minus that prefix (ADR-040): 全体 + ぞう → 全体像 → 像.
    /// Compositions through connections (分析 + できます → 分析出来ます) are
    /// not counted: they would promote kanji spellings of conjugations the user
    /// writes in kana.
    func compoundCompletions(previousWord: String, kana: String, maxResults: Int = 200) -> [String] {
        guard !previousWord.isEmpty, !kana.isEmpty else { return [] }
        var completions: [String] = []
        searchDetailed(pat: kana, searchMode: 1, maxResults: maxResults) { result in
            guard result.depth == 1, result.word.hasPrefix(previousWord) else { return }
            let rest = String(result.word.dropFirst(previousWord.count))
            if !rest.isEmpty, !completions.contains(rest) { completions.append(rest) }
        }
        return completions
    }
}
