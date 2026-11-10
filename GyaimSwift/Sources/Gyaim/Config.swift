import Foundation

enum Config {
    static let gyaimDir: String = {
        let path = NSString("~/.gyaim").expandingTildeInPath
        return path
    }()

    static let cacheDir: String = {
        "\(gyaimDir)/cacheimages"
    }()

    static let imageDir: String = {
        "\(gyaimDir)/images"
    }()

    static let localDictFile: String = {
        "\(gyaimDir)/localdict.txt"
    }()

    static let studyDictFile: String = {
        "\(gyaimDir)/studydict.txt"
    }()

    static let contextDictFile: String = {
        "\(gyaimDir)/contextdict.txt"
    }()

    static let importedConnectionDictFile: String = {
        "\(gyaimDir)/connectiondict.txt"
    }()

    static let settingsFile: String = {
        "\(gyaimDir)/settings.json"
    }()

    static func activeConnectionDictFile(bundleDictPath: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: importedConnectionDictFile),
           (try? fm.attributesOfItem(atPath: importedConnectionDictFile)[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            return importedConnectionDictFile
        }
        return bundleDictPath
    }

    /// Connection dictionaries in load order (ADR-034 / 042): the Gictionary-
    /// derived file (an imported ~/.gyaim/connectiondict.txt replaces the
    /// bundled dict.txt), then our tail grammar, then the Mozc-derived
    /// vocabulary, each when the bundle has it.
    static func activeConnectionDictFiles(bundleDictPath: String, grammarDictPath: String? = nil,
                                          mozcDictPath: String?) -> [String] {
        connectionDictFiles(gictionaryPath: activeConnectionDictFile(bundleDictPath: bundleDictPath),
                            bundleDictPath: bundleDictPath, grammarDictPath: grammarDictPath, mozcDictPath: mozcDictPath)
    }

    /// The tail grammar is written against the connection class numbers of the
    /// bundled dict.txt. An imported dictionary numbers its classes by order
    /// of appearance, so the grammar is left out when one is active.
    static func connectionDictFiles(gictionaryPath: String, bundleDictPath: String, grammarDictPath: String?,
                                    mozcDictPath: String?) -> [String] {
        var files = [gictionaryPath]
        if let grammarDictPath, gictionaryPath == bundleDictPath { files.append(grammarDictPath) }
        if let mozcDictPath { files.append(mozcDictPath) }
        return files
    }

    /// The connection dictionaries of the running app bundle, or nil when the
    /// bundle has no dict.txt (tests and broken installs).
    static func bundledConnectionDictFiles(bundle: Bundle = .main) -> [String]? {
        guard let dictPath = bundle.path(forResource: "dict", ofType: "txt") else { return nil }
        return activeConnectionDictFiles(bundleDictPath: dictPath,
                                         grammarDictPath: bundle.path(forResource: "grammar-dict", ofType: "txt"),
                                         mozcDictPath: bundle.path(forResource: "mozc-dict", ofType: "txt"))
    }

    static let copyTextFile: String = {
        "\(gyaimDir)/copytext"
    }()

    static func setup() {
        let fm = FileManager.default
        for dir in [gyaimDir, cacheDir, imageDir] {
            if !fm.fileExists(atPath: dir) {
                do {
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                } catch {
                    Log.config.error("Failed to create directory \(dir): \(error.localizedDescription)")
                }
            }
        }
        for file in [localDictFile, studyDictFile, contextDictFile] {
            if !fm.fileExists(atPath: file) {
                fm.createFile(atPath: file, contents: nil)
            }
        }
        GyaimSettings.synchronizeFileAndUserDefaults()
        Log.config.info("Config setup complete")
    }
}
