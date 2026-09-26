import XCTest
@testable import AppBackupFoto

/// `DuplicateFilter` e le funzioni pure collegate (`duplicateGroupIsInternal`,
/// `duplicateFolderList`) — i tre filtri del pannello Doppioni alla scala reale
/// (ADR-0011, spec §2.2). Pura: nessun filesystem, nessun database.
final class DuplicateFilterTests: XCTestCase {

    private func entry(_ path: String, mtime: Double = 1_700_000_000) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(path), displayPath: path,
                          size: 1_000, mtime: mtime, hash: "h", hashedAt: 1_700_003_600)
    }

    private func group(_ members: [LibraryIndexEntry], hash: String = "h") -> DuplicateGroup {
        DuplicateGroup(hash: hash, size: members.map(\.size).min() ?? 0,
                       members: members.map {
                           LibraryIndexEntry(path: $0.path, displayPath: $0.displayPath, size: $0.size,
                                             mtime: $0.mtime, hash: hash, hashedAt: $0.hashedAt)
                       })
    }

    private func rule(keepIn: String, trashIn: Set<String>) -> DuplicateFolderRule {
        DuplicateFolderRule(keepIn: normalizedIndexKey(keepIn), trashIn: Set(trashIn.map(normalizedIndexKey)))
    }

    // MARK: - Filtro cartella

    func testFolderFilter_keepsGroupsWithAtLeastOneCopyThere() {
        let inTakeout = group([entry("Takeout/a.jpg"), entry("Other/a.jpg")], hash: "g1")
        let notInTakeout = group([entry("Other/b.jpg"), entry("Foto iPhone/b.jpg")], hash: "g2")
        let groups = [inTakeout, notInTakeout]
        let f = DuplicateFilter(folder: normalizedIndexKey("Takeout"))
        XCTAssertEqual(f.apply(to: groups), [0])
    }

    // MARK: - Filtro tipo di gruppo

    func testKindFilter_internalGroups_areThoseWithAllCopiesInOneFolder() {
        let internalGroup = group([entry("Takeout/a.jpg"), entry("Takeout/b.jpg")], hash: "g1")
        let crossGroup = group([entry("Takeout/a.jpg"), entry("Other/a.jpg")], hash: "g2")
        let groups = [internalGroup, crossGroup]
        let f = DuplicateFilter(internalOnly: true)
        XCTAssertEqual(f.apply(to: groups), [0])
    }

    // Le due meta' devono partizionare l'elenco: nessun gruppo fuori da entrambe, nessuno
    // in entrambe. Include un gruppo con un file in radice, il caso che rompe piu'
    // facilmente un'implementazione ingenua (ne' "tutto in una cartella" ne' ovviamente
    // "incrociato" a prima vista).
    func testKindFilter_crossFolderGroups_areTheComplement() {
        let internalGroup = group([entry("Takeout/a.jpg"), entry("Takeout/b.jpg")], hash: "g1")
        let crossGroup = group([entry("Takeout/a.jpg"), entry("Other/a.jpg")], hash: "g2")
        let rootMixedGroup = group([entry("a.jpg"), entry("Takeout/a.jpg")], hash: "g3")
        let allSameFolderThree = group([entry("Other/a.jpg"), entry("Other/b.jpg"),
                                        entry("Other/c.jpg")], hash: "g4")
        let groups = [internalGroup, crossGroup, rootMixedGroup, allSameFolderThree]

        let internalIndices = Set(DuplicateFilter(internalOnly: true).apply(to: groups))
        let crossIndices = Set(DuplicateFilter(internalOnly: false).apply(to: groups))

        XCTAssertEqual(internalIndices.intersection(crossIndices), [])
        XCTAssertEqual(internalIndices.union(crossIndices), Set(groups.indices))
    }

    // MARK: - Filtro regola

    func testRuleFilter_keepsOnlyCoveredGroups() {
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        let covered = group([entry("Foto iPhone/a.jpg"), entry("Takeout/a.jpg")], hash: "g1")
        let notCovered = group([entry("Other/a.jpg"), entry("Other 2/a.jpg")], hash: "g2")
        let groups = [covered, notCovered]
        let f = DuplicateFilter(rule: r)
        XCTAssertEqual(f.apply(to: groups), [0])
    }

    // MARK: - Composizione

    func testFilters_composeWithAnd() {
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout"])
        // Soddisfa cartella + regola, ma NON e' interno (due cartelle diverse).
        let matchesFolderAndRuleOnly = group([entry("Foto iPhone/a.jpg"), entry("Takeout/a.jpg")], hash: "g1")
        // Soddisfa cartella + interno, ma non e' coperto dalla regola (niente Takeout).
        let matchesFolderAndInternalOnly = group([entry("Foto iPhone/a.jpg"), entry("Foto iPhone/b.jpg")], hash: "g2")
        // Non soddisfa il filtro cartella.
        let matchesNothing = group([entry("Other/a.jpg"), entry("Other 2/a.jpg")], hash: "g3")
        let groups = [matchesFolderAndRuleOnly, matchesFolderAndInternalOnly, matchesNothing]

        let f = DuplicateFilter(folder: normalizedIndexKey("Foto iPhone"), internalOnly: false, rule: r)
        XCTAssertEqual(f.apply(to: groups), [0])
    }

    func testEmptyFilter_keepsEverything() {
        let groups = [group([entry("Takeout/a.jpg"), entry("Other/a.jpg")], hash: "g1"),
                     group([entry("Foto iPhone/a.jpg"), entry("Foto iPhone/b.jpg")], hash: "g2")]
        XCTAssertEqual(DuplicateFilter().apply(to: groups), Array(groups.indices))
    }

    // MARK: - Elenco delle cartelle

    func testFolderList_comesFromTheGroups_notFromTheDisk() {
        let groups = [group([entry("Takeout/a.jpg"), entry("Other/a.jpg")], hash: "g1")]
        let list = duplicateFolderList(groups)
        XCTAssertEqual(Set(list.map(\.folder)), Set([normalizedIndexKey("Takeout"), normalizedIndexKey("Other")]))
        // Nessuna cartella "immaginata": solo quelle davvero presenti fra i membri.
        XCTAssertFalse(list.map(\.folder).contains(normalizedIndexKey("Foto iPhone")))
    }

    func testFolderList_countsGroupsNotFiles() {
        // Tre file dello STESSO gruppo nella stessa cartella: deve contare 1, non 3.
        let threeInSameFolder = group([entry("Other/a.jpg"), entry("Other/b.jpg"),
                                       entry("Other/c.jpg")], hash: "g1")
        let oneMoreInSameFolder = group([entry("Other/d.jpg"), entry("Takeout/d.jpg")], hash: "g2")
        let list = duplicateFolderList([threeInSameFolder, oneMoreInSameFolder])
        let other = list.first { $0.folder == normalizedIndexKey("Other") }
        XCTAssertEqual(other?.count, 2, "due gruppi hanno una copia in Other, non conta i file")
    }

    func testFolderList_isSortedDeterministically() {
        let groups = [group([entry("Takeout 2/a.jpg")], hash: "g1"),
                     group([entry("Other/a.jpg")], hash: "g2"),
                     group([entry("Foto iPhone/a.jpg")], hash: "g3")]
        let list = duplicateFolderList(groups)
        XCTAssertEqual(list.map(\.folder), list.map(\.folder).sorted(),
                       "l'elenco deve essere gia' ordinato, non dipendere dall'ordine dei gruppi")
    }

    // MARK: - File in radice

    func testFileAtTheRoot_hasNoTopLevelFolder_andIsCountedAsSuch() {
        let g = group([entry("a.jpg"), entry("Takeout/a.jpg")], hash: "g1")
        // Non e' interno: il file in radice non condivide nessuna cartella col resto.
        XCTAssertFalse(duplicateGroupIsInternal(g))
        // Ma il filtro cartella lo trova comunque, grazie al membro in Takeout.
        XCTAssertEqual(DuplicateFilter(folder: normalizedIndexKey("Takeout")).apply(to: [g]), [0])
        // L'elenco delle cartelle non inventa una voce per la radice.
        let list = duplicateFolderList([g])
        XCTAssertEqual(list.map(\.folder), [normalizedIndexKey("Takeout")])
    }
}
