import XCTest
@testable import AppBackupFoto

/// `ImportPreviewStatus` e' la sola parte del wizard di anteprima import che e' logica pura
/// (Task 3 del piano `2026-09-01-import-preview-dedup.md`): le righe che il passo `.preview`
/// mostra, il motivo per cui l'anteprima non puo' nemmeno partire, e la riga di avanzamento.
/// Stesso ruolo di `LibraryIndexStatus.lines` e di `DuplicatesStatus`: nessuna stringa scritta
/// nella View, tutte qui.
final class ImportPreviewStatusTests: XCTestCase {

    // MARK: - Perche' l'anteprima non puo' nemmeno partire

    /// SSD non configurato: motivo scritto, e va DISTINTO da "non collegato" — sono due azioni
    /// diverse per l'utente (configurare vs collegare fisicamente il volume).
    func testSSDNotConfigured_explainsAndDiffersFromNotMounted() {
        let notConfigured = ImportPreviewStatus.unavailableReason(ssdConfigured: false, ssdMounted: false)
        let notMounted = ImportPreviewStatus.unavailableReason(ssdConfigured: true, ssdMounted: false)
        XCTAssertNotNil(notConfigured)
        XCTAssertNotNil(notMounted)
        XCTAssertNotEqual(notConfigured, notMounted, "i due motivi non devono essere la stessa frase")
    }

    /// SSD configurato ma non collegato in questo momento: il motivo deve nominare il
    /// collegamento (l'azione che l'utente deve fare), non un generico "non disponibile".
    func testSSDConfiguredButNotMounted_namesConnecting() {
        let reason = ImportPreviewStatus.unavailableReason(ssdConfigured: true, ssdMounted: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("SSD"))
        XCTAssertTrue(reason!.lowercased().contains("collega"),
                      "deve dire di collegare l'SSD, non solo che non e' disponibile")
    }

    /// SSD configurato e collegato: nessun motivo, l'anteprima puo' partire.
    func testSSDConfiguredAndMounted_noReason() {
        XCTAssertNil(ImportPreviewStatus.unavailableReason(ssdConfigured: true, ssdMounted: true))
    }

    // MARK: - Le righe del passo .preview

    /// Nessun doppione: la riga "Già presenti sull'SSD" non deve comparire affatto — non a
    /// zero, proprio assente.
    func testNoDuplicates_thenAlreadyPresentLineIsAbsent() {
        let lines = ImportPreviewStatus.lines(toAdd: 10, toSkipDuplicates: 0, toAddBytes: 1_000_000, estimatedSec: 5, interrupted: false)
        XCTAssertFalse(lines.contains { $0.id == "already-present" })
        for line in lines {
            XCTAssertFalse(line.text.lowercased().contains("già presenti"))
            XCTAssertFalse(line.text.lowercased().contains("già presente"))
        }
    }

    /// Doppioni presenti: la riga compare, col numero.
    func testDuplicatesPresent_lineAppearsWithCount() {
        let lines = ImportPreviewStatus.lines(toAdd: 10, toSkipDuplicates: 3, toAddBytes: 1_000_000, estimatedSec: 5, interrupted: false)
        guard let already = lines.first(where: { $0.id == "already-present" }) else {
            return XCTFail("manca la riga 'già presenti'")
        }
        XCTAssertTrue(already.text.contains("3"))
    }

    /// Plurale della riga "già presenti": 1 file concordato al singolare, 2 al plurale.
    /// Stessa disciplina di LibraryIndexStatus (2026-09-01).
    func testAlreadyPresentLine_pluralAgreement() {
        let one = ImportPreviewStatus.lines(toAdd: 10, toSkipDuplicates: 1, toAddBytes: 1, estimatedSec: 1, interrupted: false)
            .first { $0.id == "already-present" }!.text
        let two = ImportPreviewStatus.lines(toAdd: 10, toSkipDuplicates: 2, toAddBytes: 1, estimatedSec: 1, interrupted: false)
            .first { $0.id == "already-present" }!.text
        XCTAssertTrue(one.contains("1 file"))
        XCTAssertFalse(one.lowercased().contains("verranno"), "singolare: non deve usare il verbo plurale")
        XCTAssertFalse(one.lowercased().contains("presenti"), "singolare: non deve usare l'aggettivo plurale")
        XCTAssertTrue(two.contains("2 file"))
        XCTAssertFalse(two.lowercased().contains("verrà "), "plurale: non deve usare il verbo singolare")
    }

    /// Plurale della riga principale (quella con `toAdd`): stessa disciplina. Verifica
    /// direttamente le forme concordate, non un confronto testuale indiretto — un confronto
    /// per sola sostituzione di cifre passerebbe anche con un plurale sempre uguale, se il
    /// resto della riga (byte/tempo) introduce cifre proprie che confondono il paragone.
    func testToAddLine_pluralAgreement() {
        let one = ImportPreviewStatus.lines(toAdd: 1, toSkipDuplicates: 0, toAddBytes: 1, estimatedSec: 1, interrupted: false)
            .first { $0.id == "toAdd" }!.text
        let two = ImportPreviewStatus.lines(toAdd: 2, toSkipDuplicates: 0, toAddBytes: 1, estimatedSec: 1, interrupted: false)
            .first { $0.id == "toAdd" }!.text
        XCTAssertTrue(one.contains("1 file nuovo "), "singolare atteso: «\(one)»")
        XCTAssertFalse(one.contains("nuovi"), "singolare: non deve usare la forma plurale: «\(one)»")
        XCTAssertTrue(two.contains("2 file nuovi "), "plurale atteso: «\(two)»")
        XCTAssertFalse(two.contains("file nuovo "), "plurale: non deve usare la forma singolare: «\(two)»")
    }

    /// `toAdd == 0` ma `toSkipDuplicates > 0`: e' lo scenario del reimport, la ragione stessa
    /// per cui esiste questo lavoro. La coppia di righe deve leggersi come "non c'e' niente di
    /// nuovo da importare", mai come un silenzio o un errore.
    func testNothingNewToImport_readsAsGoodNewsNotSilenceOrError() {
        let lines = ImportPreviewStatus.lines(toAdd: 0, toSkipDuplicates: 12, toAddBytes: 0, estimatedSec: 0, interrupted: false)
        XCTAssertFalse(lines.isEmpty, "mai un silenzio")
        guard let toAdd = lines.first(where: { $0.id == "toAdd" }) else {
            return XCTFail("manca la riga principale anche a toAdd == 0")
        }
        XCTAssertNotEqual(toAdd.tone, .warning, "non deve leggersi come un errore")
        XCTAssertTrue(
            toAdd.text.lowercased().contains("nessuna") || toAdd.text.lowercased().contains("niente di nuovo")
                || toAdd.text.lowercased().contains("già tutte"),
            "deve dire esplicitamente che non c'e' niente di nuovo: «\(toAdd.text)»"
        )
        guard let already = lines.first(where: { $0.id == "already-present" }) else {
            return XCTFail("manca la riga sui doppioni, che e' meta' del racconto")
        }
        XCTAssertTrue(already.text.contains("12"))
    }

    /// `toAdd == 0` E `toSkipDuplicates == 0`: sorgente vuota. Situazione OPPOSTA alla
    /// precedente — "non ho trovato foto" contro "le hai gia' tutte" — e deve produrre una
    /// riga diversa. Stessa classe di errore gia' corretta con `sawNothing` in #31.
    func testEmptySource_differsFromNothingNewToImport() {
        let empty = ImportPreviewStatus.lines(toAdd: 0, toSkipDuplicates: 0, toAddBytes: 0, estimatedSec: 0, interrupted: false)
        let nothingNew = ImportPreviewStatus.lines(toAdd: 0, toSkipDuplicates: 12, toAddBytes: 0, estimatedSec: 0, interrupted: false)

        XCTAssertFalse(empty.isEmpty, "mai un silenzio")
        let emptyIds = Set(empty.map(\.id))
        let nothingNewIds = Set(nothingNew.map(\.id))
        XCTAssertNotEqual(emptyIds, nothingNewIds, "le due diramazioni devono produrre righe diverse")

        guard let emptySourceLine = empty.first(where: { $0.id == "empty-source" }) else {
            return XCTFail("manca la riga dedicata alla sorgente vuota")
        }
        XCTAssertFalse(nothingNew.contains { $0.id == "empty-source" },
                       "il reimport non deve MAI produrre la riga di sorgente vuota")
        XCTAssertTrue(emptySourceLine.text.lowercased().contains("non ho trovato")
                      || emptySourceLine.text.lowercased().contains("nessuna foto"))
    }

    // MARK: - Registro anti-gergo, su tutte le diramazioni

    /// Una diramazione per ogni combinazione rilevante di `lines`, con nome. Condivisa fra i
    /// test che devono girare sulle STESSE diramazioni — altrimenti il registro anti-gergo
    /// rischia di finire verificato solo su un sottoinsieme, esattamente il rilievo chiuso il
    /// 2026-09-01 su `LibraryIndexStatus`.
    private func tutteLeDiramazioni() -> [(nome: String, toAdd: Int, toSkipDuplicates: Int, toAddBytes: Int64, estimatedSec: Int)] {
        [
            ("normale-senza-doppioni", 25, 0, 100_000_000, 30),
            ("normale-con-doppioni", 25, 4, 100_000_000, 30),
            ("un-solo-file", 1, 0, 1, 1),
            ("un-solo-doppione", 5, 1, 1, 1),
            ("niente-di-nuovo", 0, 12, 0, 0),
            ("sorgente-vuota", 0, 0, 0, 0),
        ]
    }

    func testEveryBranchIsActuallyReachedByItsCase() {
        for caso in tutteLeDiramazioni() {
            let lines = ImportPreviewStatus.lines(
                toAdd: caso.toAdd, toSkipDuplicates: caso.toSkipDuplicates,
                toAddBytes: caso.toAddBytes, estimatedSec: caso.estimatedSec, interrupted: false)
            XCTAssertFalse(lines.isEmpty, "il caso «\(caso.nome)» non produce nessuna riga")
        }
    }

    func testAntiJargonRegister_reachesEveryBranch() {
        let gergo = ["indice", "hash", "sha256", "sha", "sqlite", "mtime", "cache", "entry", "dedup", "scansione"]
        for caso in tutteLeDiramazioni() {
            let lines = ImportPreviewStatus.lines(
                toAdd: caso.toAdd, toSkipDuplicates: caso.toSkipDuplicates,
                toAddBytes: caso.toAddBytes, estimatedSec: caso.estimatedSec, interrupted: false)
            for line in lines {
                let detto = line.text.lowercased()
                for parola in gergo {
                    XCTAssertFalse(detto.contains(parola),
                                   "gergo nella diramazione «\(caso.nome)» (\(line.id)): '\(parola)' in «\(detto)»")
                }
            }
        }
        // Il motivo di indisponibilita' e' un'altra superficie testuale mostrata all'utente:
        // deve rispettare lo stesso registro.
        for reason in [
            ImportPreviewStatus.unavailableReason(ssdConfigured: false, ssdMounted: false),
            ImportPreviewStatus.unavailableReason(ssdConfigured: true, ssdMounted: false),
        ].compactMap({ $0 }) {
            let detto = reason.lowercased()
            for parola in gergo {
                XCTAssertFalse(detto.contains(parola), "gergo nel motivo di indisponibilita': '\(parola)' in «\(detto)»")
            }
        }
        // E la riga di avanzamento.
        let progress = ImportPreviewStatus.progressLine(done: 10, total: 200, sourceFileCount: 12_000, elapsedSec: 0).lowercased()
        for parola in gergo {
            XCTAssertFalse(progress.contains(parola), "gergo nella riga di avanzamento: '\(parola)' in «\(progress)»")
        }
    }

    // MARK: - `id` stabili e unici

    /// Stesso input, due chiamate: gli `id` devono coincidere — altrimenti SwiftUI vedrebbe
    /// tutte le righe come nuove a ogni ridisegno.
    func testStableIdsAcrossTwoCallsWithSameData() {
        let first = ImportPreviewStatus.lines(toAdd: 7, toSkipDuplicates: 2, toAddBytes: 500, estimatedSec: 3, interrupted: false)
        let second = ImportPreviewStatus.lines(toAdd: 7, toSkipDuplicates: 2, toAddBytes: 500, estimatedSec: 3, interrupted: false)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    /// Gli `id` prodotti da UNA chiamata devono essere unici fra loro — altrimenti `ForEach`
    /// mostrerebbe una riga al posto di due.
    func testIdsAreUniqueWithinASingleCall() {
        for caso in tutteLeDiramazioni() {
            let lines = ImportPreviewStatus.lines(
                toAdd: caso.toAdd, toSkipDuplicates: caso.toSkipDuplicates,
                toAddBytes: caso.toAddBytes, estimatedSec: caso.estimatedSec, interrupted: false)
            let ids = lines.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "id duplicati nel caso «\(caso.nome)»: \(ids)")
        }
    }

    // MARK: - Riga di avanzamento

    /// Deve dire quanti su quanti.
    func testProgressLine_saysHowManyOfHowMany() {
        let line = ImportPreviewStatus.progressLine(done: 42, total: 200, sourceFileCount: 200, elapsedSec: 0)
        XCTAssertTrue(line.contains("42"))
        XCTAssertTrue(line.contains("200"))
    }

    /// Quando il denominatore (i candidati che superano il prefiltro) e' molto piu' piccolo
    /// del totale della sorgente, la riga deve nominare anche il totale della sorgente: e'
    /// l'informazione che dice all'utente se aspettera' 3 secondi o 3 minuti.
    func testProgressLine_namesSourceTotalWhenDenominatorIsMuchSmaller() {
        let line = ImportPreviewStatus.progressLine(done: 5, total: 40, sourceFileCount: 12_000, elapsedSec: 0)
        XCTAssertTrue(line.contains("40"))
        XCTAssertTrue(line.contains("12.000") || line.contains("12000") || line.contains("12,000"),
                      "deve nominare il totale della sorgente: «\(line)»")
    }

    /// Quando il totale COINCIDE col totale della sorgente (nessun prefiltro a ridurre il
    /// denominatore), non deve ripetere lo stesso numero una seconda volta come se fosse
    /// un'informazione diversa.
    func testProgressLine_doesNotRepeatWhenDenominatorEqualsSourceTotal() {
        let line = ImportPreviewStatus.progressLine(done: 5, total: 200, sourceFileCount: 200, elapsedSec: 0)
        // Il "200" compare una volta sola nel testo (come totale), non due.
        let occurrences = line.components(separatedBy: "200").count - 1
        XCTAssertEqual(occurrences, 1, "«\(line)» ripete il totale come se la sorgente fosse un'informazione diversa")
    }

    // MARK: - Tempo trascorso nella riga di avanzamento (Task 4, requisito 2 di Enrico)
    //
    // Aggiunti in Task 4 (non previsti dal piano, che assegnava a `progressLine` solo
    // "quanti su quanti"): la condizione con cui Enrico ha accettato la doppia lettura
    // della sorgente comprende ESPLICITAMENTE "un timer o una figura che gira", ma
    // `ImportPreviewStatus.progressLine` (Task 3) non citava affatto il tempo. Riusa
    // `FileSyncer.SyncResult.hms`, non lo riscrive.

    /// Il tempo trascorso compare, formattato con lo stesso `hms` usato dai job.
    func testProgressLine_includesElapsedTimeFormattedWithHms() {
        let line = ImportPreviewStatus.progressLine(done: 5, total: 200, sourceFileCount: 200, elapsedSec: 65)
        XCTAssertTrue(line.contains(FileSyncer.SyncResult.hms(65)), "«\(line)» non riporta il tempo trascorso")
    }

    /// Zero secondi trascorsi: deve comunque comparire (mai omesso, e' l'unica prova che
    /// il controllo sta davvero procedendo).
    func testProgressLine_zeroElapsed_stillShowsTheTime() {
        let line = ImportPreviewStatus.progressLine(done: 0, total: 200, sourceFileCount: 200, elapsedSec: 0)
        XCTAssertTrue(line.contains(FileSyncer.SyncResult.hms(0)))
    }

    // MARK: - Interruzione: degrada al conteggio grezzo, non a uno schermo vuoto
    //
    // Aggiunti in Task 4 (non previsti dal piano, che assegnava a `lines` solo quattro
    // diramazioni): e' la conseguenza diretta della risposta 4 di Enrico nella spec —
    // "Interrompere non lascia una schermata vuota, e non torna indietro" — degrada al
    // conteggio grezzo con una riga che dice la verita'.

    /// L'interruzione aggiunge una riga dedicata, che dice che il controllo si e' fermato
    /// e che il numero potrebbe includere foto gia' sull'SSD.
    func testInterrupted_addsWarningLineAboutTheInterruption() {
        let lines = ImportPreviewStatus.lines(toAdd: 10, toSkipDuplicates: 2, toAddBytes: 1_000, estimatedSec: 1, interrupted: true)
        guard let warning = lines.first(where: { $0.id == "interrupted" }) else {
            return XCTFail("manca la riga che dichiara l'interruzione")
        }
        XCTAssertEqual(warning.tone, .warning)
        XCTAssertTrue(warning.text.lowercased().contains("interrott"), "«\(warning.text)» non dice che il controllo e' stato interrotto")
        XCTAssertTrue(warning.text.lowercased().contains("ssd"), "«\(warning.text)» non avverte che alcune foto potrebbero essere gia' sull'SSD")
    }

    /// Senza interruzione, la riga non compare affatto.
    func testNotInterrupted_noWarningLine() {
        let lines = ImportPreviewStatus.lines(toAdd: 10, toSkipDuplicates: 2, toAddBytes: 1_000, estimatedSec: 1, interrupted: false)
        XCTAssertFalse(lines.contains { $0.id == "interrupted" })
    }

    /// Interrotto con toAdd == 0 e toSkipDuplicates == 0: NON e' la stessa cosa di
    /// "sorgente vuota" (quella e' una constatazione confidente su un controllo arrivato
    /// in fondo). Un controllo troncato non puo' dichiarare con sicurezza che la sorgente
    /// e' vuota: la riga dedicata alla sorgente vuota non deve mai comparire qui.
    func testInterrupted_neverClaimsEmptySourceEvenWithZeroCounts() {
        let lines = ImportPreviewStatus.lines(toAdd: 0, toSkipDuplicates: 0, toAddBytes: 0, estimatedSec: 0, interrupted: true)
        XCTAssertFalse(lines.isEmpty, "mai un silenzio, nemmeno interrotti")
        XCTAssertFalse(lines.contains { $0.id == "empty-source" },
                       "un controllo interrotto non puo' dichiarare la sorgente vuota con sicurezza")
        XCTAssertTrue(lines.contains { $0.id == "interrupted" })
    }

    /// Interrotto con toAdd == 0 e toSkipDuplicates > 0: NON e' la stessa "buona notizia
    /// confidente" del reimport completo ("le hai gia' tutte") — quella affermazione
    /// presuppone che il controllo sia arrivato in fondo.
    func testInterrupted_doesNotClaimTheConfidentGoodNewsOfACompleteRecheck() {
        let lines = ImportPreviewStatus.lines(toAdd: 0, toSkipDuplicates: 5, toAddBytes: 0, estimatedSec: 0, interrupted: true)
        guard let toAddLine = lines.first(where: { $0.id == "toAdd" }) else {
            return XCTFail("manca la riga principale anche interrotti")
        }
        XCTAssertFalse(toAddLine.text.lowercased().contains("già tutte"),
                       "«\(toAddLine.text)» dichiara una certezza che l'interruzione non permette")
        XCTAssertTrue(lines.contains { $0.id == "interrupted" })
    }

    /// Registro anti-gergo sulla riga di interruzione: stessa disciplina delle altre.
    func testInterrupted_antiJargonRegister() {
        let gergo = ["indice", "hash", "sha256", "sha", "sqlite", "mtime", "cache", "entry", "dedup", "scansione"]
        let lines = ImportPreviewStatus.lines(toAdd: 3, toSkipDuplicates: 1, toAddBytes: 10, estimatedSec: 1, interrupted: true)
        guard let warning = lines.first(where: { $0.id == "interrupted" }) else {
            return XCTFail("manca la riga di interruzione")
        }
        let detto = warning.text.lowercased()
        for parola in gergo {
            XCTAssertFalse(detto.contains(parola), "gergo nella riga di interruzione: '\(parola)' in «\(detto)»")
        }
    }

    /// Gli `id` restano unici anche col ramo di interruzione attivo.
    func testInterrupted_idsRemainUnique() {
        let lines = ImportPreviewStatus.lines(toAdd: 10, toSkipDuplicates: 2, toAddBytes: 1_000, estimatedSec: 1, interrupted: true)
        let ids = lines.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "id duplicati col ramo di interruzione: \(ids)")
    }
}
