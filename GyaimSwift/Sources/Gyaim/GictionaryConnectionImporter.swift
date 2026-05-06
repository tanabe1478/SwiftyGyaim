import Foundation

/// Imports Gictionary-format data into SwiftyGyaim's connection dictionary TSV.
///
/// Supported input formats:
/// - Gictionary.json from https://github.com/masui/Gictionary
/// - Already-converted connection TSV (`romaji\tsurface\tinConnection\toutConnection`)
enum GictionaryConnectionImporter {
    enum ImportError: LocalizedError {
        case invalidURL
        case emptyData
        case unsupportedFormat
        case noValidEntries

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "URLが正しくありません"
            case .emptyData:
                return "ダウンロードしたデータが空です"
            case .unsupportedFormat:
                return "Gictionary JSONまたは接続辞書TSVとして解釈できません"
            case .noValidEntries:
                return "有効な辞書エントリが見つかりません"
            }
        }
    }

    struct ImportResult: Equatable {
        let entryCount: Int
        let outputPath: String
    }

    private struct GictionaryExport: Decodable {
        let pages: [Page]
    }

    private struct Page: Decodable {
        let title: String
        let lines: [String]
    }

    private struct SourceEntry: Hashable {
        let reading: String
        let word: String
        let wordClass: String
        let nextClass: String
    }

    static let sourceURLDefaultsKey = "connectionDictSourceURL"

    static var sourceURLString: String {
        UserDefaults.standard.string(forKey: sourceURLDefaultsKey) ?? ""
    }

    static func setSourceURLString(_ value: String) {
        UserDefaults.standard.set(value, forKey: sourceURLDefaultsKey)
    }

    static func importFromURL(_ url: URL,
                              outputPath: String = Config.importedConnectionDictFile,
                              completion: @escaping (Result<ImportResult, Error>) -> Void) {
        if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try importData(Data(contentsOf: url), outputPath: outputPath)
                    setSourceURLString(url.absoluteString)
                    completion(.success(result))
                } catch {
                    completion(.failure(error))
                }
            }
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data, !data.isEmpty else {
                completion(.failure(ImportError.emptyData))
                return
            }
            do {
                let result = try importData(data, outputPath: outputPath)
                setSourceURLString(url.absoluteString)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    @discardableResult
    static func importData(_ data: Data,
                           outputPath: String = Config.importedConnectionDictFile) throws -> ImportResult {
        guard !data.isEmpty else { throw ImportError.emptyData }

        let content: String
        if let s = String(data: data, encoding: .utf8) {
            content = s
        } else if let s = String(data: data, encoding: .shiftJIS) {
            content = s
        } else {
            throw ImportError.unsupportedFormat
        }

        let connectionTSV: String
        let entryCount: Int
        if looksLikeConnectionTSV(content) {
            let normalized = normalizeConnectionTSV(content)
            guard !normalized.isEmpty else { throw ImportError.noValidEntries }
            connectionTSV = normalized
            entryCount = normalized.split(separator: "\n").count
        } else {
            let entries = try parseGictionaryJSON(data)
            let converted = convert(entries: entries)
            guard !converted.lines.isEmpty else { throw ImportError.noValidEntries }
            connectionTSV = converted.lines.joined(separator: "\n") + "\n"
            entryCount = converted.lines.count
        }

        let url = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try connectionTSV.write(to: url, atomically: true, encoding: .utf8)
        return ImportResult(entryCount: entryCount, outputPath: outputPath)
    }

    static func removeImportedDictionary(outputPath: String = Config.importedConnectionDictFile) throws {
        if FileManager.default.fileExists(atPath: outputPath) {
            try FileManager.default.removeItem(atPath: outputPath)
        }
        UserDefaults.standard.removeObject(forKey: sourceURLDefaultsKey)
    }

    private static func parseGictionaryJSON(_ data: Data) throws -> [SourceEntry] {
        let export: GictionaryExport
        do {
            export = try JSONDecoder().decode(GictionaryExport.self, from: data)
        } catch {
            throw ImportError.unsupportedFormat
        }

        var seen: Set<SourceEntry> = []
        var entries: [SourceEntry] = []

        for page in export.pages {
            for rawLine in page.lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line == page.title { continue }
                if line.isEmpty { break }
                if line.hasPrefix("#") { continue }
                if line.contains("[[") { break }

                let withoutComment = stripTrailingComment(line)
                let parts = withoutComment.split { $0 == " " || $0 == "\t" }.map(String.init)
                guard parts.count == 2 || parts.count == 3 else { break }

                let entry = SourceEntry(reading: parts[0],
                                        word: page.title,
                                        wordClass: parts[1],
                                        nextClass: parts.count == 3 ? parts[2] : "")
                if seen.insert(entry).inserted {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    private static func convert(entries: [SourceEntry]) -> (lines: [String], classNumbers: [String: Int]) {
        let rk = RomaKana()
        var classNumbers: [String: Int] = [:]
        var nextClassNumber = 1
        var outputLines: [String] = []
        var emitted: Set<String> = []

        func number(for wordClass: String) -> Int {
            if let n = classNumbers[wordClass] { return n }
            classNumbers[wordClass] = nextClassNumber
            nextClassNumber += 1
            return classNumbers[wordClass]!
        }

        for entry in entries {
            let inConn = number(for: entry.wordClass)
            let outConn = entry.nextClass.isEmpty ? 0 : number(for: entry.nextClass)
            let readings = romanizedReadings(for: entry.reading, romaKana: rk)
            for roma in readings where !roma.isEmpty {
                let line = "\(roma)\t\(entry.word)\t\(inConn)\t\(outConn)"
                if emitted.insert(line).inserted {
                    outputLines.append(line)
                }
            }
        }
        return (outputLines, classNumbers)
    }

    private static func romanizedReadings(for reading: String, romaKana: RomaKana) -> [String] {
        guard let first = reading.unicodeScalars.first else { return [] }
        if first.value >= 0x3040 && first.value <= 0x309F {
            return romaKana.hiragana2roma(reading)
        }
        return [reading]
    }

    private static func stripTrailingComment(_ line: String) -> String {
        guard let range = line.range(of: #"\s+#"#, options: .regularExpression) else {
            return line
        }
        return String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func looksLikeConnectionTSV(_ content: String) -> Bool {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .newlines)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            return parts.count >= 4 && Int(parts[2]) != nil && (parts[3].isEmpty || Int(parts[3]) != nil)
        }
        return false
    }

    private static func normalizeConnectionTSV(_ content: String) -> String {
        var lines: [String] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .newlines)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 4, Int(parts[2]) != nil, parts[3].isEmpty || Int(parts[3]) != nil else { continue }
            let normalized = "\(parts[0])\t\(parts[1])\t\(parts[2])\t\(parts[3])"
            lines.append(normalized)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
