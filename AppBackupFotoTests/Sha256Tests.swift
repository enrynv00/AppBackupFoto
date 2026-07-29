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
}
