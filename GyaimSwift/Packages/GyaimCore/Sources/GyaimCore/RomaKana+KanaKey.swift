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

/// One to three kana scalars that a trailing romaji fragment must fit
/// (か, きゃ, っか, っきゃ). Fixed size so scanning entries allocates nothing.
struct KanaUnit: Equatable {
    var first: UInt32
    var second: UInt32 = 0
    var third: UInt32 = 0

    var count: Int { third != 0 ? 3 : (second != 0 ? 2 : 1) }

    var string: String {
        String(String.UnicodeScalarView([first, second, third].prefix(count).compactMap(Unicode.Scalar.init)))
    }
}

/// Kana-keyed readings for the connection dictionary (ADR-033): dictionary rows
/// and typed queries are compared as kana, so every romaji spelling of a reading
/// (shuusei / syuusei, kan / kann) reaches the same entry.
extension RomaKana {
    private static let consonants: Set<Character> = Set("bcdfghjklmnpqrstvwxz")
    private static let doubleConsonants: Set<Character> = Set("bcdfghjklmpqrstvwxyz")
    private static let smallKana: Set<UInt32> = Set("ぁぃぅぇぉゃゅょゎァィゥェォャュョヮ".unicodeScalars.map(\.value))
    private static let sokuon: Set<UInt32> = Set("っッ".unicodeScalars.map(\.value))

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
        let katakana: ClosedRange<UInt32> = 0x30A1...0x30F6
        guard text.unicodeScalars.contains(where: { katakana.contains($0.value) }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            katakana.contains(scalar.value) ? Unicode.Scalar(scalar.value - 0x60) ?? scalar : scalar
        }))
    }

    // MARK: - Kana units (what a trailing romaji fragment has to fit)

    /// The kana unit starting at `position`: a sokuon binds to the following
    /// kana and a small kana to the preceding one (っか, きゃ, っきゃ). Nil past
    /// the end. Walks the scalar view without allocating.
    static func kanaUnit(in kana: String.UnicodeScalarView, at position: Int) -> KanaUnit? {
        var iterator = kana.makeIterator()
        for _ in 0..<position { guard iterator.next() != nil else { return nil } }
        guard let first = iterator.next()?.value else { return nil }
        var unit = KanaUnit(first: first)
        var next = iterator.next()?.value
        if sokuon.contains(first), let second = next {
            unit.second = second
            next = iterator.next()?.value
        }
        if let following = next, smallKana.contains(following) {
            if unit.second == 0 { unit.second = following } else { unit.third = following }
        }
        return unit
    }

    /// Romaji spellings of one kana unit (memoized; there are a few hundred units).
    func romajiVariants(ofUnit unit: String) -> [String] {
        Self.unitCache.lock.lock()
        defer { Self.unitCache.lock.unlock() }
        if let cached = Self.unitCache.variants[unit] { return cached }
        var variants = hiragana2roma(unit)
        if variants.isEmpty, let first = unit.unicodeScalars.first, (0x30A0...0x30FF).contains(first.value) {
            variants = katakana2roma(unit)
        }
        if variants.isEmpty { variants = [unit] }  // digits / symbols spell themselves
        Self.unitCache.variants[unit] = variants
        return variants
    }

    /// Canonical romaji of a kana string, unit by unit: the shortest spelling
    /// of each unit (si, ti, tu rather than shi, chi, tsu), ties alphabetical.
    func canonicalRomaji(ofKana kana: String) -> String {
        var position = 0
        var romaji = ""
        while let unit = Self.kanaUnit(in: kana.unicodeScalars, at: position) {
            let text = unit.string
            romaji += romajiVariants(ofUnit: text).min { ($0.count, $0) < ($1.count, $1) } ?? text
            position += unit.count
        }
        return romaji
    }

    /// True when the kana unit can be spelled starting with `tail`.
    func unitMatches(tail: String, unit: KanaUnit) -> Bool {
        guard !tail.isEmpty else { return true }
        return romajiVariants(ofUnit: unit.string).contains { $0.hasPrefix(tail) }
    }

    /// Convenience for tests: the unit at `position` of `kana` fits `tail`.
    func chunkMatches(tail: String, inKana kana: String, at position: Int) -> Bool {
        guard let unit = Self.kanaUnit(in: kana.unicodeScalars, at: position) else { return false }
        return unitMatches(tail: tail, unit: unit)
    }

    /// First kana scalars an entry may start with when the whole typed input is
    /// still an incomplete syllable (`tail` only), in scalar order.
    func firstScalars(compatibleWith tail: String) -> [UInt32] {
        Self.unitCache.lock.lock()
        defer { Self.unitCache.lock.unlock() }
        if let cached = Self.unitCache.firstScalars[tail] { return cached }
        var result: Set<UInt32> = []
        for (kana, spellings) in hiraganaToRoma where spellings.contains(where: { $0.hasPrefix(tail) }) {
            if let first = kana.unicodeScalars.first { result.insert(first.value) }
        }
        if let first = tail.first, Self.doubleConsonants.contains(first) { result.insert("っ".unicodeScalars.first!.value) }
        let sorted = result.sorted()
        Self.unitCache.firstScalars[tail] = sorted
        return sorted
    }

    private final class UnitCache {
        let lock = NSLock()
        var variants: [String: [String]] = [:]
        var firstScalars: [String: [UInt32]] = [:]
    }
    private static let unitCache = UnitCache()
}
