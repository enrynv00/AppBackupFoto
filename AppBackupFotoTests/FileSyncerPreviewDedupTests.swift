//
//  FileSyncerPreviewDedupTests.swift
//  AppBackupFotoTests
//
//  Task 1 del piano 2026-09-01 (anteprima vera nel wizard di import): il gancio
//  `duplicateFilter` su `FileSyncer.previewSync`. FileSyncer non impara cos'e' un
//  doppione: riceve un lotto di candidati e riceve indietro gli indici da sottrarre.
//  La decisione (hash, indice, IndexableKind) vive fuori, in BackupRunner (Task 2) —
//  qui si verifica solo l'aritmetica e la propagazione.
//

import XCTest
@testable import AppBackupFoto

final class FileSyncerPreviewDedupTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSyncerPreviewDedupTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Senza duplicateFilter: nessun cambiamento per i tre job esistenti

    func testWithoutDuplicateFilter_countsIdenticalToToday_andZeroDuplicates() async throws {
        try writeFile(srcDir.appendingPathComponent("new.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("2024/nested.jpg"), byteCount: 500)
        try writeFile(srcDir.appendingPathComponent("existing.jpg"), byteCount: 2000)
        try writeFile(dstDir.appendingPathComponent("existing.jpg"), byteCount: 2000)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)

        // Stesso comportamento di prima della modifica (FileSyncerPreviewBytesTests):
        // il parametro nuovo e' additivo, questo test protegge i tre job che non
        // optano in (Mac->SSD, SSD->HDD, RestoreEngine).
        XCTAssertEqual(result.toAdd, 2)
        XCTAssertEqual(result.toSkip, 1)
        XCTAssertEqual(result.toAddBytes, 1500)
        XCTAssertEqual(result.toSkipDuplicates, 0)
    }

    func testEmptyDuplicateSet_identicalToNilCase() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("b.jpg"), byteCount: 500)

        let syncer = FileSyncer()
        let withNil = await syncer.previewSync(from: srcDir, to: dstDir, deep: false)
        let withEmpty = await syncer.previewSync(from: srcDir, to: dstDir, deep: false,
                                                  duplicateFilter: { _ in [] })

        XCTAssertEqual(withEmpty.toAdd, withNil.toAdd)
        XCTAssertEqual(withEmpty.toSkip, withNil.toSkip)
        XCTAssertEqual(withEmpty.toAddBytes, withNil.toAddBytes)
        XCTAssertEqual(withEmpty.toSkipDuplicates, 0)
    }

    // MARK: - Un indice restituito sottrae esattamente quel candidato

    func testOneDuplicateIndex_subtractsExactlyThatCandidate() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 1000)
        try writeFile(srcDir.appendingPathComponent("b.jpg"), byteCount: 700)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false,
                                               duplicateFilter: { candidates in
            guard let i = candidates.firstIndex(where: { $0.url.lastPathComponent == "b.jpg" }) else {
                return []
            }
            return [i]
        })

        XCTAssertEqual(result.toAdd, 1)
        XCTAssertEqual(result.toSkipDuplicates, 1)
        XCTAssertEqual(result.toAddBytes, 1000) // solo a.jpg, b.jpg (700) sottratto
    }

    // MARK: - Invariante dei conteggi

    func testInvariant_toAddPlusToSkipPlusToSkipDuplicates_equalsFilesExamined() async throws {
        try writeFile(srcDir.appendingPathComponent("keep.jpg"), byteCount: 111)
        try writeFile(srcDir.appendingPathComponent("dup.jpg"), byteCount: 222)
        try writeFile(srcDir.appendingPathComponent("already-there.jpg"), byteCount: 333)
        try writeFile(dstDir.appendingPathComponent("already-there.jpg"), byteCount: 333)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false,
                                               duplicateFilter: { candidates in
            guard let i = candidates.firstIndex(where: { $0.url.lastPathComponent == "dup.jpg" }) else {
                return []
            }
            return [i]
        })

        XCTAssertEqual(result.toAdd, 1)
        XCTAssertEqual(result.toSkip, 1)
        XCTAssertEqual(result.toSkipDuplicates, 1)
        XCTAssertEqual(result.toAdd + result.toSkip + result.toSkipDuplicates, 3)
    }

    // MARK: - I candidati sono solo quelli che sarebbero contati in toAdd

    func testCandidates_excludeFilesAlreadyAtDestination() async throws {
        try writeFile(srcDir.appendingPathComponent("new.jpg"), byteCount: 100)
        try writeFile(srcDir.appendingPathComponent("existing.jpg"), byteCount: 200)
        try writeFile(dstDir.appendingPathComponent("existing.jpg"), byteCount: 200)

        var captured: [FileSyncer.PreviewCandidate] = []
        let syncer = FileSyncer()
        _ = await syncer.previewSync(from: srcDir, to: dstDir, deep: false, duplicateFilter: { candidates in
            captured = candidates
            return []
        })

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.url.lastPathComponent, "new.jpg")
    }

    // MARK: - Esclusioni: LibraryExclusions e file nascosti

    func testCandidates_excludeLibraryExclusionsAndHiddenFiles() async throws {
        try writeFile(srcDir.appendingPathComponent("visible.jpg"), byteCount: 100)
        try writeFile(srcDir.appendingPathComponent("lost+found/junk.jpg"), byteCount: 50)
        try writeFile(srcDir.appendingPathComponent(".hidden.jpg"), byteCount: 60)

        var captured: [FileSyncer.PreviewCandidate] = []
        let syncer = FileSyncer()
        _ = await syncer.previewSync(from: srcDir, to: dstDir, deep: false, duplicateFilter: { candidates in
            captured = candidates
            return []
        })

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.url.lastPathComponent, "visible.jpg")
    }

    // MARK: - Sottocartelle, nell'ordine di enumerazione

    func testCandidates_includeSubfolderFiles_inEnumerationOrder() async throws {
        try writeFile(srcDir.appendingPathComponent("root.jpg"), byteCount: 100)
        try writeFile(srcDir.appendingPathComponent("sub/nested.jpg"), byteCount: 200)

        // Ordine atteso ricostruito con la STESSA `contentsOfDirectory` che
        // previewDir usa davvero — mai un ordine alfabetico assunto a tavolino.
        func expectedOrder(_ dir: URL) throws -> [URL] {
            var result: [URL] = []
            let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])
            for item in items {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: item.path, isDirectory: &isDir)
                if isDir.boolValue {
                    result += try expectedOrder(item)
                } else {
                    result.append(item)
                }
            }
            return result
        }
        let expected = try expectedOrder(srcDir)

        var captured: [FileSyncer.PreviewCandidate] = []
        let syncer = FileSyncer()
        _ = await syncer.previewSync(from: srcDir, to: dstDir, deep: false, duplicateFilter: { candidates in
            captured = candidates
            return []
        })

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured.map(\.url.path), expected.map(\.path))
    }

    // MARK: - PreviewCandidate.size

    func testPreviewCandidateSize_matchesRealFileSize() async throws {
        try writeFile(srcDir.appendingPathComponent("sized.jpg"), byteCount: 4321)

        var captured: [FileSyncer.PreviewCandidate] = []
        let syncer = FileSyncer()
        _ = await syncer.previewSync(from: srcDir, to: dstDir, deep: false, duplicateFilter: { candidates in
            captured = candidates
            return []
        })

        XCTAssertEqual(captured.first?.size, 4321)
    }

    // MARK: - Indici fuori intervallo e ripetuti

    func testOutOfRangeIndices_areIgnoredWithoutCrash() async throws {
        try writeFile(srcDir.appendingPathComponent("only.jpg"), byteCount: 100)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false,
                                               duplicateFilter: { _ in [5, 100] })

        XCTAssertEqual(result.toAdd, 1)
        XCTAssertEqual(result.toSkipDuplicates, 0)
        XCTAssertEqual(result.toAddBytes, 100)
    }

    func testRepeatedIndices_doNotSubtractTwice() async throws {
        try writeFile(srcDir.appendingPathComponent("a.jpg"), byteCount: 100)
        try writeFile(srcDir.appendingPathComponent("b.jpg"), byteCount: 200)
        try writeFile(srcDir.appendingPathComponent("c.jpg"), byteCount: 300)

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false,
                                               duplicateFilter: { candidates in
            guard let i = candidates.firstIndex(where: { $0.url.lastPathComponent == "b.jpg" }) else {
                return []
            }
            // E' un Set: ripetere lo stesso indice non deve sottrarre due volte.
            // Il test fissa il contratto anche se il literal collassa da solo.
            return Set([i, i, i])
        })

        XCTAssertEqual(result.toAdd, 2)
        XCTAssertEqual(result.toSkipDuplicates, 1)
        XCTAssertEqual(result.toAddBytes, 400) // a.jpg + c.jpg, non b.jpg sottratto due volte
    }

    // MARK: - estimatedSec conta anche i doppioni

    func testEstimatedSec_countsDuplicatesTogetherWithFilesToCopy() async throws {
        // 50 file, tutti dichiarati doppioni dalla closure: toAdd == 0, ma
        // toSkipDuplicates == 50. Con la vecchia formula (toAdd / 50) sarebbe 0 —
        // un reimport interamente duplicato da minuti mostrerebbe "00:00:00".
        for i in 0..<50 {
            try writeFile(srcDir.appendingPathComponent("dup\(i).jpg"), byteCount: 10)
        }

        let syncer = FileSyncer()
        let result = await syncer.previewSync(from: srcDir, to: dstDir, deep: false,
                                               duplicateFilter: { candidates in
            Set(candidates.indices)
        })

        XCTAssertEqual(result.toAdd, 0)
        XCTAssertEqual(result.toSkipDuplicates, 50)
        XCTAssertEqual(result.estimatedSec, 1) // max(1, (0 + 50) / 50)
    }
}
