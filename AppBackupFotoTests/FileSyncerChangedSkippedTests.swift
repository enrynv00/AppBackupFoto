//
//  FileSyncerChangedSkippedTests.swift
//  AppBackupFotoTests
//
//  Verifica che FileSyncer.sync distingua "file identico, skippato" da "file
//  esistente ma diverso, skippato per zero-overwrite" (roadmap #13).
//

import XCTest
@testable import AppBackupFoto

final class FileSyncerChangedSkippedTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSyncerChangedSkippedTests-\(UUID().uuidString)", isDirectory: true)
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

    @discardableResult
    private func writeFile(_ url: URL, _ contents: String) throws -> URL {
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testChangedExistingFile_incrementsChangedSkippedAndSkipped() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), "new content, different size")
        try writeFile(dstDir.appendingPathComponent("a.jpg"), "old")

        let syncer = FileSyncer()
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                            onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.changedSkipped, 1)
        XCTAssertEqual(result.copied, 0)
    }

    func testIdenticalExistingFile_doesNotIncrementChangedSkipped() async throws {
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        let srcURL = try writeFile(srcDir.appendingPathComponent("a.jpg"), "same")
        let dstURL = try writeFile(dstDir.appendingPathComponent("a.jpg"), "same")
        try fm.setAttributes([.modificationDate: sameDate], ofItemAtPath: srcURL.path)
        try fm.setAttributes([.modificationDate: sameDate], ofItemAtPath: dstURL.path)

        let syncer = FileSyncer()
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                            onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.changedSkipped, 0)
    }

    func testNewFile_doesNotIncrementChangedSkipped() async throws {
        try writeFile(srcDir.appendingPathComponent("new.jpg"), "brand new")

        let syncer = FileSyncer()
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                            onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.changedSkipped, 0)
    }
}
