import Foundation

/// Conversion of a query that is still being typed (ADR-033).
struct KanaPrefixConversion: Equatable {
    /// Kana for the completed part of the input. Characters that are not
    /// romaji (digits, symbols) pass through unchanged so keys like "3" survive.
    let kana: String
    /// Trailing letters that do not complete a kana yet ("k", "ky", "n").
    let tail: String
    /// For each Character of `kana`, how many characters of the typed string
    /// had been consumed when it was produced (kana position -> romaji offset).
    let romajiEnds: [Int]
}

/// Kana-keyed readings for the connection dictionary (ADR-033): dictionary rows
/// and typed queries are compared as kana, so every romaji spelling of a reading
/// (shuusei / syuusei, kan / kann) reaches the same entry.
extension RomaKana {
    private static let consonants: Set<Character> = Set("bcdfghjklmnpqrstvwxz")
    private static let doubleConsonants: Set<Character> = Set("bcdfghjklmpqrstvwxyz")
    private static let smallKana: Set<Character> = Set("ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ")
    private static let sokuon: Set<Character> = ["っ", "ッ"]

    /// Key for a complete reading: like `roma2hiragana`, but keeps what it
    /// cannot convert and turns a final "n" into ん. Readings already written
    /// in kana are normalized to hiragana.
    func roma2kanaKey(_ reading: String) -> String {
        if reading.contains(where: { !$0.isASCII }) { return Self.hiraganized(reading) }
        return convertKey(reading, complete: true).kana
    }

    /// Conversion of a query being typed: the incomplete final letters stay in `tail`.
    func roma2kanaPrefix(_ roma: String) -> KanaPrefixConversion {
        convertKey(roma, complete: false)
    }

    private func convertKey(_ roma: String, complete: Bool) -> KanaPrefixConversion {
        let chars = Array(roma)
        var kana = ""
        var ends: [Int] = []
        var index = 0
        func emit(_ text: String, consumedUpTo: Int) {
            for character in text {
                kana.append(character)
                ends.append(consumedUpTo)
            }
        }
        while index < chars.count {
            if let match = longestRomaKey(chars, at: index, map: romaToHiragana) {
                index += match.key.count
                emit(match.kana, consumedUpTo: index)
                continue
            }
            let current = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if current == "n" || current == "N", let next, Self.consonants.contains(next) {
                index += 1
                emit("ん", consumedUpTo: index)
            } else if Self.doubleConsonants.contains(current), next == current {
                index += 1
                emit("っ", consumedUpTo: index)
            } else if current.isLetter, chars.count - index <= 3, chars[index...].allSatisfy(\.isLetter) {
                // Incomplete syllable at the end of the input.
                let rest = String(chars[index...])
                if !complete { return KanaPrefixConversion(kana: kana, tail: rest, romajiEnds: ends) }
                index = chars.count
                emit(rest == "n" || rest == "N" ? "ん" : rest, consumedUpTo: index)
            } else {
                // Not romaji (digit, symbol, stray letter): keep it literally.
                index += 1
                emit(String(current), consumedUpTo: index)
            }
        }
        return KanaPrefixConversion(kana: kana, tail: "", romajiEnds: ends)
    }

    static func hiraganized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0x60) ?? scalar : scalar
        }))
    }

    // MARK: - Kana chunks (the unit a trailing romaji fragment has to fit)

    /// The kana unit starting at `position`: a sokuon binds to the following
    /// kana and a small kana to the preceding one (っか, きゃ, っきゃ).
    static func kanaChunk(in kana: [Character], at position: Int) -> String? {
        guard position < kana.count else { return nil }
        var end = position + 1
        if sokuon.contains(kana[position]), end < kana.count { end += 1 }
        if end < kana.count, smallKana.contains(kana[end]) { end += 1 }
        return String(kana[position..<end])
    }

    /// Romaji spellings of one kana chunk (memoized; there are a few hundred chunks).
    func romajiVariants(ofChunk chunk: String) -> [String] {
        Self.chunkCache.lock.lock()
        defer { Self.chunkCache.lock.unlock() }
        if let cached = Self.chunkCache.variants[chunk] { return cached }
        var variants = hiragana2roma(chunk)
        if variants.isEmpty, let first = chunk.unicodeScalars.first, (0x30A0...0x30FF).contains(first.value) {
            variants = katakana2roma(chunk)
        }
        if variants.isEmpty { variants = [chunk] }  // digits / symbols spell themselves
        Self.chunkCache.variants[chunk] = variants
        return variants
    }

    /// Canonical romaji of a kana string, chunk by chunk: the shortest spelling
    /// of each chunk (si, ti, tu rather than shi, chi, tsu), ties alphabetical.
    func canonicalRomaji(ofKana kana: String) -> String {
        let characters = Array(kana)
        var position = 0
        var romaji = ""
        while let chunk = Self.kanaChunk(in: characters, at: position) {
            romaji += romajiVariants(ofChunk: chunk).min { ($0.count, $0) < ($1.count, $1) } ?? chunk
            position += chunk.count
        }
        return romaji
    }

    /// True when the kana chunk at `position` can be spelled starting with `tail`.
    func chunkMatches(tail: String, in kana: [Character], at position: Int) -> Bool {
        guard !tail.isEmpty else { return true }
        guard let chunk = Self.kanaChunk(in: kana, at: position) else { return false }
        return romajiVariants(ofChunk: chunk).contains { $0.hasPrefix(tail) }
    }

    /// First kana characters an entry may start with when the whole typed
    /// input is still an incomplete syllable (`tail` only).
    func firstKanaCharacters(compatibleWith tail: String) -> Set<Character> {
        Self.chunkCache.lock.lock()
        defer { Self.chunkCache.lock.unlock() }
        if let cached = Self.chunkCache.firstCharacters[tail] { return cached }
        var result: Set<Character> = []
        for (kana, spellings) in hiraganaToRoma where spellings.contains(where: { $0.hasPrefix(tail) }) {
            if let first = kana.first { result.insert(first) }
        }
        if let first = tail.first, Self.doubleConsonants.contains(first) { result.insert("っ") }
        Self.chunkCache.firstCharacters[tail] = result
        return result
    }

    private final class ChunkCache {
        let lock = NSLock()
        var variants: [String: [String]] = [:]
        var firstCharacters: [String: Set<Character>] = [:]
    }
    private static let chunkCache = ChunkCache()
}
