//
//  FileSyncerPreviewBytesTests.swift
//  AppBackupFotoTests
//
//  Verifica che FileSyncer.previewSync sommi correttamente i byte dei file
//  che verrebbero copiati (toAddBytes), ignorando i file già presenti a
//  destinazione (zero-overwrite: skippati, non contano nei byte da aggiungere).
//

import XCTest
@testable import AppBackupFoto

final class FileSyncerPreviewBytesTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSyncerPreviewBytesTests-\(UUID().uuidString)", isDirectory: true)
        srcDir = root.appendingPathComponent("src", isDirectory: true)
        dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try? fm.removeItem(at: root)
        }
        root = nil; srcDir = nil; dstDir = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFile(_ url: URL, byteCount: Int) throws -> URL {
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        return url
    }

    func testSingleNewFile_sumsItsByteCount() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 1)
        XCTAssertEqual(result.toAddBytes, 1000)
    }

    func testMultipleNewFiles_sumsAllByteCounts() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("b.jpg"), byteCount: 2500)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 2)
        XCTAssertEqual(result.toAddBytes, 3500)
    }

    func testExistingDestFile_isSkippedAndNotCountedInBytes() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("b.jpg"), byteCount: 2500)
        try writeFile(dstDir.appendingPathComponent("a.jpg"), byteCount: 1000)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 1)
        XCTAssertEqual(result.toSkip, 1)
        XCTAssertEqual(result.toAddBytes, 2500)
    }

    func testNestedSubdirectory_bytesAreSummedAcrossSubdirs() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("2024/b.jpg"), byteCount: 2500)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 2)
        XCTAssertEqual(result.toAddBytes, 3500)
    }

    func testEmptySource_zeroBytes() async throws {
        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        XCTAssertEqual(result.toAdd, 0)
        XCTAssertEqual(result.toAddBytes, 0)
    }
}
