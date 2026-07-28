import XCTest
@testable import AppBackupFoto

final class ReviewEngineIntegritySampleTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("ReviewEngineTests-\(UUID().uuidString)", isDirectory: true)
        srcDir = root.appendingPathComponent("src", isDirectory: true)
        dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil; srcDir = nil; dstDir = nil
        try super.tearDownWithError()
    }

    func testIdenticalFiles_areMatched() throws {
        let data = Data("hello world".utf8)
        try data.write(to: srcDir.appendingPathComponent("a.jpg"))
        try data.write(to: dstDir.appendingPathComponent("a.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 1)
        XCTAssertTrue(result.mismatches.isEmpty)
        XCTAssertNil(result.error)
    }

    func testAlteredDestinationFile_isReportedAsMismatch() throws {
        try Data("original".utf8).write(to: srcDir.appendingPathComponent("b.jpg"))
        try Data("corrupted".utf8).write(to: dstDir.appendingPathComponent("b.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 0)
        XCTAssertEqual(result.mismatches, ["b.jpg"])
    }

    func testDestinationFileMissingFromSource_isSkippedNotMismatch() throws {
        try Data("only-on-dest".utf8).write(to: dstDir.appendingPathComponent("c.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.skippedNoSource, 1)
        XCTAssertTrue(result.mismatches.isEmpty)
    }

    func testEmptyDestination_returnsZeroedResultWithoutError() throws {
        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.matched, 0)
        XCTAssertNil(result.error)
    }

    func testNestedSubdirectory_relativePathIsPreserved() throws {
        try fm.createDirectory(at: srcDir.appendingPathComponent("2024"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir.appendingPathComponent("2024"), withIntermediateDirectories: true)
        let data = Data("nested".utf8)
        try data.write(to: srcDir.appendingPathComponent("2024/d.jpg"))
        try data.write(to: dstDir.appendingPathComponent("2024/d.jpg"))

        let result = ReviewEngine().sampleLocalPair(srcRoot: srcDir, dstRoot: dstDir,
                                                      pairName: "Test", sampleSize: 20)

        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.matched, 1)
    }
}
