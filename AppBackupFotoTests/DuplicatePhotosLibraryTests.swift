import XCTest
@testable import AppBackupFoto

/// Le copie in «Foto iPhone» che la libreria Foto del Mac ha ancora non escono mai (ADR-0018):
/// scelta della tenuta, blocco, piano della corsa, spiegazione e riepilogo. Logica pura.
///
/// Fixture costruite contro i mutanti, come in `DuplicateBatchTests`: la copia «nella libreria»
/// non e' mai la prima del gruppo, non e' la piu' vecchia e non ha il percorso piu' corto,
/// cosi' una regola che la ignorasse sceglierebbe un'altra copia.
final class DuplicatePhotosLibraryTests: XCTestCase {

    private func entry(_ displayPath: String, size: Int64 = 1_000, mtime: Double = 1_700_000_000) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(displayPath), displayPath: displayPath,
                          size: size, mtime: mtime, hash: "H", hashedAt: 1_700_003_600)
    }

    private func group(_ members: [LibraryIndexEntry], hash: String = "H") -> DuplicateGroup {
        DuplicateGroup(hash: hash, size: members.map(\.size).min() ?? 0,
                       members: members.map {
                           LibraryIndexEntry(path: $0.path, displayPath: $0.displayPath, size: $0.size,
                                             mtime: $0.mtime, hash: hash, hashedAt: $0.hashedAt)
                       })
    }

    /// La libreria Foto letta, con questi file (percorsi sotto «Foto iPhone»).
    private func photos(_ displayPaths: String...) -> PhotosLibraryPresence {
        .known(Set(displayPaths.map(normalizedIndexKey)))
    }

    private let rimossaDaFoto = "Foto iPhone/0/A.jpg"         // la piu' vecchia, percorso corto
    private let ancoraInFoto = "Foto iPhone/1/IMG_0002_lungo.jpg"

    // MARK: - Quale copia si tiene

    /// Senza la regola 1b vincerebbe la piu' vecchia (rimossa da Foto) e quella ancora in Foto
    /// resterebbe lo stesso: due copie tenute invece di una.
    func testKeeper_isTheCopyStillInPhotos_evenIfAnotherIsOlder() {
        let old = entry(rimossaDaFoto, mtime: 1_500_000_000)
        let inPhotos = entry(ancoraInFoto, mtime: 1_700_000_000)
        let c = duplicateKeepChoice(group([old, inPhotos]), rule: nil, photos: photos(ancoraInFoto))
        XCTAssertEqual(c.keeper.path, inPhotos.path)
        XCTAssertEqual(c.reason, .stillInPhotosLibrary)
        XCTAssertEqual(c.keptByPhotosLibrary, [])
        let e = DuplicateBatch.Entry(group: group([old, inPhotos]), choice: c)
        XCTAssertEqual(e.leaving.map(\.path), [old.path])
    }

    /// Il caso comune (una copia in «Foto iPhone», le altre fuori): tenuta e motivo come prima.
    func testCommonCase_mainLibraryVersusTakeout_isUnchanged() {
        let takeout = entry("Takeout/a.jpg", mtime: 1_500_000_000)
        let inPhotos = entry(ancoraInFoto)
        let c = duplicateKeepChoice(group([takeout, inPhotos]), rule: nil, photos: photos(ancoraInFoto))
        XCTAssertEqual(c.keeper.path, inPhotos.path)
        XCTAssertEqual(c.reason, .mainLibrary)
        XCTAssertEqual(DuplicateBatch.Entry(group: group([takeout, inPhotos]), choice: c).leaving.map(\.path), [takeout.path])
    }

    /// Due copie ancora in Foto (doppioni veri della libreria Foto) e una in Takeout: una delle
    /// due e' la tenuta, l'altra resta, esce solo Takeout.
    func testTwoCopiesStillInPhotos_bothStay_onlyTheOtherLeaves() {
        let f1 = entry("Foto iPhone/2/IMG_0003.jpg")
        let f2 = entry(ancoraInFoto)
        let takeout = entry("Takeout/b.jpg", mtime: 1_400_000_000)
        let g = group([takeout, f1, f2])
        let c = duplicateKeepChoice(g, rule: nil, photos: photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto))
        let e = DuplicateBatch.Entry(group: g, choice: c)
        XCTAssertTrue([f1.path, f2.path].contains(c.keeper.path))
        XCTAssertEqual(c.keptByPhotosLibrary, Set([f1.path, f2.path]).subtracting([c.keeper.path]))
        XCTAssertEqual(e.leaving.map(\.path), [takeout.path])
        XCTAssertEqual(e.keptByPhotosLibrary.count, 1)
        XCTAssertEqual(e.reclaimableBytes, 1_000, "si libera solo la copia di Takeout")
    }

    /// Tutte le copie in piu' ancora in Foto: niente da spostare.
    func testAllExtraCopiesStillInPhotos_nothingToMove() {
        let f1 = entry("Foto iPhone/2/IMG_0003.jpg")
        let f2 = entry(ancoraInFoto)
        let b = DuplicateBatch(groups: [group([f1, f2], hash: "h1")], rule: nil,
                               photos: photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto))
        XCTAssertEqual(b.groups.count, 1, "il gruppo resta visibile")
        XCTAssertEqual(b.groups[0].leaving.map(\.path), [])
        XCTAssertEqual(b.nothingToMove, ["h1"])
        XCTAssertEqual(b.fileCount, 0)
        XCTAssertEqual(b.reclaimableBytes, 0)
        XCTAssertEqual(b.keptByPhotosLibraryCount, 1)
    }

    /// La regola dell'utente resta sovrana: «tieni in Takeout, sposta da Foto iPhone» non sposta
    /// una copia ancora in Foto — il gruppo resta senza niente da spostare.
    func testUserRule_cannotMoveACopyStillInPhotos() {
        let takeout = entry("Takeout/a.jpg")
        let inPhotos = entry(ancoraInFoto)
        let rule = DuplicateFolderRule(keepIn: normalizedIndexKey("Takeout"), trashIn: [normalizedIndexKey("Foto iPhone")])
        let b = DuplicateBatch(groups: [group([inPhotos, takeout], hash: "h1")], rule: rule, photos: photos(ancoraInFoto))
        XCTAssertEqual(b.groups[0].choice.keeper.path, takeout.path)
        XCTAssertEqual(b.groups[0].choice.reason, .userFolderRule)
        XCTAssertEqual(b.nothingToMove, ["h1"])
    }

    /// «Tieni in Foto iPhone»: fra le copie li', quella ancora in Foto.
    func testUserRule_keepInFotoIPhone_prefersTheCopyStillInPhotos() {
        let old = entry(rimossaDaFoto, mtime: 1_500_000_000)
        let inPhotos = entry(ancoraInFoto)
        let takeout = entry("Takeout/a.jpg", mtime: 1_400_000_000)
        let rule = DuplicateFolderRule(keepIn: normalizedIndexKey("Foto iPhone"), trashIn: [normalizedIndexKey("Takeout")])
        let c = duplicateKeepChoice(group([old, takeout, inPhotos]), rule: rule, photos: photos(ancoraInFoto))
        XCTAssertEqual(c.keeper.path, inPhotos.path)
        XCTAssertEqual(c.reason, .stillInPhotosLibrary)
    }

    /// Libreria Foto non leggibile: ogni copia in «Foto iPhone» resta; quelle fuori escono.
    func testUnknownLibrary_keepsEveryFotoIPhoneCopy_butNotTheOthers() {
        let f1 = entry(rimossaDaFoto)
        let f2 = entry(ancoraInFoto)
        let takeout = entry("Takeout/a.jpg")
        let e = DuplicateBatch(groups: [group([takeout, f1, f2])], rule: nil, photos: .unknown).groups[0]
        XCTAssertEqual(e.leaving.map(\.path), [takeout.path])
        XCTAssertEqual(e.keptByPhotosLibrary.count, 1)
    }

    /// Libreria letta, nessuna copia ancora in Foto: tutto come prima.
    func testCopiesNoLongerInPhotos_leaveAsBefore() {
        let f1 = entry(rimossaDaFoto, mtime: 1_500_000_000)
        let f2 = entry(ancoraInFoto)
        let e = DuplicateBatch(groups: [group([f1, f2])], rule: nil, photos: photos("Foto iPhone/9/altro.jpg")).groups[0]
        XCTAssertEqual(e.choice.keeper.path, f1.path)
        XCTAssertEqual(e.choice.reason, .oldest)
        XCTAssertEqual(e.leaving.map(\.path), [f2.path])
    }

    // MARK: - Il blocco e la corsa contano solo le copie che escono

    func testBatchTotals_countOnlyTheCopiesThatLeave() {
        let keeper = entry("Foto iPhone/2/IMG_0003.jpg", size: 500)
        let stays = entry(ancoraInFoto, size: 500)
        let leaves = entry("Takeout/x.jpg", size: 500)
        let b = DuplicateBatch(groups: [group([leaves, stays, keeper], hash: "h1")], rule: nil,
                               photos: photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto))
        XCTAssertEqual(b.fileCount, 1)
        XCTAssertEqual(b.reclaimableBytes, 500)
        XCTAssertEqual(b.verifiedBytes, 1_500, "si rileggono comunque tutte le copie, anche quelle che restano")
        XCTAssertEqual(b.folderBreakdown.map(\.folder), ["Takeout"], "«Foto iPhone» non perde niente")
        XCTAssertEqual(b.nothingToMove, [])
    }

    func testRunPlan_splitsAndEstimatesOnTheCopiesThatLeave() {
        let g1 = group([entry("Foto iPhone/1/a.jpg"), entry("Foto iPhone/2/a.jpg"), entry("Takeout/a.jpg")], hash: "h1")
        let g2 = group([entry("Foto iPhone/3/b.jpg"), entry("Takeout/b.jpg")], hash: "h2")
        let b = DuplicateBatch(groups: [g1, g2], rule: nil,
                               photos: photos("Foto iPhone/1/a.jpg", "Foto iPhone/2/a.jpg", "Foto iPhone/3/b.jpg"))
        // Con 2 file per blocco: g1 fa uscire 1 file (non 2), quindi entrambi i gruppi stanno nello stesso blocco.
        XCTAssertEqual(DuplicateRunPlan(entries: b.groups, fileCap: 2, byteCap: .max).blocks.count, 1)
    }

    /// `init(entries:)` conserva le copie congelate come «nella libreria», senza ricalcolare.
    func testInitFromEntries_keepsTheFrozenSet() {
        let g = group([entry("Foto iPhone/1/a.jpg"), entry("Foto iPhone/2/a.jpg"), entry("Takeout/a.jpg")])
        let frozen = DuplicateBatch(groups: [g], rule: nil, photos: photos("Foto iPhone/1/a.jpg", "Foto iPhone/2/a.jpg"))
        let sub = DuplicateBatch(entries: frozen.groups)
        XCTAssertEqual(sub.groups[0].choice.keptByPhotosLibrary, frozen.groups[0].choice.keptByPhotosLibrary)
        XCTAssertEqual(sub.fileCount, 1)
        XCTAssertEqual(sub.keptByPhotosLibraryCount, 1)
    }

    // MARK: - Testi

    func testExplanation_saysWhyTheCopyStillInPhotosIsKept() {
        let old = entry(rimossaDaFoto, mtime: 1_500_000_000)
        let inPhotos = entry(ancoraInFoto)
        let g = group([old, inPhotos])
        let text = duplicateKeepExplanation(duplicateKeepChoice(g, rule: nil, photos: photos(ancoraInFoto)), in: g)
        XCTAssertEqual(text, "Tengo la copia che si trova in «Foto iPhone/1»: è ancora nella libreria Foto del Mac, "
            + "quindi resta comunque. Se la spostassi, il prossimo backup dal Mac la ricopierebbe. C'è 1 altra copia "
            + "che risulta identica a questa, in base all'ultimo controllo delle foto sull'SSD.")
    }

    func testExplanation_saysWhichOtherCopiesStay() {
        let f1 = entry("Foto iPhone/2/IMG_0003.jpg")
        let f2 = entry(ancoraInFoto)
        let all = photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto)
        let pair = group([f1, f2])
        XCTAssertTrue(duplicateKeepExplanation(duplicateKeepChoice(pair, rule: nil, photos: all), in: pair)
            .hasSuffix(" Anche quella resta in «Foto iPhone», perché è ancora nella libreria Foto del Mac."))
        let trio = group([f1, f2, entry("Takeout/z.jpg")])
        XCTAssertTrue(duplicateKeepExplanation(duplicateKeepChoice(trio, rule: nil, photos: all), in: trio)
            .hasSuffix(" Una di queste resta comunque in «Foto iPhone», perché è ancora nella libreria Foto del Mac."))
        let quartet = group([f1, f2, entry("Foto iPhone/4/c.jpg"), entry("Takeout/z.jpg")])
        let three = photos("Foto iPhone/2/IMG_0003.jpg", ancoraInFoto, "Foto iPhone/4/c.jpg")
        XCTAssertTrue(duplicateKeepExplanation(duplicateKeepChoice(quartet, rule: nil, photos: three), in: quartet)
            .hasSuffix(" 2 di queste restano comunque in «Foto iPhone», perché sono ancora nella libreria Foto del Mac."))
    }

    func testSummary_saysWhichCopiesStay_onlyWhenThereAreAny() {
        let g = group([entry("Foto iPhone/1/a.jpg"), entry("Foto iPhone/2/a.jpg"), entry("Takeout/a.jpg")])
        let with = DuplicateBatch(groups: [g], rule: nil, photos: photos("Foto iPhone/1/a.jpg", "Foto iPhone/2/a.jpg"))
        XCTAssertTrue(with.summaryLines().contains(
            "Resta dov'è 1 copia in «Foto iPhone», perché è ancora nella libreria Foto del Mac: se la spostassi, "
            + "il prossimo backup dal Mac la ricopierebbe."))
        let without = DuplicateBatch(groups: [g], rule: nil, photos: .known([]))
        XCTAssertFalse(without.summaryLines().contains { $0.contains("libreria Foto") })
    }
}
