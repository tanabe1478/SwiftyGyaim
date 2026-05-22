import Foundation

/// Builds additional candidates for explicit AI rerank requests.
///
/// The generator is intentionally local and deterministic: Google candidates are
/// provided by the controller after the asynchronous API returns, while this type
/// expands a seed candidate list with local compound candidates and conservative
/// suffix completions.
struct CandidateGenerator {
    private struct CompoundBeam {
        let word: String
        let reading: String
        let segments: Int
        let score: Double
    }

    var compoundLimit = 12
    var completionLimit = 6
    var suffixes = ["でした", "です", "だった", "でした。", "です。"]
    var maxSegmentLength = 12
    var beamWidth = 8
    var segmentCandidateLimit = 3

    func generate(inputPat: String,
                  context: String,
                  baseCandidates: [SearchCandidate],
                  wordSearch: WordSearch?) -> [SearchCandidate] {
        // `context` is reserved for upcoming context-aware local generation.
        _ = context

        var result = baseCandidates
        var seen = Set(baseCandidates.map(\.word))

        for candidate in generateCompoundCandidates(query: inputPat,
                                                    wordSearch: wordSearch,
                                                    limit: compoundLimit) {
            if seen.insert(candidate.word).inserted {
                result.append(candidate)
            }
        }

        let countBeforeSuffixes = result.count
        for candidate in baseCandidates where result.count < countBeforeSuffixes + completionLimit {
            guard shouldAppendSuffix(to: candidate, query: inputPat) else { continue }
            for suffix in suffixes where result.count < countBeforeSuffixes + completionLimit {
                let word = candidate.word + suffix
                if seen.insert(word).inserted {
                    result.append(SearchCandidate(word: word,
                                                  reading: candidate.reading ?? inputPat,
                                                  source: .synthetic,
                                                  kind: .completion))
                }
            }
        }

        return result
    }

    private func shouldAppendSuffix(to candidate: SearchCandidate, query: String) -> Bool {
        candidate.word != query
            && !candidate.word.isEmpty
            && candidate.word.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil
    }

    private func generateCompoundCandidates(query: String,
                                            wordSearch: WordSearch?,
                                            limit: Int) -> [SearchCandidate] {
        guard let wordSearch, query.count >= 4 else { return [] }
        let chars = Array(query)
        var beams: [[CompoundBeam]] = Array(repeating: [], count: chars.count + 1)
        beams[0] = [CompoundBeam(word: "", reading: "", segments: 0, score: 0)]

        for pos in 0..<chars.count where !beams[pos].isEmpty {
            for end in (pos + 1)...min(chars.count, pos + maxSegmentLength) {
                let reading = String(chars[pos..<end])
                let segmentCandidates = wordSearch.search(query: reading,
                                                          searchMode: 1,
                                                          limit: segmentCandidateLimit)
                guard !segmentCandidates.isEmpty else { continue }
                for beam in beams[pos] {
                    for candidate in segmentCandidates where candidate.word != reading {
                        let word = beam.word + candidate.word
                        let score = beam.score + Double(reading.count) - Double(beam.segments) * 0.15
                        beams[end].append(CompoundBeam(word: word,
                                                       reading: beam.reading + reading,
                                                       segments: beam.segments + 1,
                                                       score: score))
                    }
                }
                beams[end].sort { $0.score > $1.score }
                if beams[end].count > beamWidth {
                    beams[end] = Array(beams[end].prefix(beamWidth))
                }
            }
        }

        var seen = Set<String>()
        return beams[chars.count]
            .filter { $0.segments >= 2 && $0.word != query && seen.insert($0.word).inserted }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { SearchCandidate(word: $0.word,
                                    reading: $0.reading,
                                    source: .synthetic,
                                    kind: .compound) }
    }
}
