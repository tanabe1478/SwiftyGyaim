import Foundation

/// Resolves and keeps the bundled in-process AI model resident.
///
/// This is the first step toward azooKey-style on-device inference: the GGUF
/// weight is shipped in the app bundle and memory-mapped inside the IME process,
/// avoiding Python/HTTP process boundaries. Actual token inference will be wired
/// to this resident model in a later step.
final class BundledAIRerankModel {
    static let shared = BundledAIRerankModel()

    static let modelDirectory = "Models/zenz-v3.1-xsmall-gguf"
    static let modelFilename = "ggml-model-Q5_K_M"
    static let modelExtension = "gguf"

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
        bundle.url(forResource: modelFilename,
                   withExtension: modelExtension,
                   subdirectory: modelDirectory)
            ?? bundle.url(forResource: modelFilename, withExtension: modelExtension)
    }
}
