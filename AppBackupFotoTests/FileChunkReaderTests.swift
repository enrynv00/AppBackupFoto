import XCTest
@testable import AppBackupFoto

final class FileChunkReaderTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory.appendingPathComponent("FileChunkReaderTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    func testChunksReconstructOriginalContent_nonMultipleSize() async throws {
        // 250 byte con chunk da 100: 3 chunk (100, 100, 50) — l'ultimo parziale
        // è il caso che rompe un off-by-one nel loop di lettura.
        var data = Data()
        for i in 0..<250 { data.append(UInt8(i % 256)) }
        let file = root.appendingPathComponent("data.bin")
        try data.write(to: file)

        var received: [Data] = []
        try await S3Syncer.readFileInChunks(path: file.path, chunkSize: 100) { chunk in
            received.append(chunk)
        }

        XCTAssertEqual(received.map(\.count), [100, 100, 50])
        XCTAssertEqual(received.reduce(Data(), +), data)
    }

    func testEmptyFile_producesNoChunks() async throws {
        let file = root.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        var callCount = 0
        try await S3Syncer.readFileInChunks(path: file.path, chunkSize: 100) { _ in callCount += 1 }

        XCTAssertEqual(callCount, 0)
    }

    func testNonExistentFile_throws() async {
        do {
            try await S3Syncer.readFileInChunks(path: root.appendingPathComponent("missing.bin").path, chunkSize: 100) { _ in }
            XCTFail("Doveva lanciare un errore")
        } catch {
            // atteso
        }
    }

    func testOnChunkError_propagates() async throws {
        let data = Data(repeating: 0xAB, count: 300)
        let file = root.appendingPathComponent("data.bin")
        try data.write(to: file)

        struct TestError: Error {}
        do {
            try await S3Syncer.readFileInChunks(path: file.path, chunkSize: 100) { _ in throw TestError() }
            XCTFail("Doveva propagare l'errore di onChunk")
        } catch is TestError {
            // atteso
        }
    }
}
