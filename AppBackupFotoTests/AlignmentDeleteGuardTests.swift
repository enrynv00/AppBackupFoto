import XCTest
@testable import AppBackupFoto

/// Il DELETE su Cubbit e' nuovo nel progetto (ADR-0019) e deve restare chiuso dove sta. Questi
/// test leggono il sorgente di `ContentView.swift` e pretendono che le richieste DELETE siano
/// esattamente quelle previste, e che l'unico DELETE con versione sia quello che toglie un segno
/// di cancellazione. Se ne aggiungi un'altra, questo test fallisce apposta: prima va scritto
/// perche' in ADR-0019 e nella checklist «IF il codice fa chiamate S3» di `Docs/CLAUDE.md`.
final class AlignmentDeleteGuardTests: XCTestCase {
    /// Il sorgente dell'app: accanto alla cartella dei test nel repository
    /// (`AppBackupFoto/ContentView.swift`), o in `src/` nella verifica veloce fuori da Xcode.
    private func source(file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        for rel in ["AppBackupFoto/ContentView.swift", "src/ContentView.swift"] {
            let url = root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        XCTFail("Non trovo ContentView.swift accanto a \(root.path): il controllo sul DELETE non puo' girare.")
        return ""
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testOnlyThreeRequestsUseDELETE() throws {
        // AbortMultipartUpload (non tocca dati scritti), il DELETE senza versione del progetto 4
        // e la rimozione di un segno di cancellazione registrato. Nient'altro.
        XCTAssertEqual(count("httpMethod = \"DELETE\"", in: try source()), 3)
    }

    func testTheOnlyRequestWithAVersionId_isTheDeleteMarkerRemoval() throws {
        let src = try source()
        XCTAssertEqual(count("\"?versionId=\"", in: src), 1)
        guard let fn = src.range(of: "func removeDeleteMarkerForAlignment("),
              let use = src.range(of: "\"?versionId=\""), fn.upperBound <= use.lowerBound else {
            return XCTFail("il ?versionId= deve stare dentro removeDeleteMarkerForAlignment")
        }
        let body = src[fn.upperBound..<use.lowerBound]
        XCTAssertFalse(body.contains("\n    func "), "il ?versionId= deve stare dentro removeDeleteMarkerForAlignment")
    }

    func testTheTwoAlignmentDeletesAreCalledOnlyByTheCubbitAdapter() throws {
        let src = try source()
        XCTAssertEqual(count("deleteObjectForAlignment(", in: src), 2, "definizione + S3AlignmentCloud")
        XCTAssertEqual(count("removeDeleteMarkerForAlignment(", in: src), 2, "definizione + S3AlignmentCloud")
    }

    func testTheEngineSendsTheDeleteFromOnePlaceOnly() throws {
        // Un solo punto del motore manda il DELETE senza versione (dopo le versioni lette e le
        // due HEAD). Se ne serve un secondo, va scritto perche' in ADR-0019.
        XCTAssertEqual(count("cloud.delete(key:", in: try source()), 1)
    }

    func testTheUndoRemovesDeleteMarkersFromOnePlaceOnly() throws {
        XCTAssertEqual(count("cloud.removeDeleteMarker(", in: try source()), 1)
    }

    /// 2026-10-14 (nota in ADR-0019): ogni Cubbit che `BackupRunner` da' al motore ritenta da
    /// solo le letture (`RetryingAlignmentCloud`), e quel Cubbit passa i due DELETE una volta
    /// sola (lo provano `AlignmentEngineCubbitTests`). Un `S3AlignmentCloud` nudo farebbe fermare
    /// una corsa di ore al primo errore passeggero della rete.
    func testEveryCubbitGivenToTheEngine_retriesItsReads() throws {
        let src = try source()
        let built = count("S3AlignmentCloud(syncer:", in: src)
        XCTAssertEqual(built, 3, "controllo, corsa, annullamento")
        XCTAssertEqual(count("RetryingAlignmentCloud(S3AlignmentCloud(syncer:", in: src), built)
    }
}
