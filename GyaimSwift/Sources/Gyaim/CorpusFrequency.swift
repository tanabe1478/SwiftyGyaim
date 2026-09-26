import Foundation

/// General word-frequency prior for the heuristic rerank (experimental, off by
/// default). Among many connection candidates with one reading (kaeru: 帰る
/// 買える カエル 換える 返る 蛙 替える 変える ...) the heuristic order is
/// close to dictionary order, so the right word can fall outside the model's
/// scored set. `aiRerankCorpusFrequencyPath` names a `surface<TAB>count` TSV
/// built by Tools/dict/build-corpus-frequency.py; it is loaded once per path.
final class CorpusFrequency {
    static let shared = CorpusFrequency()
    static let pathKey = "aiRerankCorpusFrequencyPath"
    static let weightKey = "aiRerankCorpusFrequencyWeight"

    /// Bonus per decade of corpus count (0 = feature off, nothing is loaded).
    static var weight: Double {
        max(0, GyaimSettings.double(forKey: weightKey))
    }

    private let lock = NSLock()
    private var loadedPath: String?
    private var counts: [String: Int] = [:]

    private init() {}

    func count(of surface: String) -> Int? {
        guard let configured = GyaimSettings.string(forKey: Self.pathKey), !configured.isEmpty else { return nil }
        let path = (configured as NSString).expandingTildeInPath
        lock.lock()
        defer { lock.unlock() }
        if loadedPath != path {
            counts = Self.load(path: path)
            loadedPath = path
        }
        return counts[surface]
    }

    private static func load(path: String) -> [String: Int] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            Log.dict.warning("Corpus frequency table not readable: \(path)")
            return [:]
        }
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count == 2, let count = Int(parts[1]) { counts[String(parts[0])] = count }
        }
        Log.dict.info("Corpus frequency table loaded: \(counts.count) surfaces")
        return counts
    }
}
