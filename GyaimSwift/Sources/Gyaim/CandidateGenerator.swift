import Foundation

/// Builds additional candidates for explicit AI rerank requests.
///
/// The generator is intentionally local and deterministic: Google candidates are
/// provided by the controller after the asynchronous API returns, while this type
/// expands a seed candidate list with local compound candidates and conservative
/// suffix completions.
struct CandidateGenerator {
    private struct LatticeBeam {
        let word: String
        let reading: String
        let segments: Int
        let score: Double
        let lastWord: String?
    }

    var compoundLimit = 12
    var completionLimit = 6
    var suffixes = ["でした", "です", "だった", "でした。", "です。"]
    var maxSegmentLength = 12
    var beamWidth = 8
    var segmentCandidateLimit = 5

    func generate(inputPat: String,
                  context: String,
                  baseCandidates: [SearchCandidate],
                  wordSearch: WordSearch?,
                  surfacePrefixes: [String] = []) -> [SearchCandidate] {
        // `context` is reserved for upcoming context-aware local generation.
        _ = context

        var result = baseCandidates
        var seen = Set(baseCandidates.map(\.word))

        for candidate in generateLatticeCandidates(query: inputPat,
                                                   wordSearch: wordSearch,
                                                   limit: compoundLimit,
                                                   surfacePrefixes: surfacePrefixes) {
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

    private func generateLatticeCandidates(query: String,
                                           wordSearch: WordSearch?,
                                           limit: Int,
                                           surfacePrefixes: [String] = []) -> [SearchCandidate] {
        guard let wordSearch, query.count >= 5 else { return [] }
        let chars = Array(query)
        var beams: [[LatticeBeam]] = Array(repeating: [], count: chars.count + 1)
        beams[0] = [LatticeBeam(word: "", reading: "", segments: 0, score: 0, lastWord: nil)]

        for pos in 0..<chars.count where !beams[pos].isEmpty {
            let maxEnd = min(chars.count, pos + maxSegmentLength)
            for end in (pos + 1)...maxEnd {
                let reading = String(chars[pos..<end])
                let segmentCandidates = wordSearch.search(query: reading,
                                                          searchMode: 1,
                                                          limit: segmentCandidateLimit)
                    .filter { shouldUseSegmentCandidate($0, reading: reading) }
                guard !segmentCandidates.isEmpty else { continue }

                for beam in beams[pos] {
                    for candidate in segmentCandidates {
                        let word = beam.word + candidate.word
                        let score = beam.score
                            + scoreSegment(candidate,
                                           reading: reading,
                                           previousWord: beam.lastWord,
                                           segmentIndex: beam.segments)
                        beams[end].append(LatticeBeam(word: word,
                                                      reading: beam.reading + reading,
                                                      segments: beam.segments + 1,
                                                      score: score,
                                                      lastWord: candidate.word))
                    }
                }
                prune(&beams[end])
            }
        }

        let normalizedPrefixes = surfacePrefixes.filter { !$0.isEmpty }
        var seen = Set<String>()
        return beams[chars.count]
            .filter { beam in
                beam.segments >= 2
                    && beam.word != query
                    && seen.insert(beam.word).inserted
                    && satisfiesSurfacePrefixes(beam.word, prefixes: normalizedPrefixes)
            }
            .sorted { adjustedLatticeScore($0) > adjustedLatticeScore($1) }
            .prefix(limit)
            .map { SearchCandidate(word: $0.word,
                                    reading: $0.reading,
                                    source: .synthetic,
                                    kind: .lattice) }
    }

    private func prune(_ beams: inout [LatticeBeam]) {
        beams.sort { adjustedLatticeScore($0) > adjustedLatticeScore($1) }
        if beams.count > beamWidth {
            beams = Array(beams.prefix(beamWidth))
        }
    }

    private func adjustedLatticeScore(_ beam: LatticeBeam) -> Double {
        beam.score
            - Double(max(0, beam.segments - 1)) * 0.80
            - unnaturalScriptTransitionPenalty(beam.word)
    }

    private func satisfiesSurfacePrefixes(_ word: String, prefixes: [String]) -> Bool {
        prefixes.isEmpty || prefixes.contains { word.hasPrefix($0) }
    }

    private func shouldUseSegmentCandidate(_ candidate: SearchCandidate, reading: String) -> Bool {
        candidate.word != reading
            && !candidate.word.isEmpty
            && candidate.word.allSatisfy(isAllowedCompoundCharacter)
            && !isShortNumericSegment(word: candidate.word, reading: reading)
    }

    private func scoreSegment(_ candidate: SearchCandidate,
                              reading: String,
                              previousWord: String?,
                              segmentIndex: Int) -> Double {
        var score = Double(reading.count)
        score -= Double(segmentIndex) * 0.35
        score += sourceBias(candidate.source)
        score -= shortSegmentPenalty(word: candidate.word, reading: reading)
        if let previousWord {
            score -= transitionPenalty(previous: previousWord, next: candidate.word)
            if previousWord.allSatisfy(isKanji) && candidate.word == "する" {
                score += 0.80
            }
            score += commonCompoundBonus(previous: previousWord, next: candidate.word)
        }
        return score
    }

    private func sourceBias(_ source: CandidateSource) -> Double {
        switch source {
        case .study:
            return 0.30
        case .local:
            return 0.20
        case .connection:
            return 0.05
        case .google, .external, .synthetic:
            return 0.0
        }
    }

    private func shortSegmentPenalty(word: String, reading: String) -> Double {
        var penalty = 0.0
        if word.count == 1 && word.contains(where: isKanji) {
            penalty += 1.20
        }
        if reading.count <= 2 && word.count <= 1 {
            penalty += 0.60
        }
        return penalty
    }

    private func commonCompoundBonus(previous: String, next: String) -> Double {
        switch (previous, next) {
        case ("起動", "後"),
             ("更新", "後"),
             ("変更", "後"),
             ("修正", "後"),
             ("改善", "点"):
            return 1.20
        default:
            return 0
        }
    }

    private func transitionPenalty(previous: String, next: String) -> Double {
        guard let previousLast = previous.last, let nextFirst = next.first else { return 0 }
        if isHiragana(previousLast) && isKanji(nextFirst) {
            return 2.00
        }
        if isKatakana(previousLast) && (isHiragana(nextFirst) || isKanji(nextFirst)) {
            return 1.50
        }
        return 0
    }

    private func unnaturalScriptTransitionPenalty(_ word: String) -> Double {
        let chars = Array(word)
        guard chars.count >= 2 else { return 0 }
        var penalty = 0.0
        for index in 1..<chars.count {
            if isHiragana(chars[index - 1]) && isKanji(chars[index]) {
                penalty += 1.50
            }
            if isKatakana(chars[index - 1]) && isHiragana(chars[index]) {
                penalty += 1.00
            }
        }
        return penalty
    }

    private func isShortNumericSegment(word: String, reading: String) -> Bool {
        reading.count <= 2 && word.allSatisfy(isNumericCharacter)
    }

    private func isNumericCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x0030...0x0039, // ASCII digits
                 0xFF10...0xFF19, // Fullwidth digits
                 0x2460...0x2473, // Circled digits
                 0x00B2...0x00B3, 0x00B9, // Superscript digits
                 0x2070, 0x2074...0x2079:
                return true
            default:
                return "〇零一二三四五六七八九十百千万億兆".unicodeScalars.contains(scalar)
            }
        }
    }

    private func isAllowedCompoundCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0x3005...0x3007, // 々, 〆, 〇
                 0xFF10...0xFF19, // Fullwidth digits
                 0xFF21...0xFF3A, // Fullwidth Latin uppercase
                 0xFF41...0xFF5A: // Fullwidth Latin lowercase
                return true
            default:
                return false
            }
        }
    }

    private func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x3040...0x309F ~= $0.value }
    }

    private func isKatakana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x30A0...0x30FF ~= $0.value }
    }

    private func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x4E00...0x9FFF ~= $0.value }
    }
}
