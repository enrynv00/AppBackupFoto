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
        duplicateKeepChoice(group(members))
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
            let result = duplicateKeepChoice(group(members))
            XCTAssertEqual(result.keeper.path, a.path,
                           "ordine di input \(members.map(\.displayPath))")
            XCTAssertEqual(result.reason, .deterministicTieBreak)
        }
    }

    func testTieBreak_prefersTheShortestPath() {
        let short = entry("Other/IMG_0001.JPG")
        let c = choice([entry("Other/sottocartella/lunga/IMG_0001.JPG"), short])
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

    // MARK: Casi limite

    func testSingleMemberGroup_keepsThatMember() {
        let only = entry("Other/IMG_0001.JPG")
        let c = choice([only])
        XCTAssertEqual(c.keeper.path, only.path)
        XCTAssertEqual(c.reason, .deterministicTieBreak)
    }

    // MARK: La spiegazione

    private func explanation(_ members: [LibraryIndexEntry]) -> String {
        let g = group(members)
        return duplicateKeepExplanation(duplicateKeepChoice(g), in: g)
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
        XCTAssertTrue(three.contains("2"), "due altre copie non sono nominate: \(three)")

        let two = explanation([entry("Foto iPhone/IMG_0001.JPG"),
                               entry("Import/Scheda/IMG_0001.JPG")])
        XCTAssertTrue(two.contains("1"), "l'altra copia non e' nominata: \(two)")
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
            let c = duplicateKeepChoice(g)
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
            .oldest: "la più vecchia",
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

    // Un file nella root non ha una cartella da nominare: la spiegazione deve dirlo
    // comunque, senza produrre virgolette vuote.
    func testExplanation_handlesAFileAtTheRoot() {
        let text = explanation([entry("IMG_0001.JPG", mtime: 1_500_000_000),
                                entry("Other/IMG_0001.JPG", mtime: 1_700_000_000)])
        XCTAssertFalse(text.contains("«»"), text)
        XCTAssertTrue(text.contains("SSD"), text)
    }
}
