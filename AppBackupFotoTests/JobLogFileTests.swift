import XCTest
@testable import AppBackupFoto

/// ROADMAP #43, ADR-0014: il registro completo di ogni job sul disco del Mac, con l'ora su ogni
/// riga, la conservazione degli ultimi 50 e «Salva» che esporta il file intero. Ogni test lavora
/// in una cartella temporanea sua; nessun test tocca `/Volumes` ne' `~/Library/Logs`.
final class JobLogFileTests: XCTestCase {
    private var tmp: URL!
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-26 09:10:39 UTC.
    private let fixed = Date(timeIntervalSince1970: 1_790_413_839)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("JobLogFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func isRegular(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    private func writeManyLines(_ log: JobLogFile) {
        for i in 0..<2000 {
            log.write("STATUS: Carico: Foto iPhone/0/IMG_\(String(format: "%05d", i)).HEIC\n", at: fixed)
        }
    }

    func testDefaultDirectory_isInTheUserLibraryLogs_neverOnAVolume() {
        let p = JobLogFile.defaultDirectory(isRunningUnderTests: false).path
        XCTAssertTrue(p.hasSuffix("/Library/Logs/AppBackupFoto"), p)
        XCTAssertTrue(p.hasPrefix(NSHomeDirectory()), p)
        XCTAssertFalse(p.hasPrefix("/Volumes/"), p)
    }

    /// BUG-10: sotto test il registro non va nella cartella vera dell'utente.
    func testDefaultDirectory_underTests_isInTheTemporaryFolder() {
        let p = JobLogFile.defaultDirectory(isRunningUnderTests: true).standardized.path
        XCTAssertTrue(p.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).standardized.path), p)
        XCTAssertFalse(p.contains("/Library/Logs/"), p)
    }

    func testFileName_format() {
        XCTAssertEqual(JobLogFile.fileName(startedAt: fixed, timeZone: utc), "backup_2026-09-26_09-10-39.log")
        XCTAssertTrue(JobLogFile.isLogFileName(JobLogFile.fileName(startedAt: Date())))
    }

    func testStamped_prefixesEveryLine() {
        XCTAssertEqual(JobLogFile.stamped("a\nb\n", at: fixed, timeZone: utc),
                       "2026-09-26 09:10:39  a\n2026-09-26 09:10:39  b\n")
        XCTAssertEqual(JobLogFile.stamped("a\n\nb", at: fixed, timeZone: utc),
                       "2026-09-26 09:10:39  a\n\n2026-09-26 09:10:39  b")
    }

    func testWriteAndFinish_fileHasHeaderLinesAndClosing() throws {
        let log = JobLogFile(directory: tmp, startedAt: fixed, header: "AppBackupFoto 1.2 — SSD -> Cubbit S3")
        log.write("STATUS: uno\n", at: fixed)
        log.write("STATUS: due\n", at: fixed)
        log.write("STATUS: tre\n", at: fixed)
        log.finish(closingLine: "Fine del job: prova")
        log.waitForPendingWrites()
        let lines = read(log.url).split(separator: "\n").map(String.init)
        guard lines.count == 5 else { return XCTFail("attese 5 righe, sono \(lines.count): \(lines)") }
        XCTAssertTrue(lines[0].hasSuffix("  AppBackupFoto 1.2 — SSD -> Cubbit S3"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("  STATUS: uno"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("  STATUS: due"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("  STATUS: tre"), lines[3])
        XCTAssertTrue(lines[4].hasSuffix("  Fine del job: prova"), lines[4])
        XCTAssertEqual(log.url.deletingLastPathComponent().standardized.path, tmp.standardized.path)
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testWritesAfterFinish_areIgnored() {
        let log = JobLogFile(directory: tmp, startedAt: fixed, header: "h")
        log.finish(closingLine: "fine uno")
        log.write("DOPO\n", at: fixed)
        log.finish(closingLine: "fine due")
        log.waitForPendingWrites()
        let text = read(log.url)
        XCTAssertTrue(text.contains("fine uno"), text)
        XCTAssertFalse(text.contains("DOPO"), text)
        XCTAssertFalse(text.contains("fine due"), text)
    }

    /// La regressione di questo intervento: il log salvato il 2026-09-26 era lungo esattamente
    /// 60.000 caratteri e cominciava a meta' di una riga.
    func testMoreThanSixtyThousandCharacters_areAllKept() {
        let log = JobLogFile(directory: tmp, startedAt: fixed, header: "h")
        writeManyLines(log)
        log.finish(closingLine: "fine")
        log.waitForPendingWrites()
        let text = read(log.url)
        XCTAssertGreaterThan(text.count, 100_000)
        XCTAssertTrue(text.contains("IMG_00000.HEIC"))
        XCTAssertTrue(text.contains("IMG_01999.HEIC"))
    }

    func testExport_copiesTheWholeFile() {
        let log = JobLogFile(directory: tmp, startedAt: fixed, header: "h")
        writeManyLines(log)
        let dest = tmp.appendingPathComponent("esportato.txt")
        let done = expectation(description: "export")
        log.export(to: dest, fallback: "SOLO CODA") { ok in
            XCTAssertTrue(ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let out = read(dest)
        XCTAssertTrue(out.contains("IMG_00000.HEIC"))
        XCTAssertTrue(out.contains("IMG_01999.HEIC"))
        XCTAssertFalse(out.contains("SOLO CODA"))
    }

    func testExport_withoutAFile_writesTheFallbackWithANote() throws {
        let notADirectory = tmp.appendingPathComponent("file-non-cartella")
        try Data("x".utf8).write(to: notADirectory)
        let log = JobLogFile(directory: notADirectory, startedAt: fixed, header: "h")
        let dest = tmp.appendingPathComponent("esportato.txt")
        let done = expectation(description: "export")
        log.export(to: dest, fallback: "SOLO CODA") { ok in
            XCTAssertFalse(ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let out = read(dest)
        XCTAssertTrue(out.hasPrefix(JobLogFile.unavailableNote), out)
        XCTAssertTrue(out.hasSuffix("SOLO CODA"), out)
    }

    func testUnwritableDirectory_neverCrashes_andWritesNothing() throws {
        let notADirectory = tmp.appendingPathComponent("file")
        try Data("contenuto".utf8).write(to: notADirectory)
        let log = JobLogFile(directory: notADirectory, startedAt: fixed, header: "h")
        log.write("riga\n", at: fixed)
        log.finish(closingLine: "fine")
        log.waitForPendingWrites()
        XCTAssertEqual(read(notADirectory), "contenuto")
        XCTAssertEqual(names(in: tmp), ["file"])
    }

    /// Al posto di `/Volumes` (che nessun test tocca) una radice rifiutata finta: niente viene
    /// creato dentro, nemmeno la cartella.
    func testRefusedRoot_isNeverWritten() throws {
        let refused = tmp.appendingPathComponent("Volume finto")
        try FileManager.default.createDirectory(at: refused, withIntermediateDirectories: true)
        let log = JobLogFile(directory: refused.appendingPathComponent("Logs"), startedAt: fixed, header: "h",
                             refusedRoots: [refused.path])
        log.write("riga\n", at: fixed)
        log.finish(closingLine: "fine")
        log.waitForPendingWrites()
        XCTAssertEqual(names(in: refused), [])
        let roots = JobLogFile.defaultRefusedRoots
        XCTAssertTrue(JobLogFile.isRefused("/Volumes/SSD - Enri/Logs", refusedRoots: roots))
        XCTAssertTrue(JobLogFile.isRefused("/Volumes", refusedRoots: roots))
        XCTAssertTrue(JobLogFile.isRefused("/Users/x/../../Volumes/BackupHDD", refusedRoots: roots))
        XCTAssertTrue(JobLogFile.isRefused("/volumes/SSD - Enri/Logs", refusedRoots: roots))
        XCTAssertFalse(JobLogFile.isRefused("/VolumesX/a", refusedRoots: roots))
        XCTAssertFalse(JobLogFile.isRefused("/Users/x/Library/Logs/AppBackupFoto", refusedRoots: roots))
    }

    /// Una cartella dei log che passa da un collegamento verso una radice rifiutata si riconosce
    /// prima di creare qualunque cosa.
    func testDirectoryThroughALinkToARefusedRoot_isRefused() throws {
        let target = tmp.appendingPathComponent("destinazione")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("collegamento")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let log = JobLogFile(directory: link.appendingPathComponent("Logs"), startedAt: fixed, header: "h",
                             refusedRoots: [realResolvedPath(target)])
        log.write("riga\n", at: fixed)
        log.finish(closingLine: "fine")
        log.waitForPendingWrites()
        XCTAssertEqual(names(in: target), [])
    }

    func testNamesToPrune_keepsTheNewest() {
        let all = (0..<53).map { String(format: "backup_2026-01-01_00-00-%02d.log", $0) }
        let pruned = JobLogFile.namesToPrune(all.shuffled(), keep: 50, protecting: all[52])
        XCTAssertEqual(pruned, Array(all.prefix(3)))
    }

    func testNamesToPrune_ignoresEverythingElse_andProtectsTheCurrent() {
        let valid = (0..<3).map { "backup_2026-01-01_00-00-0\($0).log" }
        let other = ["note.txt", "backup_x.log", "backup_2026-09-26_09-10-39.log.bak", ".DS_Store",
                     "Backup_2026-01-01_00-00-00.log", "backup_2026-01-01_00-00-0a.log", "../backup_2026-01-01_00-00-00.log"]
        for name in other { XCTAssertFalse(JobLogFile.isLogFileName(name), name) }
        // Il nome protetto e' il piu' vecchio (orologio tornato indietro): resta lo stesso.
        XCTAssertEqual(JobLogFile.namesToPrune(valid + other, keep: 1, protecting: valid[0]), [valid[1], valid[2]])
        XCTAssertEqual(JobLogFile.namesToPrune(valid + other, keep: 3, protecting: ""), [])
    }

    func testPruneOnDisk_removesOnlyOldMatchingFiles() throws {
        let fm = FileManager.default
        let old = (0..<52).map { String(format: "backup_2000-01-01_00-00-%02d.log", $0) }
        for name in old { try Data("vecchio".utf8).write(to: tmp.appendingPathComponent(name)) }
        try Data("mie note".utf8).write(to: tmp.appendingPathComponent("appunti.txt"))
        let folder = tmp.appendingPathComponent("backup_1999-01-01_00-00-00.log")   // nome valido, ma cartella
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("dentro".utf8).write(to: folder.appendingPathComponent("dentro.txt"))
        let log = JobLogFile(directory: tmp, startedAt: Date(), header: "h")
        log.waitForPendingWrites()
        let logs = names(in: tmp).filter { JobLogFile.isLogFileName($0) && isRegular(tmp.appendingPathComponent($0)) }
        XCTAssertEqual(logs.count, 50)
        XCTAssertTrue(logs.contains(log.url.lastPathComponent))
        for gone in old.prefix(3) { XCTAssertFalse(logs.contains(gone), gone) }
        XCTAssertEqual(read(tmp.appendingPathComponent("appunti.txt")), "mie note")
        XCTAssertEqual(read(folder.appendingPathComponent("dentro.txt")), "dentro")
    }

    /// Un collegamento con un nome valido non si cancella mai, e la sua destinazione nemmeno.
    func testPrune_neverTouchesALink() throws {
        let fm = FileManager.default
        let outside = tmp.appendingPathComponent("fuori")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let photo = outside.appendingPathComponent("foto.jpg")
        try Data("foto".utf8).write(to: photo)
        let logs = tmp.appendingPathComponent("Logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        for i in 0..<50 {
            try Data("vecchio".utf8).write(to: logs.appendingPathComponent(String(format: "backup_2000-01-01_00-00-%02d.log", i)))
        }
        let link = logs.appendingPathComponent("backup_1990-01-01_00-00-00.log")
        try fm.createSymbolicLink(at: link, withDestinationURL: photo)
        let log = JobLogFile(directory: logs, startedAt: Date(), header: "h")
        log.waitForPendingWrites()
        XCTAssertNoThrow(try fm.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(read(photo), "foto")
        XCTAssertFalse(fm.fileExists(atPath: logs.appendingPathComponent("backup_2000-01-01_00-00-00.log").path))
    }

    func testTwoJobsInTheSameSecond_appendNotOverwrite() {
        let first = JobLogFile(directory: tmp, startedAt: fixed, header: "PRIMO")
        first.write("riga uno\n", at: fixed)
        first.finish(closingLine: "fine uno")
        first.waitForPendingWrites()
        let second = JobLogFile(directory: tmp, startedAt: fixed, header: "SECONDO")
        second.finish(closingLine: "fine due")
        second.waitForPendingWrites()
        XCTAssertEqual(first.url, second.url)
        let text = read(first.url)
        for piece in ["PRIMO", "riga uno", "fine uno", "SECONDO", "fine due"] { XCTAssertTrue(text.contains(piece), piece) }
        guard let firstEnd = text.range(of: "fine uno"), let secondStart = text.range(of: "SECONDO") else {
            return XCTFail("un registro ha sovrascritto l'altro: \(text)")
        }
        XCTAssertLessThan(firstEnd.lowerBound, secondStart.lowerBound)
    }

    func testClosingLine_hasAllNumbers() {
        let line = JobLogFile.closingLine(phaseLabel: "Completato: SSD -> Cubbit S3", copied: 12, skipped: 3400,
                                          errors: 2, elapsed: "01:02:03")
        for piece in ["Completato: SSD -> Cubbit S3", "copiati 12", "saltati 3400", "errori 2", "durata 01:02:03"] {
            XCTAssertTrue(line.contains(piece), line)
        }
    }

    // MARK: - Guardia sul sorgente (per il Security/Rules Auditor)

    /// Il sorgente dell'app: accanto alla cartella dei test nel repository, o in `src/` nella
    /// verifica veloce fuori da Xcode (stesso schema di `AlignmentDeleteGuardTests`).
    private func source(file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["AppBackupFoto/ContentView.swift", "src/ContentView.swift"] {
            let url = root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        XCTFail("Non trovo ContentView.swift accanto a \(root.path): il controllo non puo' girare.")
        return ""
    }

    /// L'unica cancellazione di file di questo intervento sta dentro `JobLogFile.prune`. Se ne
    /// aggiungi un'altra in questa classe, il test fallisce apposta: prima va scritto perche'.
    func testJobLogFile_hasExactlyOneRemoveItem_insidePrune() throws {
        let src = try source()
        guard let start = src.range(of: "nonisolated final class JobLogFile"),
              let end = src.range(of: "// MARK: - BackupRunner", range: start.upperBound..<src.endIndex) else {
            return XCTFail("non trovo JobLogFile nel sorgente")
        }
        let body = String(src[start.lowerBound..<end.lowerBound])
        XCTAssertEqual(body.components(separatedBy: "removeItem(").count - 1, 1)
        guard let prune = body.range(of: "private func prune()"), let use = body.range(of: "removeItem(") else {
            return XCTFail("la cancellazione deve stare dentro prune()")
        }
        XCTAssertLessThan(prune.lowerBound, use.lowerBound)
    }
}
