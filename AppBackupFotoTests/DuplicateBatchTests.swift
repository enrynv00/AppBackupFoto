import XCTest
@testable import AppBackupFoto

/// Il riepilogo che l'utente legge **prima** della conferma distruttiva.
///
/// Le fixture di questo file sono costruite a partire dal **mutante** e non dall'intento:
/// nel Task 2 sei test si sono rivelati ciechi perche' la fixture rendeva indistinguibili
/// due formule diverse (la copia tenuta sempre in prima posizione, lunghezza e alfabeto
/// sempre concordi, `contains` di una sottostringa invece della frase intera). Qui ogni
/// caso e' scelto in modo che le due formule in gara si **contraddicano**.
final class DuplicateBatchTests: XCTestCase {

    private func entry(_ path: String, size: Int64 = 1_000, mtime: Double = 1_700_000_000) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(path),
                          displayPath: path,
                          size: size,
                          mtime: mtime,
                          hash: "h",
                          hashedAt: 1_700_000_000)
    }

    /// Un gruppo con hash distinto, cosi' due gruppi non si confondono mai fra loro.
    private func group(_ members: [LibraryIndexEntry], hash: String = "h", size: Int64? = nil) -> DuplicateGroup {
        DuplicateGroup(hash: hash,
                       size: size ?? (members.map(\.size).min() ?? 0),
                       members: members.map {
                           LibraryIndexEntry(path: $0.path, displayPath: $0.displayPath, size: $0.size,
                                             mtime: $0.mtime, hash: hash, hashedAt: $0.hashedAt)
                       })
    }

    // MARK: - Aritmetica

    /// L'errore aritmetico piu' facile della feature: la copia che resta occupa comunque il
    /// suo spazio, quindi si liberano `size × (copie − 1)` byte e non `size × copie`.
    /// La fixture usa **3** membri: con 2 membri `count` e `count − 1` valgono 2 e 1, ma un
    /// mutante `size × count / 2` darebbe comunque il risultato giusto. Con 3 membri
    /// 2×size e' distinguibile sia da 3×size sia da 1.5×size.
    func testReclaimableSpace_excludesTheKeptCopy() {
        let b = DuplicateBatch(groups: [group([entry("Foto iPhone/a.jpg", size: 100),
                                               entry("Other/b.jpg", size: 100),
                                               entry("Other/c.jpg", size: 100)])], rule: nil, photos: .known([]))
        XCTAssertEqual(b.reclaimableBytes, 200)
        XCTAssertNotEqual(b.reclaimableBytes, 300, "conta anche la copia tenuta")
    }

    /// Dimensioni **diverse** fra i gruppi: con due gruppi da 100 un mutante che somma il
    /// primo due volte darebbe lo stesso totale.
    func testReclaimableSpace_sumsGroupsOfDifferentSizes() {
        let b = DuplicateBatch(groups: [group([entry("A/a.jpg", size: 100), entry("A/b.jpg", size: 100)], hash: "h1"),
                                        group([entry("B/a.jpg", size: 700), entry("B/b.jpg", size: 700)], hash: "h2")], rule: nil, photos: .known([]))
        XCTAssertEqual(b.reclaimableBytes, 800)
    }

    /// Gruppi di **cardinalita' diverse** (2 e 3): con due gruppi da 2 membri il conteggio
    /// dei file e quello dei gruppi coincidono, e il test sarebbe cieco.
    func testFileCount_isTheNumberOfFilesToTrash_notOfGroups() {
        let b = DuplicateBatch(groups: [group([entry("A/a.jpg"), entry("A/b.jpg")], hash: "h1"),
                                        group([entry("B/a.jpg"), entry("B/b.jpg"), entry("B/c.jpg")], hash: "h2")], rule: nil, photos: .known([]))
        XCTAssertEqual(b.fileCount, 3, "1 + 2 file da cestinare, non 2 gruppi")
        XCTAssertEqual(b.groups.count, 2)
    }

    /// La dimensione del gruppo e' la **minima** fra i membri (vedi `DuplicateGroup.size`):
    /// lo spazio recuperabile va calcolato da quella, mai dal primo membro incontrato.
    func testReclaimableSpace_usesTheGroupSize_notTheFirstMember() {
        let g = group([entry("A/grande.jpg", size: 900), entry("A/piccola.jpg", size: 100)], size: 100)
        XCTAssertEqual(DuplicateBatch(groups: [g], rule: nil, photos: .known([])).reclaimableBytes, 100)
    }

    /// `verifiedBytes` e' la grandezza da cui si stima la **rilettura** (ogni membro del
    /// gruppo, la copia tenuta compresa, ADR-0005) e non lo spazio che si libera: con 3
    /// membri da 100 byte, `reclaimableBytes` conta 200 (le due che se ne vanno) mentre
    /// `verifiedBytes` conta 300 (tutte e tre). Le due grandezze devono restare diverse
    /// per costruzione, non solo per coincidenza numerica su questa fixture.
    func testVerifiedBytes_countsEveryMemberIncludingTheKeptCopy() {
        let g = group([entry("A/a.jpg", size: 100), entry("A/b.jpg", size: 100), entry("A/c.jpg", size: 100)])
        let b = DuplicateBatch(groups: [g], rule: nil, photos: .known([]))
        XCTAssertEqual(b.verifiedBytes, 300, "tutti e tre i membri, copia tenuta compresa")
        XCTAssertEqual(b.reclaimableBytes, 200)
        XCTAssertNotEqual(b.verifiedBytes, b.reclaimableBytes)
    }

    // MARK: - Ripartizione per cartella

    /// Due gruppi che pescano dalla stessa cartella producono **una** riga con conteggio 2.
    func testFolderBreakdown_mergesGroupsThatShareAFolder() {
        let b = DuplicateBatch(groups: [group([entry("Foto iPhone/a.jpg"), entry("Other/vecchie/a.jpg")], hash: "h1"),
                                        group([entry("Foto iPhone/b.jpg"), entry("Other/vecchie/b.jpg")], hash: "h2")], rule: nil, photos: .known([]))
        XCTAssertEqual(b.folderBreakdown.count, 1)
        // Cartella di primo livello (ADR-0011), non l'intero percorso genitore: la
        // proprieta' verificata (fusione dei gruppi che condividono una cartella) e'
        // invariata, cambia solo la stringa attesa — autorizzato dalla regola 7 dei piani.
        XCTAssertEqual(b.folderBreakdown.first?.folder, "Other")
        XCTAssertEqual(b.folderBreakdown.first?.count, 2)
    }

    /// La ripartizione riguarda i file che **si spostano**, non quelli che restano: la
    /// cartella della copia tenuta non compare se da li' non si cestina niente.
    func testFolderBreakdown_countsOnlyTheCopiesThatLeave() {
        let b = DuplicateBatch(groups: [group([entry("Foto iPhone/a.jpg"), entry("Import/Scheda/a.jpg")])], rule: nil, photos: .known([]))
        // Cartella di primo livello (ADR-0011): stessa proprieta' verificata (solo le
        // cartelle che perdono file compaiono), stringa attesa aggiornata — regola 7.
        XCTAssertEqual(b.folderBreakdown.map(\.folder), ["Import"])
        XCTAssertFalse(b.folderBreakdown.contains { $0.folder == "Foto iPhone" },
                       "la cartella della copia tenuta non perde file")
    }

    /// Ordine deterministico anche fra cartelle a pari conteggio: e' la lezione del
    /// tie-break del Task 2, dove un ordine "stabile abbastanza" non lo era.
    func testFolderBreakdown_isDeterministicOnTies() {
        let members = [entry("Foto iPhone/a.jpg"), entry("Zeta/a.jpg"), entry("Alfa/a.jpg")]
        let first = DuplicateBatch(groups: [group(members)], rule: nil, photos: .known([])).folderBreakdown.map(\.folder)
        let second = DuplicateBatch(groups: [group(members.reversed())], rule: nil, photos: .known([])).folderBreakdown.map(\.folder)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ["Alfa", "Zeta"], "a pari conteggio decide il nome, in ordine")
    }

    /// Cartella di **primo livello**, non l'intero percorso genitore (ADR-0011): con le
    /// copie in eccesso sparse su migliaia di `ASUS/foto/recup_dir.NN`, la cartella
    /// genitrice completa produrrebbe migliaia di righe nel riepilogo.
    func testFolderBreakdown_isByTopLevelFolder() {
        let b = DuplicateBatch(groups: [group([entry("Foto iPhone/a.jpg"),
                                               entry("ASUS/foto/recup_dir.37/a.jpg")], hash: "h1")], rule: nil, photos: .known([]))
        XCTAssertEqual(b.folderBreakdown.map(\.folder), ["ASUS"])
    }

    /// Quante cartelle diverse in tutto perdono file: e' l'unico modo di accorgersi in
    /// tempo, a questa scala, di aver puntato la cartella sbagliata (spec §2.7).
    func testFolderBreakdown_saysHowManyFoldersInTotal() {
        let b = DuplicateBatch(groups: [
            group([entry("Foto iPhone/a.jpg"), entry("Takeout/a.jpg")], hash: "h1"),
            group([entry("Foto iPhone/b.jpg"), entry("Other/b.jpg")], hash: "h2")
        ], rule: nil, photos: .known([]))
        XCTAssertEqual(b.folderBreakdown.count, 2, "Takeout e Other perdono file: due cartelle")
        XCTAssertTrue(b.summaryLines().contains { $0.contains("2 cartelle") },
                      b.summaryLines().joined(separator: "\n"))
    }

    // MARK: - Ordinamento

    /// Spazio recuperabile **decrescente**. La fixture mette il gruppo piccolo per primo in
    /// input: con l'ordine gia' giusto in partenza il mutante "non ordinare" sopravvive.
    func testOrder_isByReclaimableSpaceDescending() {
        let b = DuplicateBatch(groups: [group([entry("A/a.jpg", size: 10), entry("A/b.jpg", size: 10)], hash: "h1"),
                                        group([entry("B/a.jpg", size: 900), entry("B/b.jpg", size: 900)], hash: "h2")], rule: nil, photos: .known([]))
        XCTAssertEqual(b.groups.map(\.group.hash), ["h2", "h1"])
    }

    /// A parita' di spazio, decide il numero di copie, decrescente. I due gruppi hanno lo
    /// stesso spazio recuperabile (200) con cardinalita' diverse, quindi il criterio
    /// primario non puo' decidere ed e' davvero il secondo a essere misurato.
    func testOrder_breaksSpaceTiesByNumberOfCopies() {
        let due = group([entry("A/a.jpg", size: 200), entry("A/b.jpg", size: 200)], hash: "h1")
        let tre = group([entry("B/a.jpg", size: 100), entry("B/b.jpg", size: 100), entry("B/c.jpg", size: 100)], hash: "h2")
        XCTAssertEqual(DuplicateBatch(groups: [due, tre], rule: nil, photos: .known([])).groups.map(\.group.hash), ["h2", "h1"])
        XCTAssertEqual(DuplicateBatch(groups: [tre, due], rule: nil, photos: .known([])).groups.map(\.group.hash), ["h2", "h1"],
                       "l'ordine di input non deve contare")
    }

    /// Due gruppi identici su **entrambi** i criteri di prodotto (stesso spazio, stesso
    /// numero di copie): a decidere resta solo la terza chiave, e senza di quella l'ordine
    /// dipende da come sono arrivati. Un elenco che si riordina fra due aperture del
    /// pannello e' un elenco su cui l'utente rimette le spunte a caso.
    ///
    /// Misurato il 2026-08-29: senza questo test, sostituire la terza chiave con `false`
    /// lasciava tutti e 19 gli altri test verdi. E' lo stesso buco del tie-break del Task 2.
    func testOrder_isTotal_whenSpaceAndCopiesBothTie() {
        let alfa = group([entry("A/a.jpg", size: 200), entry("A/b.jpg", size: 200)], hash: "h-alfa")
        let zeta = group([entry("Z/a.jpg", size: 200), entry("Z/b.jpg", size: 200)], hash: "h-zeta")
        XCTAssertEqual(DuplicateBatch(groups: [alfa, zeta], rule: nil, photos: .known([])).groups.map(\.group.hash), ["h-alfa", "h-zeta"])
        XCTAssertEqual(DuplicateBatch(groups: [zeta, alfa], rule: nil, photos: .known([])).groups.map(\.group.hash), ["h-alfa", "h-zeta"],
                       "l'ordine di input decide: la terza chiave non sta ordinando")
    }

    // MARK: - Tetto

    /// Il confine esatto, in entrambi i versi: **alla** soglia non scatta, **oltre** si'.
    /// E' il test che uccide `>=` al posto di `>` e viceversa.
    func testCap_boundary() {
        // 501 file da cestinare: 501 gruppi da 2 membri, 1 file ciascuno.
        func batch(files: Int) -> DuplicateBatch {
            DuplicateBatch(groups: (0..<files).map {
                group([entry("A/\($0)-a.jpg", size: 1), entry("A/\($0)-b.jpg", size: 1)], hash: "h\($0)")
            }, rule: nil, photos: .known([]))
        }
        XCTAssertEqual(batch(files: duplicateBatchFileCap).fileCount, duplicateBatchFileCap)
        XCTAssertFalse(batch(files: duplicateBatchFileCap).exceedsCap, "alla soglia il tetto non scatta")
        XCTAssertTrue(batch(files: duplicateBatchFileCap + 1).exceedsCap)
    }

    /// Il tetto sui byte e' indipendente da quello sui file: **un solo** file, sopra la
    /// soglia di spazio. Con un gruppo grande e molti file entrambi i tetti scatterebbero e
    /// il test non distinguerebbe quale dei due e' stato applicato.
    func testCap_bytesTripIndependentlyOfFileCount() {
        let sopra = group([entry("A/a.jpg", size: duplicateBatchByteCap + 1),
                           entry("A/b.jpg", size: duplicateBatchByteCap + 1)])
        let alSoglia = group([entry("A/a.jpg", size: duplicateBatchByteCap),
                              entry("A/b.jpg", size: duplicateBatchByteCap)])
        XCTAssertEqual(DuplicateBatch(groups: [sopra], rule: nil, photos: .known([])).fileCount, 1)
        XCTAssertTrue(DuplicateBatch(groups: [sopra], rule: nil, photos: .known([])).exceedsCap)
        XCTAssertFalse(DuplicateBatch(groups: [alSoglia], rule: nil, photos: .known([])).exceedsCap, "alla soglia il tetto non scatta")
    }

    // MARK: - Il riepilogo

    /// Il numero che conta e' quello dei **file** che si spostano, non dei gruppi. La
    /// fixture ha 2 gruppi e 3 file: con numeri uguali il test sarebbe cieco.
    func testSummary_countsFilesNotGroups() {
        let b = DuplicateBatch(groups: [group([entry("A/a.jpg"), entry("A/b.jpg")], hash: "h1"),
                                        group([entry("B/a.jpg"), entry("B/b.jpg"), entry("B/c.jpg")], hash: "h2")], rule: nil, photos: .known([]))
        // Solo la **prima** riga, non il testo intero: la ripartizione per cartella dice
        // legittimamente "2 file" (i due che escono da B), e un `contains` sul tutto sarebbe
        // rosso col codice giusto. E' il titolo il posto dove i gruppi si spaccerebbero per
        // file.
        let titolo = b.summaryLines()[0]
        XCTAssertTrue(titolo.contains("3 file"), titolo)
        XCTAssertFalse(titolo.contains("2 file"), "sta contando i gruppi: \(titolo)")
    }

    /// Cestinare **non** libera spazio finche' il Cestino non si svuota: misurato nella
    /// spec su ExFAT esterno. Senza questa riga il riepilogo promette GB che non arrivano.
    func testSummary_saysSpaceIsFreedOnlyWhenTrashIsEmptied() {
        let b = DuplicateBatch(groups: [group([entry("A/a.jpg"), entry("A/b.jpg")])], rule: nil, photos: .known([]))
        XCTAssertTrue(b.summaryLines().contains { $0.contains("svuoti il Cestino") },
                      b.summaryLines().joined(separator: "\n"))
    }

    /// I mirror non cancellano mai: le copie su HDD e su Cubbit restano dove sono.
    func testSummary_saysMirrorsKeepTheirCopies() {
        let b = DuplicateBatch(groups: [group([entry("A/a.jpg"), entry("A/b.jpg")])], rule: nil, photos: .known([]))
        let testo = b.summaryLines().joined(separator: "\n")
        XCTAssertTrue(testo.contains("HDD"), testo)
        XCTAssertTrue(testo.contains("Cubbit"), testo)
    }

    /// Un blocco vuoto lo **dice**, invece di mostrare "0 file" e una riga sul Cestino che
    /// non serve a nessuno.
    func testSummary_emptyBatchSaysSoInsteadOfShowingZero() {
        let b = DuplicateBatch(groups: [], rule: nil, photos: .known([]))
        XCTAssertEqual(b.fileCount, 0)
        XCTAssertEqual(b.reclaimableBytes, 0)
        XCTAssertFalse(b.exceedsCap)
        let testo = b.summaryLines().joined(separator: "\n")
        XCTAssertFalse(testo.contains("0 file"), testo)
        XCTAssertFalse(testo.contains("svuoti il Cestino"), "niente da cestinare: \(testo)")
    }

    /// Il riepilogo nomina le cartelle da cui i file se ne vanno: e' l'informazione che
    /// permette di accorgersi che si sta per svuotare la cartella sbagliata.
    func testSummary_namesTheFoldersLosingFiles() {
        let b = DuplicateBatch(groups: [group([entry("Foto iPhone/a.jpg"), entry("Import/Scheda/a.jpg")])], rule: nil, photos: .known([]))
        // Cartella di primo livello (ADR-0011): la proprieta' verificata (il riepilogo
        // nomina la cartella da cui i file se ne vanno) resta la stessa — regola 7.
        XCTAssertTrue(b.summaryLines().contains { $0.contains("Import") },
                      b.summaryLines().joined(separator: "\n"))
    }

    /// Registro anti-gergo, come per `LibraryIndexStatus` e `duplicateKeepExplanation`.
    func testSummary_hasNoJargon() {
        let b = DuplicateBatch(groups: [group([entry("A/a.jpg"), entry("A/b.jpg")])], rule: nil, photos: .known([]))
        let testo = b.summaryLines().joined(separator: "\n").lowercased()
        for parola in ["hash", "indice", "sha256", "scansione", "byte"] {
            XCTAssertFalse(testo.contains(parola), "gergo «\(parola)» nel riepilogo: \(testo)")
        }
    }

    /// La copia tenuta di ogni gruppo e' **congelata** dentro il blocco al momento in cui il
    /// blocco si costruisce, ed e' quella che l'utente conferma. Ricalcolarla a valle e'
    /// esattamente il buco che il Task 4 non deve riaprire.
    func testBatch_freezesTheKeptCopyOfEachGroup() {
        let g = group([entry("Import/Scheda/a.jpg"), entry("Foto iPhone/a.jpg")])
        let b = DuplicateBatch(groups: [g], rule: nil, photos: .known([]))
        XCTAssertEqual(b.groups.first?.choice.keeper.path, normalizedIndexKey("Foto iPhone/a.jpg"))
        XCTAssertEqual(b.groups.first?.choice.keeper.path,
                       duplicateKeepChoice(g, rule: nil, photos: .known([])).keeper.path,
                       "la scelta congelata deve essere la stessa che la regola produce ora")
    }

    // MARK: - Il sottoinsieme non ricalcola (ADR-0011, init(entries:))

    /// La prova diretta: costruiamo un `Entry` con una scelta che nomina un membro
    /// **diverso** da quello che `duplicateKeepChoice` sceglierebbe oggi (la libreria
    /// principale vincerebbe su "Other"), e verifichiamo che `init(entries:)` conservi
    /// quella scelta congelata invece di ricalcolarla. Se qualcuno rimettesse un
    /// `duplicateKeepChoice` dentro `init(entries:)`, questo test lo scopre subito: senza,
    /// non dimostra niente (e' il vincolo che il piano chiede esplicitamente).
    func testInitFromEntries_doesNotRecomputeTheChoice() {
        let g = group([entry("Foto iPhone/a.jpg"), entry("Other/b.jpg")])
        let realChoice = duplicateKeepChoice(g, rule: nil, photos: .known([]))
        XCTAssertEqual(realChoice.keeper.path, normalizedIndexKey("Foto iPhone/a.jpg"),
                       "premessa del test: la libreria principale deve vincere")
        let deliberatelyWrong = g.members.first { $0.path == normalizedIndexKey("Other/b.jpg") }!
        let frozenChoice = DuplicateKeepChoice(keeper: deliberatelyWrong, reason: .oldest,
                                               tiedCandidates: 1, tiedPaths: [], keptByPhotosLibrary: [])
        let b = DuplicateBatch(entries: [DuplicateBatch.Entry(group: g, choice: frozenChoice)])
        XCTAssertEqual(b.groups.first?.choice.keeper.path, deliberatelyWrong.path,
                       "init(entries:) deve conservare la scelta congelata, mai ricalcolarla")
    }

    /// `init(entries:)` ricalcola solo i totali (ordine, conteggi, ripartizione, tetto) sul
    /// sottoinsieme ricevuto — non le scelte, gia' congelate in ogni `Entry`.
    func testInitFromEntries_recomputesOnlyTheTotals() {
        let g1 = group([entry("A/a.jpg", size: 10), entry("A/b.jpg", size: 10)], hash: "h1")
        let g2 = group([entry("B/a.jpg", size: 900), entry("B/b.jpg", size: 900)], hash: "h2")
        let e1 = DuplicateBatch.Entry(group: g1, choice: duplicateKeepChoice(g1, rule: nil, photos: .known([])))
        let e2 = DuplicateBatch.Entry(group: g2, choice: duplicateKeepChoice(g2, rule: nil, photos: .known([])))
        let b = DuplicateBatch(entries: [e1, e2])
        XCTAssertEqual(b.fileCount, 2)
        XCTAssertEqual(b.reclaimableBytes, 910)
        XCTAssertEqual(b.groups.map(\.group.hash), ["h2", "h1"],
                       "l'ordine si ricalcola anche a partire da Entry gia' congelate")
    }
}
