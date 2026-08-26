import XCTest
@testable import AppBackupFoto

final class Sha256Tests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("Sha256Tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    func testKnownString_matchesReferenceHash() throws {
        let file = root.appendingPathComponent("hello.txt")
        try Data("hello world".utf8).write(to: file)
        XCTAssertEqual(sha256(of: file), "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    func testEmptyFile_matchesReferenceHash() throws {
        let file = root.appendingPathComponent("empty.txt")
        try Data().write(to: file)
        XCTAssertEqual(sha256(of: file), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testMultiChunkFile_matchesReferenceHash() throws {
        // 200.000 byte: attraversa più blocchi di lettura da 64KB, dove il vecchio
        // FileHandle.readData(ofLength:) faceva crescere la memoria residente in
        // proporzione ai byte letti (bug reale osservato su file da 40-50GB).
        let pattern = Array("AB".utf8)
        var data = Data(capacity: 200_000)
        while data.count < 200_000 { data.append(contentsOf: pattern) }
        data = data.prefix(200_000)
        let file = root.appendingPathComponent("multichunk.bin")
        try data.write(to: file)
        XCTAssertEqual(sha256(of: file), "e664cfbf670782ae86fdf757e9f12a3741afd8becdad3cb963e69f30472afce3")
    }

    func testNonExistentFile_returnsNil() {
        let file = root.appendingPathComponent("does-not-exist.txt")
        XCTAssertNil(sha256(of: file))
    }

    /// `sha256(of:)` delega a `sha256Measured`, quindi eredita la sua guardia: se la
    /// dimensione misurata sul descrittore non coincide con quella riportata da `fstat`
    /// prima E dopo la lettura, non restituisce nessun hash.
    ///
    /// Perche' un descrittore di pipe e non un file troncato da un altro thread: al
    /// livello delle syscall il sintomo e' identico (`st_size` letta prima della lettura
    /// non coincide con quella letta dopo — qui 4 -> 0, perche' su macOS `st_size` di
    /// una pipe e' il numero di byte ancora in coda, e leggerli la svuota), ma senza
    /// nessuna corsa fra thread: l'esito e' lo stesso a ogni run. Un test basato su una
    /// corsa sarebbe verde col bug ogni volta che la corsa va nell'altro verso.
    ///
    /// Copre l'unica parte del commit `a290d93` che esce dai confini di `LibraryIndexer`
    /// (che usa `sha256Measured` direttamente, quindi non esercita questa delega) ed era
    /// l'unica senza test: rimettendo in `sha256(of:)` il corpo pre-commit, senza
    /// controllo di dimensione, la suite completa restava verde.
    func testFileWhoseMeasuredSizeDisagreesWithFstat_returnsNil() throws {
        var fds: [Int32] = [0, 0]
        try XCTSkipUnless(pipe(&fds) == 0, "pipe() non disponibile")
        defer { close(fds[0]) }

        let payload = Array("ciao".utf8)
        let written = payload.withUnsafeBufferPointer { write(fds[1], $0.baseAddress, $0.count) }
        close(fds[1])   // nessuno scrittore: la lettura vede EOF dopo i 4 byte gia' in coda
        XCTAssertEqual(written, payload.count)

        let url = URL(fileURLWithPath: "/dev/fd/\(fds[0])")
        XCTAssertNil(sha256(of: url),
                     "byte letti e dimensione riportata non coincidono: nessun hash, mai un hash parziale")
    }
}
