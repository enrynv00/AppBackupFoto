//
//  FileSyncerZeroOverwriteTests.swift
//  AppBackupFotoTests
//
//  Locks down the project's absolute invariant:
//  "Zero delete, Zero overwrite, Read-only sulla sorgente".
//
//  Every test runs against REAL throwaway temp directories (no mocking):
//  a UUID subfolder of FileManager.default.temporaryDirectory, created in
//  setUp and removed in tearDown. We assert on real file bytes on disk.
//

import XCTest
import CryptoKit
@testable import AppBackupFoto

final class FileSyncerZeroOverwriteTests: XCTestCase {

    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("AppBackupFotoTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Helpers

    @discardableResult
    private func writeFile(_ url: URL, _ contents: String, modDate: Date? = nil) throws -> URL {
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(contents.utf8).write(to: url)
        if let modDate {
            try fm.setAttributes([.modificationDate: modDate], ofItemAtPath: url.path)
        }
        return url
    }

    private func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Runs a sync and returns the result, swallowing the status/progress callbacks.
    private func runSync(deep: Bool) async throws -> FileSyncer.SyncResult {
        let syncer = FileSyncer()
        return try await syncer.sync(from: srcDir, to: dstDir, deep: deep,
                                     onStatus: { _ in }, onProgress: { _ in })
    }

    // MARK: - Zero-overwrite: destination differs (different content & size)

    func testExistingDestDifferentContent_shallow_isNotOverwritten() async throws {
        let src = try writeFile(srcDir.appendingPathComponent("photo.jpg"), "SOURCE-NEW-CONTENT")
        let dst = try writeFile(dstDir.appendingPathComponent("photo.jpg"), "ORIGINAL-DEST")
        let dstBefore = try bytes(dst)
        _ = src

        let result = try await runSync(deep: false)

        XCTAssertEqual(try bytes(dst), dstBefore, "Destination bytes must be untouched (zero-overwrite)")
        XCTAssertEqual(String(data: try bytes(dst), encoding: .utf8), "ORIGINAL-DEST")
        XCTAssertEqual(result.skipped, 1, "The pre-existing file must be skipped")
        XCTAssertEqual(result.copied, 0, "Nothing must be copied over an existing file")
        XCTAssertEqual(result.errors, 0)
    }

    func testExistingDestDifferentContent_deep_isNotOverwritten() async throws {
        _ = try writeFile(srcDir.appendingPathComponent("photo.jpg"), "SOURCE-NEW-CONTENT-DIFFERENT-SIZE")
        let dst = try writeFile(dstDir.appendingPathComponent("photo.jpg"), "ORIGINAL-DEST")
        let dstBefore = try bytes(dst)

        let result = try await runSync(deep: true)

        XCTAssertEqual(try bytes(dst), dstBefore, "Destination bytes must be untouched in deep mode too")
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(result.errors, 0)
    }

    // MARK: - Zero-overwrite: SAME size, different modification date (shallow)

    func testExistingDestSameSizeDifferentModDate_shallow_isNotOverwritten() async throws {
        // Same byte length (4 bytes) but different content and different mtime.
        // In shallow mode this makes `needs == true` via the mod-date branch,
        // yet the zero-overwrite guard must still skip it.
        let now = Date()
        _ = try writeFile(srcDir.appendingPathComponent("photo.jpg"), "SRC1", modDate: now)
        let dst = try writeFile(dstDir.appendingPathComponent("photo.jpg"), "DST9",
                                modDate: now.addingTimeInterval(-3600))
        let dstBefore = try bytes(dst)
        XCTAssertEqual(dstBefore.count, 4)

        let result = try await runSync(deep: false)

        XCTAssertEqual(try bytes(dst), dstBefore, "Same-size/different-mtime file must NOT be overwritten")
        XCTAssertEqual(String(data: try bytes(dst), encoding: .utf8), "DST9")
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.errors, 0)
    }

    // MARK: - Happy path: destination missing -> file is copied byte-for-byte

    func testMissingDest_fileIsCopiedByteForByte() async throws {
        let payload = "REAL-PHOTO-BYTES-\(UUID().uuidString)"
        let src = try writeFile(srcDir.appendingPathComponent("photo.jpg"), payload)
        let dst = dstDir.appendingPathComponent("photo.jpg")
        XCTAssertFalse(fm.fileExists(atPath: dst.path))

        let result = try await runSync(deep: false)

        XCTAssertTrue(fm.fileExists(atPath: dst.path), "File should have been copied")
        XCTAssertEqual(try bytes(dst), try bytes(src), "Copied bytes must match source exactly")
        // Doubles as a check on the SHA256 verify-after-copy path.
        XCTAssertEqual(sha256Hex(try bytes(dst)), sha256Hex(try bytes(src)))
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.errors, 0)
        XCTAssertEqual(result.hashErrors, 0)
    }

    // MARK: - Recursive: nested subdir with pre-existing destination file

    func testNestedSubdir_existingDest_isNotOverwritten() async throws {
        // Source: a new file in a subfolder + an existing (to-copy) sibling.
        _ = try writeFile(srcDir.appendingPathComponent("2024/vacation.jpg"), "SRC-VACATION-NEW")
        _ = try writeFile(srcDir.appendingPathComponent("2024/brandnew.jpg"), "SRC-BRANDNEW")
        // Destination already has vacation.jpg with different content; brandnew.jpg is absent.
        let dstVacation = try writeFile(dstDir.appendingPathComponent("2024/vacation.jpg"),
                                        "ORIGINAL-VACATION-DEST")
        let dstVacationBefore = try bytes(dstVacation)
        let dstBrandNew = dstDir.appendingPathComponent("2024/brandnew.jpg")

        let result = try await runSync(deep: false)

        // The pre-existing nested file must survive untouched.
        XCTAssertEqual(try bytes(dstVacation), dstVacationBefore,
                       "Nested pre-existing file must not be overwritten (recursive guard)")
        XCTAssertEqual(String(data: try bytes(dstVacation), encoding: .utf8), "ORIGINAL-VACATION-DEST")
        // The genuinely new nested file must be copied.
        XCTAssertTrue(fm.fileExists(atPath: dstBrandNew.path))
        XCTAssertEqual(String(data: try bytes(dstBrandNew), encoding: .utf8), "SRC-BRANDNEW")

        XCTAssertEqual(result.skipped, 1, "Exactly the existing nested file is skipped")
        XCTAssertEqual(result.copied, 1, "Exactly the new nested file is copied")
        XCTAssertEqual(result.errors, 0)
    }

    // MARK: - Local SHA256 (mirrors the app's verify-after-copy)

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
