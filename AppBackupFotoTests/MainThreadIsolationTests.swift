import XCTest
@testable import AppBackupFoto

/// Regressione del 2026-09-19 (BUG-7). Con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` un tipo
/// non annotato e' `@MainActor`, e un suo metodo sincrono chiamato da un `Task.detached` salta
/// sul main thread: era la lettura dell'elenco dopo ogni MAC -> SSD, sei minuti di beachball.
///
/// Tecnica: il lavoro parte in un `Task.detached`, ESATTAMENTE come in produzione, e intanto il
/// test tiene OCCUPATO il main thread aspettando un semaforo. Se il lavoro ha bisogno del main
/// non puo' finire, e il test scade (rosso) invece di restare appeso per sempre. Non e' una
/// corsa: il main e' occupato dal test per costruzione, quindi l'esito non dipende dal timing.
///
/// Limite dichiarato: verifica l'isolamento dei TIPI, non la forma dei call site. Un futuro
/// `await MainActor.run { idx.scan(...) }` scritto in `BackupRunner` passerebbe questi test.
final class MainThreadIsolationTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainThreadIsolationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() throws -> LibraryIndexStore {
        try LibraryIndexStore(url: tmp.appendingPathComponent("index.sqlite"))
    }

    /// Il test del test. Se l'impalcatura fosse difettosa — per esempio se il semaforo non
    /// tenesse davvero occupato il main — tutti gli altri test passerebbero anche col bug.
    /// Qui il lavoro ha BISOGNO del main per costruzione, e il test si aspetta la scadenza.
    func testHarness_detectsWorkThatNeedsTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await MainActor.run { }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .timedOut,
                       "L'impalcatura non tiene occupato il main thread: gli altri test non provano niente.")
    }

    func testStoreCount_runsWithoutTheMainThread() throws {
        let store = try makeStore()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? store.count()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "LibraryIndexStore.count() ha avuto bisogno del main thread: il tipo e' tornato @MainActor?")
    }

    func testScan_runsWithoutTheMainThread() throws {
        let root = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("uno".utf8).write(to: root.appendingPathComponent("a.jpg"))
        try Data("due".utf8).write(to: root.appendingPathComponent("b.jpg"))
        let indexer = LibraryIndexer(store: try makeStore())
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? indexer.scan(root: root)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "LibraryIndexer.scan ha avuto bisogno del main thread: e' il bug dei sei minuti dopo MAC -> SSD.")
    }

    // MARK: - Pannello Doppioni (Task 5)

    func testDuplicateGroups_runsWithoutTheMainThread() throws {
        let store = try makeStore()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? store.duplicateGroups()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "LibraryIndexStore.duplicateGroups() ha avuto bisogno del main thread.")
    }

    func testDuplicateBatch_runsWithoutTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = DuplicateBatch(groups: [], rule: nil)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "DuplicateBatch(groups:) ha avuto bisogno del main thread: e' il bug del 2026-09-02, mai davvero corretto fino a oggi.")
    }

    func testTrasherRun_runsWithoutTheMainThread() throws {
        let root = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try makeStore()
        let manifest = try TrashManifestStore(url: tmp.appendingPathComponent("manifest.json"))
        // Funzioni iniettate che non toccano niente: nessun Cestino vero, mai, in questo test.
        let trasher = DuplicateTrasher(libraryRoot: root, store: store, manifest: manifest,
                                       trashFunction: { _ in nil }, hashFunction: { _ in nil })
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = trasher.run([])
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "DuplicateTrasher.run ha avuto bisogno del main thread: e' il percorso a danno piu' alto del progetto (ADR-0005).")
    }

    // MARK: - CancelFlag (Task 5/6): il flag di interruzione condiviso del progetto

    /// `cancel()` chiamato da un thread in background deve essere visibile dal main dopo
    /// l'attesa: e' esattamente l'uso reale (bottone "Interrompi" sul main, lettura dal
    /// thread che sta scansionando/trasherando).
    func testCancelFlag_cancelFromBackgroundThread_visibleFromMain() {
        let flag = CancelFlag()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            flag.cancel()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(flag.isCancelled)
    }

    /// `reset()` (Task 6): un nuovo `sync()` deve poter ripartire dopo un `cancel()`
    /// precedente, per `FileSyncer` e `S3Syncer` che adotteranno questo tipo condiviso.
    func testCancelFlag_reset_clearsThePreviousCancellation() {
        let flag = CancelFlag()
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
        flag.reset()
        XCTAssertFalse(flag.isCancelled)
    }

    // MARK: - ProgressThrottle, TrashRestorer, RestorableBatchSummary, VolumeCapacityReader (2026-09-20)

    func testProgressThrottle_runsWithoutTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            var throttle = ProgressThrottle()
            _ = throttle.shouldEmit(nowNanos: 0, isFinal: false)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    }

    func testRestorableSummary_runsWithoutTheMainThread() throws {
        let manifest = try TrashManifestStore(url: tmp.appendingPathComponent("manifest.json"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = manifest.restorableSummary()
            _ = manifest.pendingInLastBatch()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "TrashManifestStore.restorableSummary()/pendingInLastBatch() hanno avuto bisogno del main thread.")
    }

    func testTrashRestorerRun_runsWithoutTheMainThread() throws {
        let root = tmp.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try TrashManifestStore(url: tmp.appendingPathComponent("manifest.json"))
        // Funzioni iniettate che non toccano niente: nessuna mossa vera, nessun Cestino vero.
        let restorer = TrashRestorer(libraryRoot: root, manifest: manifest,
                                     moveFunction: { _, _ in }, hashFunction: { _ in nil },
                                     volumeIdentity: { _ in 1 })
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = restorer.run([])
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "TrashRestorer.run ha avuto bisogno del main thread.")
    }

    // MARK: - TrashHistory (Task 8, 2026-09-24)

    func testTrashHistory_runsWithoutTheMainThread() throws {
        let history = try TrashHistory(url: tmp.appendingPathComponent("trash-history.jsonl"))
        let item = TrashedItem(batchId: "b1", originalDisplayPath: "/SSD/Foto iPhone/a.jpg",
                               originalKey: normalizedIndexKey("Foto iPhone/a.jpg"),
                               trashedPath: "/SSD/.Trashes/501/a.jpg", size: 1, hash: "h",
                               trashedAt: Date())
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            history.append(blockId: "b1", trashed: [item])
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "TrashHistory.append ha avuto bisogno del main thread.")
    }

    func testVolumeCapacityRead_runsWithoutTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            // Una directory temporanea: il risultato e' `.notAMountPoint`, conta solo che finisca.
            _ = VolumeCapacityReader.read(path: NSTemporaryDirectory())
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success,
                       "VolumeCapacityReader.read ha avuto bisogno del main thread.")
    }

    // MARK: - Campione d'integrita' fuori dal main (2026-09-20, ROADMAP #33, aggiunta al piano)

    /// `ReviewEngine.runIntegritySample` era `@MainActor` senza produrre alcun warning
    /// (nessun `Task.detached` di mezzo, quindi nessuno dei sei casi della tabella): girava
    /// sul main perche' era codice MainActor corretto, non per un bug di isolamento — ma su
    /// un file grande (gli zip da 40-50 GB dell'SSD) avrebbe bloccato l'app per minuti.
    func testIntegritySampleLocalPair_runsWithoutTheMainThread() throws {
        let src = tmp.appendingPathComponent("src")
        let dst = tmp.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try Data("foto".utf8).write(to: src.appendingPathComponent("a.jpg"))
        try Data("foto".utf8).write(to: dst.appendingPathComponent("a.jpg"))
        let defaults = UserDefaults(suiteName: "MainThreadIsolationTests-integrity")!

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = integritySampleLocalPair(srcRoot: src, dstRoot: dst, pairName: "Test",
                                         sampleSize: 20, defaults: defaults)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "integritySampleLocalPair ha avuto bisogno del main thread.")
    }

    // MARK: - Inventario (ROADMAP #44)

    func testContentHasherDigestFile_runsWithoutTheMainThread() throws {
        let url = tmp.appendingPathComponent("a.jpg")
        try Data("uno".utf8).write(to: url)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = ContentHasher.digestFile(at: url)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "ContentHasher.digestFile ha avuto bisogno del main thread.")
    }

    func testInventoryScan_runsWithoutTheMainThread() throws {
        let root = tmp.appendingPathComponent("HDD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("uno".utf8).write(to: root.appendingPathComponent("a.jpg"))
        let scanner = InventoryScanner(store: try makeStore(), cancelFlag: CancelFlag())
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? scanner.scan(root: root, archive: .hdd, runId: 1)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "InventoryScanner.scan ha avuto bisogno del main thread.")
    }

    func testCubbitRead_runsWithoutTheMainThread() throws {
        let reader = InventoryCubbitReader(store: try makeStore(), cancelFlag: CancelFlag())
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await reader.read(runId: 1, fetchPage: { _ in page })
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "InventoryCubbitReader.read ha avuto bisogno del main thread (manca @concurrent?).")
    }

    func testInventorySummary_runsWithoutTheMainThread() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = InventorySummary(InventorySnapshot(), sampleLimit: 10)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "InventorySummary/InventoryClassifier hanno avuto bisogno del main thread.")
    }

    func testInventoryRefresh_runsWithoutTheMainThread() throws {
        let ssd = tmp.appendingPathComponent("SSD"), hdd = tmp.appendingPathComponent("HDD")
        for d in [ssd, hdd] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let store = try makeStore()
        let page = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await InventoryRefresh.run(store: store, ssdRoot: ssd, hddRoot: hdd, runId: 1, cancelFlag: CancelFlag(),
                                           fetchPage: { _ in page }, onProgress: { _ in })
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success,
                       "InventoryRefresh.run ha avuto bisogno del main thread (manca @concurrent?).")
    }
}
