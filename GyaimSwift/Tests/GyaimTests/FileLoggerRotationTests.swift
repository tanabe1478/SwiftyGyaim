@testable import Gyaim
import XCTest

final class FileLoggerRotationTests: XCTestCase {
    func testShiftKeepsSevenGenerationsAndDropsTheOldest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logPath = dir.appendingPathComponent("gyaim.log").path
        let rotated = (1...FileLogger.maxRotatedFiles).map { "\(logPath).\($0)" }

        try "live".write(toFile: logPath, atomically: true, encoding: .utf8)
        for (index, path) in rotated.enumerated() {
            try "gen\(index + 1)".write(toFile: path, atomically: true, encoding: .utf8)
        }

        FileLogger.shiftRotatedFiles(logPath: logPath, rotatedPaths: rotated)

        XCTAssertFalse(FileManager.default.fileExists(atPath: logPath))
        XCTAssertEqual(try String(contentsOfFile: rotated[0], encoding: .utf8), "live")
        XCTAssertEqual(try String(contentsOfFile: rotated[1], encoding: .utf8), "gen1")
        XCTAssertEqual(try String(contentsOfFile: rotated[6], encoding: .utf8), "gen6")
        XCTAssertEqual(FileLogger.maxRotatedFiles, 7)
    }
}
