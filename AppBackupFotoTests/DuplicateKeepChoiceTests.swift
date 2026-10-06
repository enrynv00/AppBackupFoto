import XCTest
@testable import AppBackupFoto

/// `duplicateKeepChoice` / `duplicateKeepExplanation` — quale copia si tiene, e perche'.
///
/// Logica pura: nessun filesystem, nessun database. Il motivo fa parte del risultato
/// (decisione 3 di Enrico, spec `2026-08-27-duplicates-panel-design.md`): una spiegazione
/// ricostruita dalla UI divergerebbe dalla regola alla prima modifica di una delle due.
final class DuplicateKeepChoiceTests: XCTestCase {

    // MARK: Helper

    /// Costruisce una entry come la scrive l'indicizzatore: `path` e' la chiave
    /// normalizzata, `displayPath` il percorso come appare davvero su disco.
    private func entry(_ displayPath: String, mtime: Double = 1_700_000_000) -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(displayPath),
                          displayPath: displayPath,
                          size: 1_000,
                          mtime: mtime,
                          hash: "H",
                          hashedAt: 1_700_003_600)
    }

    private func group(_ members: [LibraryIndexEntry]) -> DuplicateGroup {
        DuplicateGroup(hash: "H", size: 1_000, members: members)
    }

    private func choice(_ members: [LibraryIndexEntry]) -> DuplicateKeepChoice {
        duplicateKeepChoice(group(members), rule: nil, photos: .known([]))
    }

    private func choice(_ members: [LibraryIndexEntry], rule: DuplicateFolderRule) -> DuplicateKeepChoice {
        duplicateKeepChoice(group(members), rule: rule, photos: .known([]))
    }

    private func rule(keepIn: String, trashIn: Set<String>) -> DuplicateFolderRule {
        DuplicateFolderRule(keepIn: normalizedIndexKey(keepIn), trashIn: Set(trashIn.map(normalizedIndexKey)))
    }

    // MARK: Regola 0 — la regola dell'utente (ADR-0011)

    // La regola precede le tre euristiche esistenti: una copia in "Takeout" vince su una in
    // "Foto iPhone", che senza regola vincerebbe sempre (regola 1).
    func testUserRule_winsOverTheMainLibrary() {
        let keeper = entry("Takeout/IMG_0001.JPG")
        let r = rule(keepIn: "Takeout", trashIn: ["Foto iPhone"])
        let c = choice([entry("Foto iPhone/IMG_0001.JPG"), keeper], rule: r)
        XCTAssertEqual(c.keeper.path, keeper.path)
        XCTAssertEqual(c.reason, .userFolderRule)
    }

    // Un gruppo che la regola non copre (qui: nessuna copia in "Takeout") produce esattamente
    // lo stesso risultato, bit per bit, di `rule: nil` — la regola 0 e' un no-op sui gruppi
    // che non copre.
    func testUserRule_changesNothingOnGroupsItDoesNotCover() {
        let members = [entry("Foto iPhone/IMG_0001.JPG"), entry("Import/Scheda/IMG_0001.JPG")]
        let withoutRule = choice(members)
        let withRule = choice(members, rule: rule(keepIn: "Takeout", trashIn: ["Other"]))
        XCTAssertEqual(withRule.keeper.path, withoutRule.keeper.path)
        XCTAssertEqual(withRule.reason, withoutRule.reason)
        XCTAssertEqual(withRule.tiedCandidates, withoutRule.tiedCandidates)
        XCTAssertEqual(withRule.tiedPaths, withoutRule.tiedPaths)
    }

    // Con due copie nella cartella da tenere, la regola 0 le isola entrambe — e fra loro
    // decide la regola 3 esistente (la piu' vecchia), non un criterio nuovo: il motivo
    // finale torna a essere quello della regola che ha davvero discriminato, non
    // `.userFolderRule`.
    func testUserRule_withSeveralCopiesInTheKeepFolder_fallsBackToTheExistingRules() {
        let older = entry("Takeout/a/IMG_0001.JPG", mtime: 1_600_000_000)
        let newer = entry("Takeout/b/IMG_0001.JPG", mtime: 1_700_000_000)
        let c = choice([older, newer, entry("Foto iPhone/IMG_0001.JPG", mtime: 1_500_000_000)],
                       rule: rule(keepIn: "Takeout", trashIn: ["Foto iPhone"]))
        XCTAssertEqual(c.keeper.path, older.path)
        XCTAssertEqual(c.reason, .oldest)
    }

    // `covers` garantisce gia' almeno un membro sotto `keepIn`: la regola 0 non deve mai
    // restringere i candidati a un insieme vuoto. Verificato osservando che il vincitore
    // resta sempre sotto `keepIn`, mai un crash o un fallback silenzioso a un'altra cartella.
    func testUserRule_neverEmptiesTheCandidates() {
        let keeper = entry("Other/IMG_0001.JPG")
        let r = rule(keepIn: "Other", trashIn: ["Takeout"])
        let c = choice([keeper, entry("Takeout/IMG_0001.JPG")], rule: r)
        XCTAssertEqual(c.reason, .userFolderRule)
        XCTAssertEqual(c.keeper.path.split(separator: "/").first.map(String.init), r.keepIn)
    }

    // La copia tenuta non e' mai una di quelle che la regola cestina: se un mutante narrows
    // erroneamente sui membri di `trashIn` invece che su quelli di `keepIn`, questo test lo
    // scopre confrontando i percorsi, non solo il conteggio.
    func testKeeperIsNeverAmongTheLeavingCopies() {
        let trashed1 = entry("Takeout/a/IMG_0001.JPG")
        let trashed2 = entry("Takeout 2/b/IMG_0001.JPG")
        let r = rule(keepIn: "Foto iPhone", trashIn: ["Takeout", "Takeout 2"])
        let c = choice([entry("Foto iPhone/IMG_0001.JPG"), trashed1, trashed2], rule: r)
        XCTAssertNotEqual(c.keeper.path, trashed1.path)
        XCTAssertNotEqual(c.keeper.path, trashed2.path)
    }

    // La spiegazione deve dire che la scelta viene dalla regola dell'utente, non da
    // un'euristica dell'app — altrimenti l'utente legge una motivazione che non è la vera
    // ragione per cui quella copia resta.
    func testExplanation_namesTheUserRule() {
        let keeper = entry("Takeout/IMG_0001.JPG")
        let g = group([entry("Foto iPhone/IMG_0001.JPG"), keeper])
        let c = duplicateKeepChoice(g, rule: rule(keepIn: "Takeout", trashIn: ["Foto iPhone"]), photos: .known([]))
        let text = duplicateKeepExplanation(c, in: g)
        XCTAssertTrue(text.contains("hai chiesto di tenere le copie che stanno lì"), text)
        XCTAssertTrue(text.contains("«Takeout»"), text)
    }

    // Stesso registro anti-gergo di `testExplanation_avoidsJargon`, sul ramo nuovo: quel
    // test itera `explanationsByReason()`, che non passa mai una regola e quindi non
    // eserciterebbe mai `.userFolderRule`.
    func testExplanation_hasNoJargon() {
        let keeper = entry("Takeout/IMG_0001.JPG")
        let g = group([entry("Foto iPhone/IMG_0001.JPG"), keeper])
        let c = duplicateKeepChoice(g, rule: rule(keepIn: "Takeout", trashIn: ["Foto iPhone"]), photos: .known([]))
        let text = duplicateKeepExplanation(c, in: g).lowercased()
        for word in ["hash", "indice", "sha256", "scansione", "entry", "registro", "cache"] {
            XCTAssertFalse(text.contains(word), "la spiegazione dice «\(word)»: \(text)")
        }
    }

    // MARK: Regola 1 — la libreria principale vince

    // Il caso che uccide l'inversione di precedenza fra le prime due regole.
    // `testMainLibraryBeatsOrganizedFolder` da solo NON la ucciderebbe: con due membri
    // entrambi fuori da `Import/` la regola 2 non discrimina, quindi invertire l'ordine
    // lascerebbe identici sia la copia tenuta sia il motivo. Qui invece l'ordine invertito
    // farebbe scegliere lo stesso file ma con motivo `.notAnImport`, cioe' direbbe
    // all'utente una frase sbagliata su una schermata che precede una cancellazione.
    func testMainLibraryBeatsImportFolder() {
        let keeper = entry("Foto iPhone/2020/IMG_0001.JPG")
        let c = choice([entry("Import/Scheda/IMG_0001.JPG"), keeper])
        XCTAssertEqual(c.keeper.path, keeper.path)
        XCTAssertEqual(c.reason, .mainLibrary)
    }

    func testMainLibraryBeatsOrganizedFolder() {
        let keeper = entry("Foto iPhone/2020/IMG_0001.JPG")
        let c = choice([entry("2019 Vacanze/IMG_0001.JPG"), keeper])
        XCTAssertEqual(c.keeper.path, keeper.path)
        XCTAssertEqual(c.reason, .mainLibrary)
    }

    // Se la prima regola non discrimina (tutte le copie in libreria principale) si scende
    // alla successiva: qui la piu' vecchia fra le due, non una delle due a caso.
    func testTwoInMainLibrary_fallThroughToTheNextRule() {
        let older = entry("Foto iPhone/2019/IMG_0001.JPG", mtime: 1_600_000_000)
        let c = choice([entry("Foto iPhone/2020/IMG_0001.JPG", mtime: 1_700_000_000),
                        older,
                        entry("Import/Scheda/IMG_0001.JPG", mtime: 1_500_000_000)])
        XCTAssertEqual(c.keeper.path, older.path)
        XCTAssertEqual(c.reason, .oldest)
    }

    // MARK: Regola 2 — una cartella organizzata batte un import

    func testOrganizedFolderBeatsImport() {
        let keeper = entry("2019 Vacanze/IMG_0001.JPG")
        let c = choice([entry("Import/Scheda/IMG_0001.JPG"), keeper])
        XCTAssertEqual(c.keeper.path, keeper.path)
        XCTAssertEqual(c.reason, .notAnImport)
    }

    func testTwoImports_keepTheOldest() {
        let older = entry("Import/Scheda/IMG_0001.JPG", mtime: 1_600_000_000)
        let c = choice([entry("Import/Reflex/IMG_0001.JPG", mtime: 1_700_000_000), older])
        XCTAssertEqual(c.keeper.path, older.path)
        XCTAssertEqual(c.reason, .oldest)
    }

    // MARK: Regola 3 — a parita', la piu' vecchia

    func testSameFolder_keepsOldest() {
        let older = entry("2019 Vacanze/IMG_0001.JPG", mtime: 1_500_000_000)
        let c = choice([entry("2019 Vacanze/copia/IMG_0001.JPG", mtime: 1_700_000_000),
                        older])
        XCTAssertEqual(c.keeper.path, older.path)
        XCTAssertEqual(c.reason, .oldest)
    }

    // MARK: Regola 4 — tie-break deterministico

    // La proposta non deve cambiare fra due aperture del pannello a parita' di dati:
    // una proposta instabile e' una proposta di cui non ci si puo' fidare. Se il tie-break
    // sparisse e restasse "il primo membro", questo test diventerebbe rosso su almeno
    // quattro delle sei permutazioni.
    func testTieBreak_isStableAcrossPermutations() {
        let a = entry("Other/a/IMG_0001.JPG")
        let b = entry("Other/bb/IMG_0001.JPG")
        let c = entry("Other/ccc/IMG_0001.JPG")
        let permutations = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
        for members in permutations {
            let result = duplicateKeepChoice(group(members), rule: nil, photos: .known([]))
            XCTAssertEqual(result.keeper.path, a.path,
                           "ordine di input \(members.map(\.displayPath))")
            XCTAssertEqual(result.reason, .deterministicTieBreak)
        }
    }

    // I due percorsi sono scelti perche' lunghezza e ordine alfabetico si **contraddicono**:
    // "other/zz.jpg" e' il piu' corto ma viene DOPO "other/aaa/bbb/img_0001.jpg" in ordine
    // alfabetico. Con una coppia in cui i due criteri concordano il test sarebbe cieco —
    // misurato il 2026-08-28: cancellando il confronto sulla lunghezza restavano 31 test
    // verdi, e a cambiare era quale foto sopravvive.
    func testTieBreak_prefersTheShortestPath() {
        let short = entry("Other/zz.jpg")
        let c = choice([entry("Other/aaa/bbb/IMG_0001.JPG"), short])
        XCTAssertEqual(c.keeper.path, short.path)
        XCTAssertEqual(c.reason, .deterministicTieBreak)
    }

    func testTieBreak_usesKeyOrderWhenLengthsAreEqual() {
        let first = entry("Other/AAA/IMG_0001.JPG")
        let c = choice([entry("Other/BBB/IMG_0001.JPG"), first])
        XCTAssertEqual(c.keeper.path, first.path)
        XCTAssertEqual(c.reason, .deterministicTieBreak)
    }

    // MARK: Precedenza fra le tre regole

    // Tre membri, tre regole in conflitto: la libreria principale vince anche se la sua
    // copia e' la piu' recente e anche se le altre due non stanno in un import.
    func testThreeMembersWithMixedRules_mainLibraryWinsOverAll() {
        let keeper = entry("Foto iPhone/2021/IMG_0001.JPG", mtime: 1_700_000_000)
        let c = choice([entry("2019 Vacanze/IMG_0001.JPG", mtime: 1_400_000_000),
                        entry("Import/Scheda/IMG_0001.JPG", mtime: 1_300_000_000),
                        keeper])
        XCTAssertEqual(c.keeper.path, keeper.path)
        XCTAssertEqual(c.reason, .mainLibrary)
    }

    // MARK: Confronto per componente, mai per prefisso testuale

    func testFotografieIPhone_isNotTheMainLibrary() {
        let keeper = entry("Foto iPhone/IMG_0001.JPG")
        let c = choice([entry("Fotografie iPhone/IMG_0001.JPG"), keeper])
        XCTAssertEqual(c.keeper.path, keeper.path)
        XCTAssertEqual(c.reason, .mainLibrary)
    }

    // Il caso che uccide davvero `hasPrefix`: "foto iphone 2/" HA come prefisso testuale
    // "foto iphone", ma non e' la stessa cartella. E' lo stesso schema gia' usato altrove
    // nel progetto (`/Volumes/SSD` non e' un prefisso di `/Volumes/SSD 2`).
    func testFotoIPhone2_isNotTheMainLibrary() {
        let keeper = entry("Foto iPhone/IMG_0001.JPG")
        let c = choice([entry("Foto iPhone 2/IMG_0001.JPG"), keeper])
        XCTAssertEqual(c.keeper.path, keeper.path)
        XCTAssertEqual(c.reason, .mainLibrary)
    }

    // Stessa trappola sull'altra regola: "Importante/" non e' "Import/".
    func testImportante_isNotAnImportFolder() {
        let a = entry("Importante/IMG_0001.JPG", mtime: 1_700_000_000)
        let b = entry("Other/IMG_0001.JPG", mtime: 1_600_000_000)
        let c = choice([a, b])
        // Nessuna delle due e' un import: decide la data, non la regola 2.
        XCTAssertEqual(c.keeper.path, b.path)
        XCTAssertEqual(c.reason, .oldest)
    }

    // Un file NELLA root non ha una cartella di primo livello: la sua prima componente
    // e' il nome del file. Un file chiamato "Foto iPhone" non e' la libreria principale.
    func testFileAtTheRootIsNotAFolder() {
        let a = entry("Foto iPhone", mtime: 1_700_000_000)
        let b = entry("Other/IMG_0001.JPG", mtime: 1_600_000_000)
        let c = choice([a, b])
        XCTAssertEqual(c.keeper.path, b.path)
        XCTAssertEqual(c.reason, .oldest)
    }

    // MARK: Chiave normalizzata, non `displayPath`

    // NOTA onesta: "Foto iPhone" non contiene caratteri decomponibili, quindi la sua forma
    // NFD coincide con la NFC e non c'e' modo di distinguerle. Cio' che questo test prova
    // davvero e' il case-folding e il fatto che il confronto passa da `normalizedIndexKey`,
    // quindi regge anche se un chiamante futuro costruisse un gruppo da percorsi grezzi.
    func testMainLibraryFolder_isRecognizedWhateverTheCase() {
        let keeper = LibraryIndexEntry(path: "FOTO IPHONE/IMG_0001.JPG".precomposedStringWithCanonicalMapping,
                                       displayPath: "FOTO IPHONE/IMG_0001.JPG",
                                       size: 1_000, mtime: 1_700_000_000,
                                       hash: "H", hashedAt: 1_700_003_600)
        let c = choice([entry("Import/Scheda/IMG_0001.JPG"), keeper])
        XCTAssertEqual(c.keeper.displayPath, keeper.displayPath)
        XCTAssertEqual(c.reason, .mainLibrary)
    }

    // Prova diretta che la regola guarda la chiave e non il percorso di visualizzazione:
    // entry patologica in cui i due dicono cose opposte. Se il confronto passasse da
    // `displayPath`, questa copia risulterebbe un import e il motivo sarebbe un altro.
    func testComparisonUsesTheNormalizedKeyNotTheDisplayPath() {
        let keeper = LibraryIndexEntry(path: "foto iphone/img_0001.jpg",
                                       displayPath: "Import/Scheda/IMG_0001.JPG",
                                       size: 1_000, mtime: 1_700_000_000,
                                       hash: "H", hashedAt: 1_700_003_600)
        let c = choice([entry("2019 Vacanze/IMG_0001.JPG"), keeper])
        XCTAssertEqual(c.keeper.path, keeper.path)
        XCTAssertEqual(c.reason, .mainLibrary)
    }

    // MARK: Quante copie restano equivalenti alla fine

    // `tiedCandidates` e' cio' che permette alla frase di non presentare come motivata una
    // scelta fatta a pari merito. Un gruppo a un solo membro non si prova qui: viola la
    // precondition di `duplicateKeepChoice` (`DuplicateGroup` ha sempre almeno due membri)
    // e una precondition non e' verificabile da XCTest senza far morire il processo.
    func testTiedCandidates_isOneWhenARuleDecidedAlone() {
        let c = choice([entry("Foto iPhone/IMG_0001.JPG"), entry("Import/Scheda/IMG_0001.JPG")])
        XCTAssertEqual(c.reason, .mainLibrary)
        XCTAssertEqual(c.tiedCandidates, 1)
    }

    func testTiedCandidates_countsTheCopiesLeftAtParity() {
        // Due copie in libreria principale piu' una fuori, tutte con la stessa data: la
        // prima regola scarta la terza ma ne lascia due, e fra quelle decide il tie-break.
        let c = choice([entry("Foto iPhone/a/IMG_0001.JPG"),
                        entry("Foto iPhone/b/IMG_0001.JPG"),
                        entry("Other/IMG_0001.JPG")])
        XCTAssertEqual(c.reason, .mainLibrary)
        XCTAssertEqual(c.tiedCandidates, 2)
    }

    // MARK: La spiegazione

    private func explanation(_ members: [LibraryIndexEntry]) -> String {
        let g = group(members)
        return duplicateKeepExplanation(duplicateKeepChoice(g, rule: nil, photos: .known([])), in: g)
    }

    func testExplanation_namesTheRealFolderOfTheKeptFile() {
        let text = explanation([entry("Foto iPhone/2020 Estate/IMG_0001.JPG"),
                                entry("Import/Scheda/IMG_0001.JPG")])
        XCTAssertTrue(text.contains("Foto iPhone/2020 Estate"),
                      "la spiegazione deve nominare la cartella vera: \(text)")
        // La cartella va detta come e' scritta su disco, non nella forma minuscola della
        // chiave: l'utente la deve ritrovare nel Finder.
        XCTAssertFalse(text.contains("foto iphone/2020 estate"), text)
    }

    func testExplanation_namesTheNumberOfOtherCopies() {
        let three = explanation([entry("Foto iPhone/IMG_0001.JPG"),
                                 entry("Import/Scheda/IMG_0001.JPG"),
                                 entry("Import/Reflex/IMG_0001.JPG")])
        XCTAssertTrue(three.contains("Ci sono 2 altre copie"), "due altre copie non sono nominate: \(three)")

        // Il ramo singolare va preteso per intero: un `contains("1")` sarebbe vero anche in
        // «Ci sono 1 altre copie», cioe' nella frase sgrammaticata che l'utente leggerebbe
        // se il ramo cadesse nel `default`. Ed e' il caso piu' frequente del pannello.
        let two = explanation([entry("Foto iPhone/IMG_0001.JPG"),
                               entry("Import/Scheda/IMG_0001.JPG")])
        XCTAssertTrue(two.contains("C'è 1 altra copia"), "l'altra copia non e' nominata: \(two)")
        XCTAssertFalse(two.contains("Ci sono 1"), two)
    }

    /// Una spiegazione per ciascuno dei quattro motivi, costruita dal caso che lo produce.
    private func explanationsByReason() -> [DuplicateKeepReason: String] {
        let cases: [[LibraryIndexEntry]] = [
            [entry("Foto iPhone/IMG_0001.JPG"), entry("Import/Scheda/IMG_0001.JPG")],
            [entry("2019 Vacanze/IMG_0001.JPG"), entry("Import/Scheda/IMG_0001.JPG")],
            [entry("2019 Vacanze/IMG_0001.JPG", mtime: 1_500_000_000),
             entry("2019 Vacanze/copia/IMG_0001.JPG", mtime: 1_700_000_000)],
            [entry("Other/a/IMG_0001.JPG"), entry("Other/bb/IMG_0001.JPG")]
        ]
        var out: [DuplicateKeepReason: String] = [:]
        for members in cases {
            let g = group(members)
            let c = duplicateKeepChoice(g, rule: nil, photos: .known([]))
            out[c.reason] = duplicateKeepExplanation(c, in: g)
        }
        return out
    }

    func testExplanation_coversAllFourReasons() {
        let texts = explanationsByReason()
        XCTAssertEqual(Set(texts.keys),
                       Set([.mainLibrary, .notAnImport, .oldest, .deterministicTieBreak]),
                       "i quattro casi non producono i quattro motivi attesi")
    }

    // Non basta che le quattro stringhe siano diverse: differirebbero anche se cambiasse
    // solo il nome della cartella, e il test sarebbe cieco proprio sul pezzo che spiega
    // il perche'. Ogni motivo deve avere una frase sua, e non deve contenere quella
    // degli altri tre.
    func testExplanation_isDifferentForEachReason() {
        let texts = explanationsByReason()
        let marker: [DuplicateKeepReason: String] = [
            .mainLibrary: "libreria principale",
            .notAnImport: "cartella di scarico",
            .oldest: "data più vecchia",
            .deterministicTieBreak: "si equivalgono"
        ]
        for (reason, text) in texts {
            guard let own = marker[reason] else {
                XCTFail("motivo senza frase attesa: \(reason)")
                continue
            }
            XCTAssertTrue(text.contains(own), "\(reason): manca «\(own)» in «\(text)»")
            for (other, phrase) in marker where other != reason {
                XCTAssertFalse(text.contains(phrase),
                               "\(reason) usa la frase di \(other): «\(text)»")
            }
        }
        XCTAssertEqual(Set(texts.values).count, 4, "due motivi producono la stessa frase")
    }

    // Registro anti-gergo, come gia' per `LibraryIndexStatus`: l'utente non deve incontrare
    // il vocabolario interno dell'app in una schermata che precede una cancellazione.
    func testExplanation_avoidsJargon() {
        for (reason, text) in explanationsByReason() {
            let lower = text.lowercased()
            for word in ["hash", "indice", "sha256", "scansione", "entry"] {
                XCTAssertFalse(lower.contains(word), "\(reason) dice «\(word)»: \(text)")
            }
        }
    }

    // MARK: Le affermazioni della frase devono essere vere del gruppo INTERO

    // Trovato dall'audit del 2026-08-28. La regola 3 confronta le date fra i **candidati
    // rimasti**, non fra tutti i membri: qui la copia piu' vecchia del gruppo sta in
    // `Import/` ed e' una di quelle che finirebbero nel Cestino. Dire "è la più vecchia"
    // sarebbe una frase contraddetta dalla riga sotto, nella schermata che precede la
    // cancellazione.
    func testExplanation_oldest_doesNotClaimToBeTheOldestOfTheWholeGroup() {
        let text = explanation([entry("Foto iPhone/2023/IMG_0001.JPG", mtime: 1_700_000_500),
                                entry("Foto iPhone/vecchie/IMG_0001.JPG", mtime: 1_700_000_900),
                                entry("Import/Scheda SD/IMG_0001.JPG", mtime: 1_700_000_000)])
        XCTAssertTrue(text.contains("Foto iPhone/2023"), text)
        XCTAssertFalse(text.contains("nessun'altra copia è più vecchia"), text)
        XCTAssertTrue(text.contains("Una copia più vecchia c'è"), text)
    }

    func testExplanation_oldest_claimsTheWholeGroupOnlyWhenNothingIsOlder() {
        let text = explanation([entry("2019 Vacanze/IMG_0001.JPG", mtime: 1_500_000_000),
                                entry("2019 Vacanze/copia/IMG_0001.JPG", mtime: 1_700_000_000)])
        XCTAssertTrue(text.contains("nessun'altra copia è più vecchia"), text)
        XCTAssertFalse(text.contains("Una copia più vecchia c'è"), text)
    }

    // Il confine di `nothingIsOlder`: due copie con la **stessa** data minima. "Nessun'altra
    // copia e' piu' vecchia di questa" resta vero, e la variante debole direbbe che una copia
    // piu' vecchia esiste — falso. Con `>` al posto di `>=` questo test diventa rosso, ed e'
    // il solo che lo guarda: altrove le date sono sempre distinte, mentre la parita' fra
    // doppioni e' la norma (`cp -p`, `rsync -t` e il restore da Finder preservano l'mtime).
    func testExplanation_oldest_keepsTheStrongClaimWhenTheOldestDateIsATie() {
        let members = [entry("Foto iPhone/a/IMG_0001.JPG", mtime: 1_700_000_100),
                       entry("Foto iPhone/b/IMG_0001.JPG", mtime: 1_700_000_100),
                       entry("Foto iPhone/c/IMG_0001.JPG", mtime: 1_700_000_200)]
        let c = duplicateKeepChoice(group(members), rule: nil, photos: .known([]))
        XCTAssertEqual(c.reason, .oldest)
        XCTAssertEqual(c.tiedCandidates, 2)
        let text = duplicateKeepExplanation(c, in: group(members))
        XCTAssertTrue(text.contains("nessun'altra copia è più vecchia"), text)
        XCTAssertFalse(text.contains("Una copia più vecchia c'è"), text)
    }

    // Stessa classe di errore sulla regola 2: mtime identici sono la norma fra doppioni
    // (`cp -p`, `rsync -t` e il restore da Finder preservano l'mtime, misurato nella spec),
    // quindi la regola 3 spesso non discrimina e restano in gara copie che import non sono.
    func testExplanation_notAnImport_doesNotClaimAllOtherCopiesAreImports() {
        let text = explanation([entry("Other/IMG_0001.JPG"),
                                entry("Takeout 2/Google Foto/IMG_0001.JPG"),
                                entry("Import/Scheda SD/IMG_0001.JPG")])
        XCTAssertTrue(text.contains("almeno un'altra copia sta in una cartella di scarico"), text)
        XCTAssertFalse(text.contains("tutte le altre copie stanno in una cartella di scarico"), text)
    }

    // La copia tenuta e' messa **per ultima** apposta: le "altre copie" vanno ricavate dal
    // gruppo per differenza dalla tenuta, non prendendo i membri dal secondo in poi. Con la
    // tenuta in prima posizione le due formule coincidono e il test sarebbe cieco — misurato
    // il 2026-08-28: un mutante che scriveva `dropFirst()` sopravviveva a tutti gli altri 30
    // test. E' anche il solo legame fra i due argomenti di `duplicateKeepExplanation`.
    func testExplanation_notAnImport_claimsAllOthersOnlyWhenTheyReallyAreImports() {
        let text = explanation([entry("Import/Scheda/IMG_0001.JPG"),
                                entry("Import/Reflex/IMG_0001.JPG"),
                                entry("2019 Vacanze/IMG_0001.JPG")])
        XCTAssertTrue(text.contains("«2019 Vacanze»"), text)
        XCTAssertTrue(text.contains("tutte le altre copie stanno in una cartella di scarico"), text)
    }

    // A lunghezze pari decide l'ordine alfabetico, non la lunghezza — ed e' il caso piu'
    // comune di tutti, perche' due scatti consecutivi nella stessa cartella hanno sempre
    // nomi della stessa lunghezza. La frase non deve attribuire la scelta a una proprieta'
    // che quel gruppo non ha.
    func testExplanation_tieBreak_doesNotClaimTheShortestPath() {
        let text = explanation([entry("Takeout/IMG_0001.JPG"), entry("Takeout/IMG_0002.JPG")])
        XCTAssertFalse(text.contains("percorso più corto"), text)
        XCTAssertTrue(text.contains("a parità scelgo sempre la stessa"), text)
    }

    // Motivo vero ma insufficiente: fra le due copie in libreria principale — di cui una va
    // nel Cestino — ha deciso il tie-break, e la frase deve dirlo invece di far credere che
    // ci sia una ragione sostanziale.
    func testExplanation_saysWhenTheFinalPickWasArbitrary() {
        let text = explanation([entry("Foto iPhone/a/IMG_0001.JPG"),
                                entry("Foto iPhone/b/IMG_0001.JPG"),
                                entry("Other/IMG_0001.JPG")])
        XCTAssertTrue(text.contains("libreria principale"), text)
        XCTAssertTrue(text.contains("va bene quanto questa"), text)
    }

    // Livello 1 di fiducia (ADR-0002/0003): i numeri vengono dall'elenco, non dal disco.
    // La frase lo deve dire — la verita' la stabilisce la rilettura al momento della
    // cancellazione, non questa riga.
    func testExplanation_doesNotPresentTheCountAsAVerifiedFact() {
        let text = explanation([entry("Foto iPhone/IMG_0001.JPG"),
                                entry("Import/Scheda/IMG_0001.JPG"),
                                entry("Import/Reflex/IMG_0001.JPG")])
        XCTAssertTrue(text.contains("risultano identiche"), text)
        XCTAssertTrue(text.contains("in base all'ultimo controllo"), text)
    }

    // Un file nella root non ha una cartella da nominare: la spiegazione deve dirlo
    // comunque, senza produrre virgolette vuote.
    func testExplanation_handlesAFileAtTheRoot() {
        let text = explanation([entry("IMG_0001.JPG", mtime: 1_500_000_000),
                                entry("Other/IMG_0001.JPG", mtime: 1_700_000_000)])
        XCTAssertFalse(text.contains("«»"), text)
        XCTAssertTrue(text.contains("direttamente sull'SSD, fuori da ogni cartella"), text)
    }
}
