import Foundation

/// Resolves and memory-maps the bundled in-process AI model.
///
/// The GGUF weight is shipped in the app bundle and mapped inside the IME
/// process, avoiding Python/HTTP process boundaries. `BundledZenzRuntime` owns
/// the llama.cpp context that uses this model for optional on-device scoring and
/// candidate generation.
final class BundledAIRerankModel {
    static let shared = BundledAIRerankModel()

    static let modelDirectory = "Models/gyaim-lm-small-public-v1-gguf"
    static let modelFilename = "ggml-model-Q5_K_M"
    static let modelExtension = "gguf"

    /// カスタムモデルのGGUF絶対パス（settings.json / UserDefaults）。
    /// 設定があり実在すれば同梱モデルより優先する。空なら同梱モデル。
    /// 反映はIMEプロセスの次回起動時（モデルは起動後1回だけmmapされるため）。
    static let customModelPathKey = "customModelPath"

    static func customModelURL() -> URL? {
        guard let path = GyaimSettings.string(forKey: customModelPathKey),
              !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            Log.config.warning("customModelPath not found, falling back to bundled: \(expanded)")
            return nil
        }
        return URL(fileURLWithPath: expanded)
    }

    /// ログ・rerank応答に載せるモデルラベル。カスタム時はファイル名由来。
    /// dogfoodログの model= フィールドでモデル別のA/B集計ができる。
    /// 同梱は公開データのみで学習した gyaim-lm-small-public-v1（再配布可）。
    /// customModelPath はドメインデータ入りのprivateモデル（v2以降）用。
    static var activeModelLabel: String {
        if let custom = customModelURL() {
            return "custom-" + custom.deletingPathExtension().lastPathComponent
        }
        return "bundled-gyaim-lm-small-public-v1"
    }

    private let lock = NSLock()
    private var mappedData: Data?
    private(set) var modelURL: URL?

    private init() {}

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mappedData != nil
    }

    var byteCount: Int? {
        lock.lock()
        defer { lock.unlock() }
        return mappedData?.count
    }

    @discardableResult
    func loadIfAvailable(bundle: Bundle = .main) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if mappedData != nil { return true }
        guard let url = Self.resolveModelURL(bundle: bundle) else {
            Log.input.warning("Bundled AI model not found in app bundle")
            return false
        }
        do {
            mappedData = try Data(contentsOf: url, options: [.mappedIfSafe])
            modelURL = url
            Log.input.info("Bundled AI model mapped: \(url.lastPathComponent) bytes=\(mappedData?.count ?? 0)")
            return true
        } catch {
            Log.input.warning("Bundled AI model mapping failed: \(error.localizedDescription)")
            return false
        }
    }

    static func resolveModelURL(bundle: Bundle = .main) -> URL? {
        if let custom = customModelURL() { return custom }
        return bundle.url(forResource: modelFilename,
                          withExtension: modelExtension,
                          subdirectory: modelDirectory)
            ?? bundle.url(forResource: modelFilename, withExtension: modelExtension)
    }
}
