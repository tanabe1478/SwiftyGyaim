// swift-tools-version: 5.9
// GyaimCore: the platform-independent conversion core of Gyaim (ADR-035).
// Dictionary search, learning, romaji/kana conversion, heuristic and model
// rerank, Google transliterate client, settings store and file logger. The
// macOS IME compiles these same files into its app module (project.yml); this
// manifest builds them as a SwiftPM package for `swift test` and for the
// Windows/Linux conversion server.
import PackageDescription

var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
#if os(macOS)
// llama.cpp ships as an xcframework (Apple only). Elsewhere `canImport(llama)`
// is false and the model-scoring paths compile out; the Windows build links a
// native llama.cpp through a separate module later.
packageDependencies.append(.package(path: "../LlamaCpp"))
coreDependencies.append(.product(name: "llama", package: "LlamaCpp"))
#endif

let package = Package(
    name: "GyaimCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GyaimCore", targets: ["GyaimCore"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "GyaimCore",
            dependencies: coreDependencies,
            path: "Sources/GyaimCore"
        ),
        .testTarget(
            name: "GyaimCoreTests",
            dependencies: ["GyaimCore"],
            path: "Tests/GyaimCoreTests",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
