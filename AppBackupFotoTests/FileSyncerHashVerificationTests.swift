//
//  FileSyncerHashVerificationTests.swift
//  AppBackupFotoTests
//
//  Verifica post-copia SHA256: i tre esiti devono restare distinti.
//
//  Fino al 2026-08-26 questo ramo era completamente scoperto — `hashErrors` compariva
//  nei test solo come `XCTAssertEqual(result.hashErrors, 0)`. Il difetto che nascondeva:
//  `if let srcHash = ..., let dstHash = ..., srcHash != dstHash { hashErrors } else { copied }`
//  faceva finire anche il caso `nil` (uno dei due hash non calcolabile) fra i file
//  VERIFICATI. Misurato end-to-end con una sorgente da 200MB che cresce durante la
//  verifica: `copied=1 hashErrors=0`, src 259MB, dst 210MB, hash diversi. E per la
//  regola zero-overwrite quel file parziale a destinazione non viene mai piu' ricopiato.
//
//  Perche' l'hash e' iniettato invece di provocare il guasto su file veri: i tre esiti
//  richiederebbero una corsa fra la copia e la verifica (file che cresce/si tronca/
//  diventa illeggibile in quella finestra). Un test basato su una corsa e' verde col bug
//  ogni volta che la corsa va nell'altro verso — l'errore che questo progetto ha gia'
//  pagato piu' volte. Il default di `FileSyncer.init` resta la vera `sha256(of:)`, e il
//  primo test qui sotto usa proprio quella su file reali.
//

import XCTest
@testable import AppBackupFoto

final class FileSyncerHashVerificationTests: XCTestCase {
    private var root: URL!
    private var srcDir: URL!
    private var dstDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("FileSyncerHashVerificationTests-\(UUID().uuidString)", isDirectory: true)
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
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = srcDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // Caso normale, con la vera `sha256(of:)`: copia verificata.
    func testVerifiedCopy_countsAsCopied() async throws {
        try writeFile("a.jpg", "contenuto")

        let syncer = FileSyncer()
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.hashErrors, 0)
        XCTAssertEqual(result.copiedUnverified, 0)
    }

    // Mismatch VERO: i due hash si calcolano entrambi e sono diversi. E' l'allarme
    // "copia non integra", e deve restare distinto dal caso non verificabile.
    func testRealMismatch_countsAsHashErrorAndNotAsCopied() async throws {
        try writeFile("a.jpg", "contenuto")

        let syncer = FileSyncer(hashFunction: { url in
            url.path.contains("/src/") ? "aaaa" : "bbbb"
        })
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.hashErrors, 1)
        XCTAssertEqual(result.copied, 0, "un mismatch non e' una copia verificata")
        XCTAssertEqual(result.copiedUnverified, 0, "un mismatch non e' 'non verificabile'")
    }

    // Il rilievo bloccante: hash della SORGENTE non calcolabile (file cresciuto o
    // troncato mentre lo leggevamo). Il file e' stato copiato, ma NON e' stato
    // verificato: non deve finire fra i verificati, e non deve nemmeno essere contato
    // come mismatch (sovrastimare le corruzioni insegna a ignorare l'allarme).
    func testUnverifiableSourceHash_isNotCountedAsCopied() async throws {
        try writeFile("a.jpg", "contenuto")

        let syncer = FileSyncer(hashFunction: { url in
            url.path.contains("/src/") ? nil : "bbbb"
        })
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.copiedUnverified, 1)
        XCTAssertEqual(result.copied, 0, "una copia non verificata non va fra quelle verificate")
        XCTAssertEqual(result.hashErrors, 0, "non e' un mismatch: il file quasi certamente sta bene")
        XCTAssertTrue(fm.fileExists(atPath: dstDir.appendingPathComponent("a.jpg").path),
                      "il file e' comunque stato copiato: e' la verifica a non aver concluso")
    }

    // Stesso caso dal lato destinazione.
    func testUnverifiableDestinationHash_isNotCountedAsCopied() async throws {
        try writeFile("a.jpg", "contenuto")

        let syncer = FileSyncer(hashFunction: { url in
            url.path.contains("/dst/") ? nil : "aaaa"
        })
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.copiedUnverified, 1)
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(result.hashErrors, 0)
    }

    // La riga di riepilogo deve poter dire "N su M": i tre esiti convivono nello stesso
    // job e si sommano ciascuno nel proprio contatore.
    func testThreeOutcomesInOneJob_areCountedSeparately() async throws {
        try writeFile("ok.jpg", "uno")
        try writeFile("mismatch.jpg", "due")
        try writeFile("unverified.jpg", "tre")

        let syncer = FileSyncer(hashFunction: { url in
            switch url.lastPathComponent {
            case "ok.jpg": return "uguale"
            case "mismatch.jpg": return url.path.contains("/src/") ? "aaaa" : "bbbb"
            default: return url.path.contains("/src/") ? nil : "cccc"
            }
        })
        let result = try await syncer.sync(from: srcDir, to: dstDir, deep: false,
                                           onStatus: { _ in }, onProgress: { _ in })

        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.hashErrors, 1)
        XCTAssertEqual(result.copiedUnverified, 1)
        XCTAssertEqual(result.done, 3)
    }
}
