import XCTest
@testable import AppBackupFoto

/// Il progresso della copia si dirada alla fonte (ADR-0010, ROADMAP #37): al massimo ~10
/// aggiornamenti al secondo, sempre l'ultimo. Con un intervallo di un'ora il test sa
/// esattamente quali aggiornamenti devono arrivare, senza cronometro.
final class FileSyncerProgressThrottleTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSyncerProgressThrottleTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeFiles(_ n: Int) throws {
        for i in 0..<n {
            try Data("contenuto \(i)".utf8).write(to: srcDir.appendingPathComponent("f\(i).jpg"))
        }
    }

    /// Aspetta che la coda del main si sia svuotata: gli `onProgress` di `FileSyncer` sono
    /// accodati con `DispatchQueue.main.async`, e possono ancora essere in coda quando
    /// `await sync(...)` ritorna (il `cont.resume` e' accodato nello stesso momento
    /// dell'ultimo `onProgress`, non dopo che e' girato).
    private func drainMainQueue() async {
        let exp = expectation(description: "coda del main svuotata")
        DispatchQueue.main.async { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 5)
    }

    func testLastProgress_equalsTheReturnedResult() async throws {
        try makeFiles(50)
        let syncer = FileSyncer(progressIntervalNanos: 3_600_000_000_000)   // un'ora: mai per tempo
        var snapshots: [FileSyncer.SyncResult] = []
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { _ in },
                                           onProgress: { snapshots.append($0) })
        await drainMainQueue()

        let last = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(last.done, result.done)
        XCTAssertEqual(last.total, result.total)
        XCTAssertEqual(last.copied, result.copied)
        XCTAssertEqual(last.skipped, result.skipped)
        XCTAssertEqual(last.errors, result.errors)
        XCTAssertEqual(last.hashErrors, result.hashErrors)
        XCTAssertEqual(last.copiedUnverified, result.copiedUnverified)
        // "Trovati N file" + il primo file + l'ultimo diradato (`isFinal`) + l'ultimo di
        // `sync` (garanzia ridondante): non 50.
        XCTAssertLessThanOrEqual(snapshots.count, 4,
                                 "il diradamento non ha funzionato: \(snapshots.count) aggiornamenti per 50 file")
    }

    func testLastProgress_afterCancel_equalsThePartialResult() async throws {
        try makeFiles(50)
        let syncer = FileSyncer(progressIntervalNanos: 3_600_000_000_000)
        var snapshots: [FileSyncer.SyncResult] = []
        var seen = 0
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { _ in },
                                           onProgress: { snapshots.append($0) },
                                           isDuplicate: { _ in
            seen += 1
            if seen == 10 { syncer.cancel() }
            return false
        })
        await drainMainQueue()

        XCTAssertLessThan(result.done, 50, "il job doveva fermarsi a meta'")
        let last = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(last.done, result.done)
        XCTAssertEqual(last.copied, result.copied)
    }

    func testDefaultInterval_isTheShared100ms() {
        let syncer = FileSyncer()
        XCTAssertEqual(syncer.progressIntervalNanos, ProgressThrottle.defaultMinimumIntervalNanos)
    }

    /// L'intervallo iniettato deve arrivare davvero al `ProgressThrottle` usato da `sync`, non
    /// solo restare memorizzato sulla proprieta' (mutante trovato in mutation testing: `sync`
    /// puo' ignorare `self.progressIntervalNanos` e creare comunque `ProgressThrottle()` col
    /// default — su un job cosi' veloce anche il default da 100ms produrrebbe pochi
    /// aggiornamenti, rendendo `testLastProgress_equalsTheReturnedResult` cieco a quel
    /// mutante). Con intervallo 0 ogni file deve emettere: se l'iniezione viene ignorata,
    /// restano solo le poche emissioni del default.
    func testInjectedZeroInterval_emitsAnUpdatePerFile() async throws {
        try makeFiles(20)
        let syncer = FileSyncer(progressIntervalNanos: 0)
        var snapshots: [FileSyncer.SyncResult] = []
        _ = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                  onStatus: { _ in },
                                  onProgress: { snapshots.append($0) })
        await drainMainQueue()

        XCTAssertGreaterThan(snapshots.count, 10,
                             "con intervallo 0 quasi ogni file deve emettere: solo \(snapshots.count) aggiornamenti per 20 file")
    }
}
