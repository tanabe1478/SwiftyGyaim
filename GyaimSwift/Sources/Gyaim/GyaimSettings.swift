import Foundation

enum GyaimSettings {
    static var settingsFilePathOverride: String?

    private static let knownKeys = [
        "loggingEnabled",
        "candidateDisplayMode",
        "studyDictEvictionMode",
        "studyHiraganaEnabled",
        "exactReadingMatchPriority",
        "googleTransliterateTrigger",
        "connectionDictSourceURL",
        "GyaimKeyBindings",
        "clipboardCandidateEnabled",
        "selectedTextCandidateEnabled",
        "aiRerankFastContextEnabled",
        "aiRerankUseModelForFastContext",
        "aiRerankFastContextLoggingEnabled",
        "aiRerankFastContextModelMinInputLength",
        "aiRerankFastContextMaxContextLength",
        "aiRerankFastContextCandidateLimit",
        "aiRerankUseGoogle",
        "aiRerankZenzReviewRounds",
        "aiRerankZenzAlternativeLimit",
        "aiRerankUseLegacyExternalReranker",
        "aiRerankUseBundledZenz",
        "aiRerankUseZenzGeneration",
        "aiRerankZenzWeight",
        "aiRerankZenzGenerationBeamWidth",
        "aiRerankZenzMaxCandidates",
        "aiRerankServerURL",
        "aiRerankHTTPTimeoutMs",
        "aiRerankCommand",
        "aiRerankTimeoutMs",
    ]

    private static var settingsFilePath: String {
        settingsFilePathOverride ?? Config.settingsFile
    }

    private static var shouldUseSettingsFile: Bool {
        if settingsFilePathOverride != nil { return true }
        return !isRunningTests
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || ProcessInfo.processInfo.processName.contains("xctest")
    }

    static func synchronizeFileAndUserDefaults() {
        guard shouldUseSettingsFile else { return }
        var dictionary = loadDictionary()
        for (key, value) in dictionary {
            setUserDefaultsValue(value, forKey: key)
        }

        var didMigrate = false
        for key in knownKeys where dictionary[key] == nil {
            guard let defaultsValue = UserDefaults.standard.object(forKey: key),
                  let jsonValue = jsonValue(from: defaultsValue) else { continue }
            dictionary[key] = jsonValue
            didMigrate = true
        }
        if didMigrate {
            saveDictionary(dictionary)
        }
    }

    static func objectExists(forKey key: String) -> Bool {
        fileValue(forKey: key) != nil || UserDefaults.standard.object(forKey: key) != nil
    }

    static func bool(forKey key: String, default defaultValue: Bool = false) -> Bool {
        if let value = fileValue(forKey: key) {
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            if let string = value as? String { return ["1", "true", "yes", "on"].contains(string.lowercased()) }
        }
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func integer(forKey key: String, default defaultValue: Int = 0) -> Int {
        if let value = fileValue(forKey: key) {
            if let int = value as? Int { return int }
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String, let int = Int(string) { return int }
        }
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.integer(forKey: key)
    }

    static func double(forKey key: String, default defaultValue: Double = 0) -> Double {
        if let value = fileValue(forKey: key) {
            if let double = value as? Double { return double }
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String, let double = Double(string) { return double }
        }
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.double(forKey: key)
    }

    static func string(forKey key: String) -> String? {
        if let value = fileValue(forKey: key) {
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return UserDefaults.standard.string(forKey: key)
    }

    static func data(forKey key: String) -> Data? {
        if let value = fileValue(forKey: key) {
            if let encoded = value as? [String: Any],
               encoded["type"] as? String == "data",
               let base64 = encoded["base64"] as? String {
                return Data(base64Encoded: base64)
            }
        }
        return UserDefaults.standard.data(forKey: key)
    }

    static func set(_ value: Bool, forKey key: String) {
        setJSONValue(value, forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }

    static func set(_ value: Int, forKey key: String) {
        setJSONValue(value, forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }

    static func set(_ value: Double, forKey key: String) {
        setJSONValue(value, forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }

    static func set(_ value: String, forKey key: String) {
        setJSONValue(value, forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }

    static func set(_ value: Data, forKey key: String) {
        setJSONValue(["type": "data", "base64": value.base64EncodedString()], forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }

    static func removeObject(forKey key: String) {
        if shouldUseSettingsFile {
            var dictionary = loadDictionary()
            dictionary.removeValue(forKey: key)
            saveDictionary(dictionary)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func removeAll() {
        if shouldUseSettingsFile {
            saveDictionary([:])
        }
    }

    private static func fileValue(forKey key: String) -> Any? {
        guard shouldUseSettingsFile else { return nil }
        return loadDictionary()[key]
    }

    private static func setJSONValue(_ value: Any, forKey key: String) {
        guard shouldUseSettingsFile else { return }
        var dictionary = loadDictionary()
        dictionary[key] = value
        saveDictionary(dictionary)
    }

    private static func loadDictionary() -> [String: Any] {
        let url = URL(fileURLWithPath: settingsFilePath)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func saveDictionary(_ dictionary: [String: Any]) {
        let url = URL(fileURLWithPath: settingsFilePath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dictionary,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            Log.config.error("Failed to save settings file: \(error.localizedDescription)")
        }
    }

    private static func jsonValue(from value: Any) -> Any? {
        if let data = value as? Data {
            return ["type": "data", "base64": data.base64EncodedString()]
        }
        guard JSONSerialization.isValidJSONObject(["value": value]) else { return nil }
        return value
    }

    private static func setUserDefaultsValue(_ value: Any, forKey key: String) {
        if let encoded = value as? [String: Any],
           encoded["type"] as? String == "data",
           let base64 = encoded["base64"] as? String,
           let data = Data(base64Encoded: base64) {
            UserDefaults.standard.set(data, forKey: key)
        } else if let string = value as? String {
            UserDefaults.standard.set(string, forKey: key)
        } else if let number = value as? NSNumber {
            UserDefaults.standard.set(number, forKey: key)
        } else if let bool = value as? Bool {
            UserDefaults.standard.set(bool, forKey: key)
        }
    }
}
