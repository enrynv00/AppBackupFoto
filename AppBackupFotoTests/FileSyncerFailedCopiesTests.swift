//
//  FileSyncerFailedCopiesTests.swift
//  AppBackupFotoTests
//
//  ROADMAP #49, ADR-0020: ogni file che una copia locale non copia, e ogni copia non
//  identica, lascia una riga col percorso relativo e il motivo, e finisce in
//  `SyncResult.failedCopies`. Nessun comportamento di copia cambia: questi test provano
//  anche che zero-overwrite resta intatto.
//

import XCTest
@testable import AppBackupFoto

final class FileSyncerFailedCopiesTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private var lockedDirs: [URL] = []
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSyncerFailedCopiesTests-\(UUID().uuidString)", isDirectory: true)
        srcDir = root.appendingPathComponent("src", isDirectory: true)
        dstDir = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Una cartella 0555 non si puo' svuotare: si rimettono i permessi prima di rimuovere.
        for dir in lockedDirs { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil; srcDir = nil; dstDir = nil; lockedDirs = []
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeSource(_ relativePath: String, _ contents: String = "contenuto") throws -> URL {
        let url = srcDir.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Crea (se serve) la cartella di destinazione e la rende non scrivibile.
    private func lockDestinationFolder(_ relativePath: String) throws {
        let dir = dstDir.appendingPathComponent(relativePath, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        lockedDirs.append(dir)
    }

    /// Le `onStatus`/`onProgress` di `FileSyncer` sono accodate con `DispatchQueue.main.async`:
    /// possono essere ancora in coda quando `await sync(...)` ritorna.
    private func drainMainQueue() async {
        let exp = expectation(description: "coda del main svuotata")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 5)
    }

    // 1
    func testUnwritableDestinationFolder_isListedWithPathAndReason() async throws {
        let src = try writeSource("sub/a.jpg")
        try lockDestinationFolder("sub")

        let result = try await FileSyncer().sync(from: srcDir, to: dstDir, deep: false,
                                                 onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.errors, 1)
        XCTAssertEqual(result.failedCopies.count, 1)
        XCTAssertEqual(result.failedCopies.first?.path, "sub/a.jpg")
        XCTAssertTrue(result.failedCopies.first?.reason.contains("permesso negato") == true,
                      result.failedCopies.first?.reason ?? "nessun motivo")
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "contenuto",
                       "la sorgente non si tocca mai")
    }

    // 2
    func testUnwritableDestinationFolder_writesALogLine() async throws {
        try writeSource("sub/a.jpg")
        try lockDestinationFolder("sub")

        var lines: [String] = []
        _ = try await FileSyncer().sync(from: srcDir, to: dstDir, deep: false,
                                        onStatus: { lines.append($0) }, onProgress: { _ in })
        await drainMainQueue()

        XCTAssertTrue(lines.contains { $0.hasPrefix("Non copiato: «sub/a.jpg» — permesso negato") },
                      lines.joined(separator: "\n"))
    }

    // 3: e' anche una prova di zero-overwrite. Il controllo di esistenza perde la corsa (il
    // file compare dopo), e `copyItem` rifiuta: il contenuto preesistente resta com'e'.
    func testDestinationAppearingBeforeTheCopy_isNeverOverwritten_andIsListed() async throws {
        try writeSource("a.jpg", "nuovo contenuto")
        let target = dstDir.appendingPathComponent("a.jpg")

        let result = try await FileSyncer().sync(from: srcDir, to: dstDir, deep: false,
                                                 onStatus: { _ in }, onProgress: { _ in },
                                                 isDuplicate: { _ in
            try? Data("preesistente".utf8).write(to: target)
            return false
        })

        XCTAssertEqual(try Data(contentsOf: target), Data("preesistente".utf8),
                       "zero-overwrite: il file comparso prima della copia non si sovrascrive")
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(result.errors, 1)
        XCTAssertTrue(result.failedCopies.first?.reason.contains("non è stato sovrascritto") == true,
                      result.failedCopies.first?.reason ?? "nessun motivo")
    }

    // 4
    func testSourceVanishedBeforeTheCopy_isListed() async throws {
        let src = try writeSource("a.jpg")

        let result = try await FileSyncer().sync(from: srcDir, to: dstDir, deep: false,
                                                 onStatus: { _ in }, onProgress: { _ in },
                                                 isDuplicate: { _ in
            try? FileManager.default.removeItem(at: src)   // il file di test sparisce prima della copia
            return false
        })

        XCTAssertEqual(result.failedCopies.count, 1)
        XCTAssertEqual(result.failedCopies.first?.path, "a.jpg")
        XCTAssertTrue(result.failedCopies.first?.reason.contains("non c'è più") == true,
                      result.failedCopies.first?.reason ?? "nessun motivo")
    }

    // 5
    func testHashMismatch_isListedWithPath_andCountsAsHashError() async throws {
        try writeSource("sub/a.jpg")

        var lines: [String] = []
        let syncer = FileSyncer(hashFunction: { url in
            url.path.contains("/src/") ? "aaaa" : "bbbb"
        })
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { lines.append($0) }, onProgress: { _ in })
        await drainMainQueue()

        XCTAssertEqual(result.hashErrors, 1)
        XCTAssertEqual(result.errors, 0)
        XCTAssertEqual(result.failedCopies, [FailedFile(path: "sub/a.jpg", reason: LocalCopyText.mismatchReason)])
        XCTAssertTrue(lines.contains { $0.hasPrefix("Copia non identica: «sub/a.jpg»") },
                      lines.joined(separator: "\n"))
    }

    // 6: la cartella temporanea e' `/var/...`, il listing la da' come `/private/var/...`
    // (misurato): il percorso relativo si costruisce cartella per cartella, non togliendo la radice.
    func testRelativePath_isRightThroughTheVarLink_andWithUnicode() async throws {
        try writeSource("a b/c/x é.jpg")
        try lockDestinationFolder("a b/c")

        let result = try await FileSyncer().sync(from: srcDir, to: dstDir, deep: false,
                                                 onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.failedCopies.map(\.path), ["a b/c/x é.jpg"])
    }

    // 7
    func testCountersAndList_alwaysAgree() async throws {
        try writeSource("ok.jpg", "uno")
        try writeSource("mm.jpg", "due")
        try writeSource("sub/a.jpg", "tre")
        try lockDestinationFolder("sub")

        let syncer = FileSyncer(hashFunction: { url in
            if url.lastPathComponent == "mm.jpg" { return url.path.contains("/src/") ? "aaaa" : "bbbb" }
            return sha256(of: url)
        })
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.errors, 1)
        XCTAssertEqual(result.hashErrors, 1)
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.failedCopies.count, result.errors + result.hashErrors)
        XCTAssertEqual(result.copied + result.skipped + result.errors + result.hashErrors
                       + result.copiedUnverified, result.done)
    }

    // 8
    func testProgressUpdates_duringTheWork_neverCarryTheList() async throws {
        try writeSource("sub/a.jpg")
        try writeSource("sub/b.jpg")
        try lockDestinationFolder("sub")

        var snapshots: [FileSyncer.SyncResult] = []
        let result = try await FileSyncer(progressIntervalNanos: 0).sync(
            from: srcDir, to: dstDir, deep: false,
            onStatus: { _ in }, onProgress: { snapshots.append($0) })
        await drainMainQueue()

        // L'ultimo `onProgress` e' uno solo e coincide con il risultato finale (ADR-0020): porta
        // l'elenco. Tutti gli altri, durante il lavoro, no: altrimenti a ogni file si
        // ricopierebbe un elenco che con un disco pieno arriva a migliaia di voci.
        XCTAssertGreaterThan(snapshots.count, 1)
        for snap in snapshots.dropLast() {
            XCTAssertTrue(snap.failedCopies.isEmpty, "durante il lavoro il progresso non porta l'elenco")
        }
        XCTAssertEqual(snapshots.last?.failedCopies.count, 2)
        XCTAssertEqual(result.failedCopies.count, 2)
    }

    // 9
    func testSuccessfulSync_hasEmptyList() async throws {
        try writeSource("a.jpg")

        let result = try await FileSyncer().sync(from: srcDir, to: dstDir, deep: false,
                                                 onStatus: { _ in }, onProgress: { _ in })

        XCTAssertTrue(result.failedCopies.isEmpty)
        XCTAssertEqual(result.errors, 0)
    }

    // 10
    func testLocalFailures_neverFillTheCubbitList() async throws {
        try writeSource("sub/a.jpg")
        try lockDestinationFolder("sub")

        let result = try await FileSyncer().sync(from: srcDir, to: dstDir, deep: false,
                                                 onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.failedCopies.count, 1)
        XCTAssertTrue(result.failedFiles.isEmpty)
    }
}
