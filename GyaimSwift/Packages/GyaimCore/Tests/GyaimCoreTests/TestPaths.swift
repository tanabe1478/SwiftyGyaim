import Foundation

/// Locations in the source tree for tests that read the bundled dictionaries
/// and fixtures. Resolved from `#filePath`, so they work both when this file is
/// compiled into the SwiftPM test target and into the Xcode GyaimTests target.
enum TestPaths {
    /// `GyaimSwift/` (holds `Resources/dict.txt`, `Resources/mozc-dict.txt`, `Sources/Gyaim`).
    static let gyaimSwiftDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // GyaimCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // GyaimCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // GyaimSwift

    /// Swift source directories of the IME app and the shared core (ADR-035).
    static var sourceDirs: [URL] {
        [gyaimSwiftDir.appendingPathComponent("Sources/Gyaim"),
         gyaimSwiftDir.appendingPathComponent("Packages/GyaimCore/Sources/GyaimCore")]
    }
}
