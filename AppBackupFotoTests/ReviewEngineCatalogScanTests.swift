//
//  ReviewEngineCatalogScanTests.swift
//  AppBackupFotoTests
//
//  Verifica ReviewEngine.scanLocalCatalog su directory temporanee reali (nessun mock).
//

import XCTest
@testable import AppBackupFoto

final class ReviewEngineCatalogScanTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("ReviewEngineCatalogScanTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ relativePath: String, byteCount: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        return url
    }

    func testTopLevelFile_appearsWithCorrectNameAndSize() throws {
        try writeFile("a.jpg", byteCount: 1000)

        let entries = ReviewEngine().scanLocalCatalog(rootURL: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "a.jpg")
        XCTAssertEqual(entries[0].relativePath, "a.jpg")
        XCTAssertEqual(entries[0].sizeBytes, 1000)
        XCTAssertNotNil(entries[0].modified)
    }

    func testNestedSubdirectory_relativePathIncludesSubfolder() throws {
        try writeFile("2024/b.jpg", byteCount: 2000)

        let entries = ReviewEngine().scanLocalCatalog(rootURL: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "b.jpg")
        XCTAssertEqual(entries[0].relativePath, "2024/b.jpg")
    }

    func testExcludedSystemFiles_areSkipped() throws {
        try writeFile("a.jpg", byteCount: 1000)
        try writeFile(".DS_Store", byteCount: 10)
        try writeFile("._a.jpg", byteCount: 10)

        let entries = ReviewEngine().scanLocalCatalog(rootURL: root)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "a.jpg")
    }

    func testEmptyDirectory_returnsEmptyArray() {
        let entries = ReviewEngine().scanLocalCatalog(rootURL: root)
        XCTAssertTrue(entries.isEmpty)
    }
}
