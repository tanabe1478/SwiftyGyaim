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
