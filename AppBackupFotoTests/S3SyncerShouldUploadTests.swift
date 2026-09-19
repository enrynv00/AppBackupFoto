//
//  S3SyncerShouldUploadTests.swift
//  AppBackupFotoTests
//
//  Regressione per BUG-3: S3Syncer.sync() ricaricava (sovrascrivendo) le key già
//  presenti su S3 con dimensione locale diversa, violando zero-overwrite sulla
//  copia offsite Cubbit. shouldUpload deve rispondere "no" per qualunque key già
//  presente, indipendentemente dalla dimensione.
//

import XCTest
@testable import AppBackupFoto

final class S3SyncerShouldUploadTests: XCTestCase {

    func testNewKey_notInExisting_shouldUpload() {
        let existingKeys: Set<String> = ["Foto iPhone/2024/a.jpg"]
        XCTAssertTrue(S3Syncer.shouldUpload(key: "Foto iPhone/2024/new.jpg", existingKeys: existingKeys))
    }

    func testExistingKey_evenWithDifferentLocalSize_shouldNotUpload() {
        // Il punto centrale del fix: la dimensione locale NON deve più influenzare
        // questa decisione. Una key già presente su S3 va sempre skippata, anche se
        // il file locale è cambiato — mai sovrascrivere.
        let existingKeys: Set<String> = ["Foto iPhone/2024/a.jpg"]
        XCTAssertFalse(S3Syncer.shouldUpload(key: "Foto iPhone/2024/a.jpg", existingKeys: existingKeys))
    }

    func testEmptyExistingKeys_anyKeyShouldUpload() {
        XCTAssertTrue(S3Syncer.shouldUpload(key: "any.jpg", existingKeys: []))
    }

    // MARK: - ROADMAP #38: uno stop precedente non deve svuotare l'elenco del bucket

    /// Config con un endpoint che rende invalido l'URL: `listPage` lancia subito (codice 8)
    /// senza toccare la rete. Se la lettura del bucket viene davvero tentata, la chiamata
    /// lancia; se invece il flag di uno stop precedente la salta, restituisce un elenco
    /// vuoto in silenzio — che e' esattamente il difetto.
    private let unreachableConfig = S3Syncer.S3Config(
        accessKeyId: "x", secretAccessKey: "x", endpoint: "https://host non valido",
        region: "x", bucket: "b")

    @MainActor
    func testPreviewUpload_afterAStop_stillReadsTheBucket() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("S3PreviewAfterStop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("b.jpg"))

        let syncer = S3Syncer()
        syncer.cancel()                                  // lo stop del job precedente
        do {
            let r = try await syncer.previewUpload(from: dir, config: unreachableConfig)
            XCTFail("L'anteprima non ha letto il bucket: ha contato \(r.toUpload) file come da caricare su un elenco vuoto")
        } catch {
            // Atteso: la lettura del bucket e' stata tentata davvero.
        }
    }

    @MainActor
    func testRestoreFolders_afterAStop_stillReadTheBucket() async {
        let engine = RestoreEngine()
        engine.stop()                                    // ripristino interrotto
        do {
            let folders = try await engine.listAvailableFolders(fromS3Config: unreachableConfig)
            XCTFail("Il ripristino non ha letto il bucket: \(folders.count) cartelle da un elenco vuoto")
        } catch {
            // Atteso.
        }
    }

    // MARK: - L'anteprima conta come il backup vero (zero-overwrite)

    func testPreviewCount_existingKeyWithDifferentSize_isNotToUpload() {
        // sync() non ricarica mai una key gia' presente (BUG-3): l'anteprima non deve
        // contarla fra quelle da caricare, qualunque sia la dimensione locale.
        let c = S3Syncer.previewCount(files: [("a.jpg", 10), ("b.jpg", 20), ("c.jpg", 30)],
                                      existingKeys: ["a.jpg", "b.jpg"])
        XCTAssertEqual(c.toUpload, 1)
        XCTAssertEqual(c.toSkip, 2)
        XCTAssertEqual(c.bytes, 30)
    }
}
