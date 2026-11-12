import Foundation

/// Which candidates the dictionary knows as finished words (BUG-049).
extension ConnectionDict {
    /// `# @stem-classes 2 8 …` in a dictionary file lists the out-connection
    /// classes of conjugation stems. grammar-dict.txt carries the line for the
    /// bundled dict.txt; an imported dictionary numbers its classes differently
    /// and declares none.
    static let stemClassesDirective = "# @stem-classes "

    func readStemClasses(_ line: Substring.UTF8View.SubSequence) {
        guard line.starts(with: Self.stemClassesDirective.utf8),
              let numbers = String(bytes: line.dropFirst(Self.stemClassesDirective.utf8.count), encoding: .utf8)
        else { return }
        stemClasses.formUnion(numbers.split(separator: " ").compactMap { Int($0) })
    }

    /// True when some derivation of `reading` spells `word` and ends in a class
    /// that is not a conjugation stem: 気持ち (noun) yes, 少な (形容詞語幹) no.
    /// False without stem classes.
    func isCompleteWord(_ word: String, reading: String) -> Bool {
        guard !stemClasses.isEmpty, !reading.isEmpty else { return false }
        var complete = false
        searchDetailed(pat: reading, searchMode: 1, maxResults: WordSearch.maxConnectionCandidates) { result in
            if result.word == word, !stemClasses.contains(result.outConnection) { complete = true }
        }
        return complete
    }

    /// The candidates the unfinished-stem rule would flag from the text alone
    /// (a one-character-longer neighbour ends in い) but that are finished
    /// words. Looked up only for those, so most keystrokes cost nothing.
    func completeWords(among candidates: [SearchCandidate]) -> Set<String> {
        guard !stemClasses.isEmpty else { return [] }
        var result: Set<String> = []
        for candidate in candidates where AIReranker.isPotentialIncompleteStem(candidate.word) {
            let flagged = candidates.contains {
                AIReranker.isIncompleteStemCompletion(stem: candidate.word, completed: $0.word)
            }
            if flagged, isCompleteWord(candidate.word, reading: candidate.reading ?? "") {
                result.insert(candidate.word)
            }
        }
        return result
    }
}
