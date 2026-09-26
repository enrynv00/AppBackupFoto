import XCTest
@testable import AppBackupFoto

/// L'invariante che rende `duplicateBatchFileCap` la granularita' vera dell'annullamento
/// automatico (ADR-0012), non un numero prudente scelto a tavolino.
///
/// Il registro di ripristino (`TrashManifestStore`) tiene al massimo `maxItems` voci e pota
/// le piu' vecchie. Sopra quel numero, un blocco poterebbe le voci **del blocco stesso**
/// mentre le sta ancora scrivendo, e «Annulla l'ultimo spostamento» rimetterebbe a posto
/// solo l'ultima parte del blocco — senza saperlo e senza dirlo. Un annullamento che mente
/// e' esattamente ciò che ADR-0009 esiste per impedire.
final class DuplicateCapInvariantTests: XCTestCase {
    func testFileCapNeverExceedsTheRegisterCeiling() {
        XCTAssertLessThanOrEqual(duplicateBatchFileCap, TrashManifestStore.maxItems)
    }
}
