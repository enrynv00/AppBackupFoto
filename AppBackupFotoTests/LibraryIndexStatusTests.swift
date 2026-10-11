//
//  LibraryIndexStatusTests.swift
//  AppBackupFotoTests
//
//  Le righe di stato della card "Foto gia' salvate sull'SSD" (roadmap #31, Task 6) e le
//  regole dell'aggiornamento automatico.
//
//  Perche' questa logica sta fuori dalla View: e' l'unica parte della card verificabile
//  senza una corsa reale sull'SSD, ed e' quella che sbaglia piu' facilmente. La regola
//  "traversata incompleta => non si toglie niente" ha cause diverse (SSD scollegato,
//  cartelle illeggibili, interruzione dell'utente, zero file visti) e ognuna richiede una
//  spiegazione diversa: se il messaggio non distingue, Enrico vede un conteggio che non
//  torna e nessun modo di capire perche'.
//

import XCTest
@testable import AppBackupFoto

final class LibraryIndexStatusTests: XCTestCase {

    /// Lettura arrivata in fondo, senza niente da segnalare.
    private func completa(_ mutate: (inout LibraryIndexer.Progress) -> Void = { _ in }) -> LibraryIndexer.Progress {
        var p = LibraryIndexer.Progress()
        p.traversalIncomplete = false
        p.scanned = 120
        p.total = 120
        mutate(&p)
        return p
    }

    private func lines(_ p: LibraryIndexer.Progress, interrupted: Bool = false) -> [LibraryIndexStatus.Line] {
        LibraryIndexStatus.lines(for: p, interruptedByUser: interrupted)
    }

    private func text(_ p: LibraryIndexer.Progress, interrupted: Bool = false) -> String {
        lines(p, interrupted: interrupted).map(\.text).joined(separator: " | ")
    }

    // MARK: Perche' la lettura non e' arrivata in fondo

    func testCleanScan_saysEverythingIsUpToDate() {
        let out = lines(completa())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.tone, .ok)
    }

    // "SSD scollegato a meta'" e "3 cartelle senza permessi" sono due guasti diversi e
    // vanno detti in modo diverso: il primo si risolve ricollegando il disco, il secondo no.
    func testVolumeVanished_isToldApartFromUnreadableFolders() {
        var p = completa()
        p.volumeVanished = true
        p.traversalIncomplete = true

        let out = lines(p)
        XCTAssertEqual(out.first?.id, "volume")
        XCTAssertEqual(out.first?.tone, .warning)
        // Una riga sola: la spiegazione generica "non sono riuscita a leggere tutto" e' un
        // residuo, non si aggiunge a una spiegazione precisa che c'e' gia'.
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(text(p).lowercased().contains("scollegato"))
        XCTAssertFalse(out.contains { $0.id == "illeggibili" })
    }

    func testUnreadableFolders_areReportedWithTheirNumber() {
        var p = completa()
        p.unreadableItems = 3
        p.traversalIncomplete = true

        let out = lines(p)
        XCTAssertTrue(out.contains { $0.id == "illeggibili" && $0.tone == .warning })
        XCTAssertTrue(text(p).contains("3"), "il numero va detto, non basta il colore")
        XCTAssertFalse(out.contains { $0.id == "volume" })
    }

    // Un solo elemento illeggibile: il plurale sbagliato in una riga letta da un utente non
    // tecnico e' un difetto quanto un numero sbagliato.
    func testASingleUnreadableFolder_usesTheSingular() {
        var p = completa()
        p.unreadableItems = 1
        p.traversalIncomplete = true

        XCTAssertTrue(text(p).contains("1 cartella non si è lasciata aprire"))
    }

    func testUserInterruption_isSaidAndIsNotAlarming() {
        var p = completa()
        p.traversalIncomplete = true

        let out = lines(p, interrupted: true)
        XCTAssertTrue(out.contains { $0.id == "interrotto" && $0.tone == .info })
        // Il punto che Enrico ha chiesto esplicitamente: chi interrompe deve capire che
        // l'elenco parziale e' valido e non va buttato.
        XCTAssertTrue(text(p, interrupted: true).lowercased().contains("resta salvato"))
    }

    // Zero file visti con l'elenco pieno NON e' "libreria vuota". E' l'unico caso in cui
    // nessun controllo, nemmeno quello completo, riesce a togliere le voci fantasma: il
    // messaggio deve nominare la sola via d'uscita (ADR-0002).
    func testNothingFoundButTheListIsNotEmpty_pointsAtTheResetCommand() {
        var p = LibraryIndexer.Progress()
        p.scanned = 0
        p.total = 42

        let out = lines(p)
        XCTAssertTrue(out.contains { $0.id == "vuoto" && $0.tone == .warning })
        XCTAssertTrue(text(p).contains("Svuota l'elenco e ricomincia da zero"))
        XCTAssertTrue(text(p).contains("42"))
    }

    // Lo stesso `scanned == 0` capita anche quando l'SSD non c'era proprio: li' il consiglio
    // "svuota l'elenco" sarebbe un pessimo consiglio.
    func testNothingFoundBecauseTheVolumeWasGone_doesNotSuggestWipingTheList() {
        var p = LibraryIndexer.Progress()
        p.scanned = 0
        p.total = 42
        p.volumeVanished = true

        XCTAssertFalse(lines(p).contains { $0.id == "vuoto" })
        XCTAssertFalse(text(p).contains("Svuota l'elenco"))
    }

    // ...e quando e' stato l'utente a fermare la lettura al primo istante.
    func testNothingFoundBecauseTheUserStoppedImmediately_doesNotSuggestWipingTheList() {
        var p = LibraryIndexer.Progress()
        p.scanned = 0
        p.total = 42

        XCTAssertFalse(lines(p, interrupted: true).contains { $0.id == "vuoto" })
    }

    // ...e quando la root non si e' lasciata aprire (permessi, TCC perso, EIO): anche li'
    // `scanned == 0`, ma il volume c'e' e nessuno ha interrotto niente. Senza questa
    // esclusione la card diceva insieme "1 cartella non si e' lasciata aprire" e "se hai
    // davvero svuotato l'SSD, svuota l'elenco": due istruzioni opposte nella stessa
    // schermata, e quella sbagliata e' l'unica distruttiva (5-15 minuti di ricostruzione e
    // doppioni ricreati al primo import).
    func testNothingFoundBecauseNothingCouldBeRead_doesNotSuggestWipingTheList() {
        var p = LibraryIndexer.Progress()
        p.scanned = 0
        p.total = 118_432
        p.unreadableItems = 1

        let out = lines(p)
        XCTAssertFalse(out.contains { $0.id == "vuoto" })
        XCTAssertFalse(text(p).contains(LibraryIndexCommands.reset),
                       "non si consiglia il comando distruttivo quando la lettura e' fallita")
        XCTAssertTrue(out.contains { $0.id == "illeggibili" },
                      "il motivo vero va detto lo stesso")
    }

    // ...e quando la lettura e' stata fermata da uno smontaggio che non riguarda l'SSD (un
    // DMG, una chiavetta espulsa nei primi secondi): la cancellazione automatica passa dallo
    // stesso `cancel()` ma NON e' un'interruzione dell'utente, e il volume non e' sparito.
    // Senza `Progress.cancelled` la card leggeva solo `scanned == 0` e finiva a consigliare
    // lo svuotamento dopo un evento che non c'entra niente.
    func testNothingFoundBecauseTheReadWasStopped_doesNotSuggestWipingTheList() {
        var p = LibraryIndexer.Progress()
        p.scanned = 0
        p.total = 42
        p.cancelled = true

        XCTAssertFalse(lines(p, interrupted: false).contains { $0.id == "vuoto" },
                       "fermata non e' vuota, nemmeno quando a fermarla non e' stato l'utente")
        // Silenzio no: la lettura non e' arrivata in fondo e va detto.
        XCTAssertTrue(lines(p, interrupted: false).contains { $0.id == "incompleta" })
    }

    // Traversata incompleta senza una causa riconoscibile: meglio una riga generica che il
    // silenzio su una lettura che non ha coperto tutta la libreria.
    func testIncompleteScanWithNoKnownCause_stillSaysSomething() {
        var p = completa()
        p.traversalIncomplete = true

        let out = lines(p)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.id, "incompleta")
        XCTAssertEqual(out.first?.tone, .warning)
    }

    func testCompleteScan_doesNotClaimItWasIncomplete() {
        XCTAssertFalse(lines(completa()).contains { $0.id == "incompleta" })
    }

    // MARK: Foto sparite dal disco e tenute lo stesso

    // Obbligatoria: senza questa riga la guardia di plausibilita' scatta in silenzio e dopo
    // una riorganizzazione legittima continuerebbe a scattare a ogni avvio, per sempre.
    func testKeptVanishedEntries_areAlwaysReported() {
        var p = completa()
        p.vanishedKept = 7

        let out = lines(p)
        XCTAssertTrue(out.contains { $0.id == "sparite" && $0.tone == .warning })
        XCTAssertTrue(text(p).contains("7"))
    }

    // Dopo una traversata COMPLETA la ricontrollata da capo serve davvero: scavalca la
    // guardia di plausibilita'.
    func testVanishedAfterACompleteScan_suggestsTheFullRecheck() {
        var p = completa()
        p.vanishedKept = 7

        XCTAssertTrue(text(p).contains("Controlla tutte le foto da capo"))
    }

    // Dopo una traversata INCOMPLETA no: `ignoringStoredHashes` scavalca solo la guardia di
    // plausibilita', mai la traversata incompleta. Consigliarla manderebbe l'utente a
    // rifare quindici minuti di lettura per ottenere esattamente lo stesso risultato.
    func testVanishedAfterAnIncompleteScan_doesNotSuggestTheFullRecheck() {
        var p = completa()
        p.vanishedKept = 7
        p.traversalIncomplete = true

        let out = text(p)
        XCTAssertTrue(out.contains("7"))
        XCTAssertFalse(out.contains("Controlla tutte le foto da capo"),
                       "la ricontrollata completa non scavalca la traversata incompleta")
    }

    func testNothingVanished_saysNothingAboutIt() {
        XCTAssertFalse(lines(completa()).contains { $0.id == "sparite" })
    }

    // MARK: Numeri che spiegano perche' il conteggio non torna

    func testUnreadableFiles_areReportedAsNeutralInformation() {
        var p = completa()
        p.errors = 4

        let out = lines(p)
        XCTAssertTrue(out.contains { $0.id == "errori" && $0.tone == .info })
        XCTAssertTrue(text(p).contains("4"))
    }

    func testFilesOutsideTheLibrary_areReported() {
        var p = completa()
        p.outsideRoot = 2

        let out = lines(p)
        XCTAssertTrue(out.contains { $0.id == "fuori" && $0.tone == .info })
        XCTAssertTrue(text(p).contains("2"))
    }

    // Il riallineamento dopo un cambio d'ora non e' un problema: e' la regola DST che fa il
    // suo lavoro, e va detta con tono neutro, mai come un avviso.
    func testTimezoneRebase_isNeutralNotAWarning() {
        var p = completa()
        p.rebasedByTimezone = 5

        let out = lines(p)
        XCTAssertTrue(out.contains { $0.id == "fuso" && $0.tone == .info })
        XCTAssertFalse(out.contains { $0.tone == .warning })
        XCTAssertTrue(text(p).contains("5"))
    }

    // MARK: Registro

    // Regola di progetto: l'app deve essere comprensibile a chi non sa come e' fatta. Se una
    // stringa richiede di conoscere il programma per essere capita, e' sbagliata.
    func testNoTechnicalJargonReachesTheScreen() {
        var tutto = LibraryIndexer.Progress()
        tutto.scanned = 10; tutto.hashed = 5; tutto.skipped = 5; tutto.errors = 2
        tutto.total = 100; tutto.vanishedKept = 3; tutto.rebasedByTimezone = 4
        tutto.unreadableItems = 6; tutto.outsideRoot = 7; tutto.volumeVanished = true

        let gergo = ["indice", "hash", "sha", "scansione", "sqlite", "mtime", "cache",
                     "entry", "traversata", "incrementale"]
        for p in [completa(), tutto] {
            for interrotto in [false, true] {
                let detto = text(p, interrupted: interrotto).lowercased()
                for parola in gergo {
                    XCTAssertFalse(detto.contains(parola), "gergo a schermo: '\(parola)' in «\(detto)»")
                }
            }
        }
        for comando in [LibraryIndexCommands.build, LibraryIndexCommands.refresh,
                        LibraryIndexCommands.fullRecheck, LibraryIndexCommands.reset,
                        LibraryIndexCommands.stop] {
            for parola in gergo {
                XCTAssertFalse(comando.lowercased().contains(parola), "gergo su un bottone: \(comando)")
            }
        }
    }

    // Il comando distruttivo non puo' chiamarsi solo "Elimina": su un'app che gestisce foto
    // si leggerebbe come "elimina le foto".
    func testTheDestructiveCommandSaysWhatItDeletes() {
        XCTAssertTrue(LibraryIndexCommands.reset.lowercased().contains("elenco"))
    }

    // MARK: Aggiornamento automatico

    // I sei test che stavano qui (`testAutoRefresh_*`) verificavano
    // `LibraryIndexAutoRefresh.shouldRun`, rimossa il 2026-09-19 insieme alla lettura
    // automatica al collegamento dell'SSD (decisione di Enrico, domanda aperta 1 della spec
    // del passo 2 del backup): le stesse condizioni vivono ora in
    // `BackupListStep.shouldRun` (vedi `BackupListStepTests`), tranne "aspetta la fine di un
    // job", che non ha piu' senso — il passo 2 **e'** il job. Il test sull'interruttore
    // resta: la chiave `UserDefaults` non e' cambiata.

    // `UserDefaults.bool` risponde `false` per una chiave mai scritta, e `@AppStorage` la
    // scrive solo al primo cambiamento: con `bool` l'aggiornamento automatico sarebbe
    // rimasto spento per default, al contrario di quello che dice l'interruttore.
    func testAutoRefreshSwitch_isOnUntilTheUserTurnsItOff() throws {
        let suite = "LibraryIndexStatusTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(LibraryIndexAutoRefresh.isEnabled(defaults: defaults),
                      "mai toccato = acceso")

        defaults.set(false, forKey: LibraryIndexAutoRefresh.defaultsKey)
        XCTAssertFalse(LibraryIndexAutoRefresh.isEnabled(defaults: defaults))

        defaults.set(true, forKey: LibraryIndexAutoRefresh.defaultsKey)
        XCTAssertTrue(LibraryIndexAutoRefresh.isEnabled(defaults: defaults))
    }

    // MARK: - Rilievi minori di #31, chiusi il 2026-09-01

    /// Una diramazione per ogni `id` prodotto da `lines`, con il nome del caso accanto.
    /// Esiste perche' i tre test qui sotto devono girare sulle **stesse** diramazioni: una
    /// lista costruita a mano dentro ognuno divergerebbe dagli altri alla prima riga nuova,
    /// ed e' esattamente cosi' che il registro anti-gergo era finito a coprirne 6 su 10.
    private func tutteLeDiramazioni() -> [(nome: String, p: LibraryIndexer.Progress, interrotto: Bool)] {
        func base(_ mutate: (inout LibraryIndexer.Progress) -> Void) -> LibraryIndexer.Progress {
            var p = LibraryIndexer.Progress()
            p.traversalIncomplete = false
            p.scanned = 120
            p.total = 120
            mutate(&p)
            return p
        }
        return [
            ("volume",     base { $0.volumeVanished = true; $0.traversalIncomplete = true }, false),
            ("interrotto", base { $0.traversalIncomplete = true }, true),
            ("illeggibili", base { $0.unreadableItems = 3; $0.traversalIncomplete = true }, false),
            ("vuoto",      base { $0.scanned = 0; $0.total = 42; $0.traversalIncomplete = true }, false),
            ("incompleta", base { $0.traversalIncomplete = true }, false),
            ("sparite",    base { $0.vanishedKept = 4 }, false),
            ("errori",     base { $0.errors = 2 }, false),
            ("fuori",      base { $0.outsideRoot = 5 }, false),
            ("fuso",       base { $0.rebasedByTimezone = 6 }, false),
            ("ok",         base { _ in }, false),
        ]
    }

    /// La diramazione che il caso dichiara di esercitare deve davvero comparire: senza
    /// questa verifica i tre test sotto potrebbero girare tutti sulla riga "ok" e restare
    /// verdi senza provare niente.
    func testEveryBranchIsActuallyReachedByItsCase() {
        for caso in tutteLeDiramazioni() {
            let ids = lines(caso.p, interrupted: caso.interrotto).map(\.id)
            XCTAssertTrue(ids.contains(caso.nome),
                          "il caso «\(caso.nome)» non produce la riga omonima: \(ids)")
        }
    }

    /// Rilievo minore di #31: il registro anti-gergo era verificato su 6 diramazioni su 10.
    /// Un registro verificato a meta' non e' un registro verificato — le righe scoperte sono
    /// esattamente quelle rare, cioe' quelle che nessuno rilegge prima di spedire.
    func testAntiJargonRegister_reachesEveryBranch() {
        let gergo = ["indice", "hash", "sha", "scansione", "sqlite", "mtime", "cache",
                     "entry", "traversata", "incrementale"]
        for caso in tutteLeDiramazioni() {
            let detto = text(caso.p, interrupted: caso.interrotto).lowercased()
            for parola in gergo {
                XCTAssertFalse(detto.contains(parola),
                               "gergo nella diramazione «\(caso.nome)»: '\(parola)' in «\(detto)»")
            }
        }
    }

    /// Rilievo minore di #31: i plurali non erano testati. Ogni riga che porta un numero ha
    /// due forme, e la forma sbagliata («1 foto risultano sparite») e' il genere di dettaglio
    /// che fa sembrare l'app scritta male proprio nel momento in cui sta dando una notizia
    /// che l'utente deve prendere sul serio.
    func testCountedLines_agreeWithTheirNumber() {
        func riga(_ id: String, _ mutate: (inout LibraryIndexer.Progress) -> Void) -> String {
            var p = LibraryIndexer.Progress()
            p.traversalIncomplete = false
            p.scanned = 120; p.total = 120
            mutate(&p)
            return lines(p).first { $0.id == id }?.text ?? ""
        }

        XCTAssertTrue(riga("illeggibili") { $0.unreadableItems = 1 }.contains("cartella non si è lasciata aprire"))
        XCTAssertTrue(riga("illeggibili") { $0.unreadableItems = 2 }.contains("cartelle non si sono lasciate aprire"))

        let unaSparita = riga("sparite") { $0.vanishedKept = 1 }
        XCTAssertTrue(unaSparita.contains("foto risulta sparita"))
        XCTAssertTrue(unaSparita.contains("ed è stata lasciata"))
        let dueSparite = riga("sparite") { $0.vanishedKept = 2 }
        XCTAssertTrue(dueSparite.contains("foto risultano sparite"))
        XCTAssertTrue(dueSparite.contains("e sono state lasciate"))

        let unErrore = riga("errori") { $0.errors = 1 }
        XCTAssertTrue(unErrore.contains("file non si è lasciato leggere"))
        XCTAssertTrue(unErrore.contains("è entrato"))
        XCTAssertTrue(unErrore.contains("verrà copiato"))
        let dueErrori = riga("errori") { $0.errors = 2 }
        XCTAssertTrue(dueErrori.contains("file non si sono lasciati leggere"))
        XCTAssertTrue(dueErrori.contains("sono entrati"))
        XCTAssertTrue(dueErrori.contains("verranno copiati"))

        let unoFuori = riga("fuori") { $0.outsideRoot = 1 }
        XCTAssertTrue(unoFuori.contains("file si trovava"))
        XCTAssertTrue(unoFuori.contains("ed è stato ignorato"))
        let dueFuori = riga("fuori") { $0.outsideRoot = 2 }
        XCTAssertTrue(dueFuori.contains("file si trovavano"))
        XCTAssertTrue(dueFuori.contains("e sono stati ignorati"))

        XCTAssertTrue(riga("fuso") { $0.rebasedByTimezone = 1 }.contains("foto rimessa in pari"))
        XCTAssertTrue(riga("fuso") { $0.rebasedByTimezone = 2 }.contains("foto rimesse in pari"))
    }

    /// Rilievo minore di #31: gli `id` non erano testati. Il doc-comment di `Line.id` dice
    /// che l'identita' e' stabile apposta, perche' con un UUID SwiftUI vedrebbe tutte le
    /// righe come nuove a ogni ridisegno. Un'identita' duplicata e' l'altro verso dello
    /// stesso guasto: `ForEach` mostrerebbe una riga sola al posto di due.
    func testLineIds_areUniqueAndStableAcrossRedraws() {
        var tutto = LibraryIndexer.Progress()
        tutto.traversalIncomplete = true
        tutto.scanned = 10; tutto.total = 100
        tutto.volumeVanished = true; tutto.unreadableItems = 3; tutto.vanishedKept = 4
        tutto.errors = 2; tutto.outsideRoot = 5; tutto.rebasedByTimezone = 6

        let primo = lines(tutto, interrupted: true).map(\.id)
        let secondo = lines(tutto, interrupted: true).map(\.id)
        XCTAssertEqual(primo, secondo, "gli id devono essere gli stessi a ogni ridisegno")
        XCTAssertEqual(Set(primo).count, primo.count, "id duplicati: \(primo)")

        for caso in tutteLeDiramazioni() {
            let ids = lines(caso.p, interrupted: caso.interrotto).map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "id duplicati in «\(caso.nome)»: \(ids)")
        }
    }

    // MARK: I comandi della card e il job di copia

    /// Rilievo minore di #31: i bottoni della card non sapevano di un job in corso, mentre
    /// l'aggiornamento automatico si'. Chi premeva "Aggiorna" durante un backup faceva
    /// leggere per intero l'SSD mentre una copia ci scriveva sopra.
    func testCommandGate_blocksWhileACopyJobIsRunning() {
        XCTAssertNotNil(LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false))
    }

    func testCommandGate_blocksWhileTheListIsBeingRead() {
        XCTAssertNotNil(LibraryIndexCommandGate.disabledReason(isIndexing: true, jobIsRunning: false, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false))
    }

    func testCommandGate_allowsWhenNothingElseIsGoingOn() {
        XCTAssertNil(LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false))
    }

    /// Le due cause hanno due frasi diverse: un bottone grigio senza motivo, o con il motivo
    /// sbagliato, e' la stessa disciplina gia' applicata a `RestoreView` e al pannello
    /// Doppioni — disattivare **e** dire perche'.
    func testCommandGate_tellsTheTwoCausesApart() {
        let job = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        let lettura = LibraryIndexCommandGate.disabledReason(isIndexing: true, jobIsRunning: false, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotEqual(job, lettura)
    }

    /// Task 4 (2026-09-19, BUG-7): lo spostamento nel Cestino ha la PRECEDENZA sulle altre
    /// due — da quando gira fuori dal main puo' essere in corso insieme a una lettura, ed e'
    /// la causa piu' vicina al danno.
    func testCommandGate_blocksWhileTrashingIsInProgress() {
        let reason = LibraryIndexCommandGate.disabledReason(isIndexing: true, jobIsRunning: false,
                                                             isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("cestino"))
    }

    /// Il motivo finisce a schermo come tutte le altre righe della card.
    func testCommandGate_reasonsCarryNoJargon() {
        let gergo = ["indice", "hash", "sha", "scansione", "sqlite", "mtime", "cache", "entry"]
        for reason in [LibraryIndexCommandGate.disabledReason(isIndexing: true, jobIsRunning: false, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                       LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                       LibraryIndexCommandGate.disabledReason(isIndexing: true, jobIsRunning: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false),
                       LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false, isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false, isRepairing: false, isAligning: false)] {
            let detto = (reason ?? "").lowercased()
            for parola in gergo {
                XCTAssertFalse(detto.contains(parola), "gergo nel motivo: '\(parola)' in «\(detto)»")
            }
        }
    }

    /// Task 5 (2026-09-20, ADR-0009): un annullamento in corso blocca anche la lettura
    /// manuale, con un motivo distinto dagli altri due.
    func testCommandGate_restoringInProgress_disablesWithAReason() {
        let reason = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false,
                                                             isTrashingDuplicates: false, isRestoringFromTrash: true, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotNil(reason)
        let job = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: true,
                                                          isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        let trashing = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false,
                                                               isTrashingDuplicates: true, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        XCTAssertNotEqual(reason, job)
        XCTAssertNotEqual(reason, trashing)
    }


    // MARK: Lo svuotamento ha un motivo suo (rilievo di review del 2026-09-01)

    /// Lo svuotamento non legge l'SSD: la frase sulla lettura concorrente sarebbe **falsa**.
    /// Il danno e' un altro — un'importazione in corso usa l'elenco per non ricopiare foto
    /// gia' presenti, e togliergielo sotto significa fargliele ricopiare.
    func testResetGate_hasItsOwnReason_notTheReadingOne() {
        let lettura = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: true, isTrashingDuplicates: false, isRestoringFromTrash: false, isInventorying: false, isRepairing: false, isAligning: false)
        let svuota = LibraryIndexCommandGate.resetDisabledReason(isIndexing: false, jobIsRunning: true, isTrashingDuplicates: false, isInventorying: false)
        XCTAssertNotNil(svuota)
        XCTAssertNotEqual(svuota, lettura, "svuotare e rileggere non hanno lo stesso motivo")
        XCTAssertFalse(svuota!.lowercased().contains("illeggibili"),
                       "lo svuotamento non legge niente: non puo' parlare di file illeggibili")
    }

    func testResetGate_blocksDuringAReadAndDuringAJob() {
        XCTAssertNotNil(LibraryIndexCommandGate.resetDisabledReason(isIndexing: true, jobIsRunning: false, isTrashingDuplicates: false, isInventorying: false))
        XCTAssertNotNil(LibraryIndexCommandGate.resetDisabledReason(isIndexing: false, jobIsRunning: true, isTrashingDuplicates: false, isInventorying: false))
        XCTAssertNil(LibraryIndexCommandGate.resetDisabledReason(isIndexing: false, jobIsRunning: false, isTrashingDuplicates: false, isInventorying: false))
    }

    /// Stessa precedenza dell'altro gate: lo spostamento vince su isIndexing/jobIsRunning.
    func testResetGate_blocksWhileTrashingIsInProgress() {
        let reason = LibraryIndexCommandGate.resetDisabledReason(isIndexing: false, jobIsRunning: false,
                                                                  isTrashingDuplicates: true, isInventorying: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("cestino"))
    }

    func testResetGate_reasonsCarryNoJargon() {
        let gergo = ["indice", "hash", "sha", "scansione", "sqlite", "mtime", "cache", "entry"]
        for reason in [LibraryIndexCommandGate.resetDisabledReason(isIndexing: true, jobIsRunning: false, isTrashingDuplicates: false, isInventorying: false),
                       LibraryIndexCommandGate.resetDisabledReason(isIndexing: false, jobIsRunning: true, isTrashingDuplicates: false, isInventorying: false)] {
            let detto = (reason ?? "").lowercased()
            for parola in gergo {
                XCTAssertFalse(detto.contains(parola), "gergo nel motivo: '\(parola)' in «\(detto)»")
            }
        }
    }

    // MARK: - Inventario in corso (ROADMAP #44)

    func testCommandGate_blocksDuringTheInventory_withItsOwnReason() {
        let reason = LibraryIndexCommandGate.disabledReason(isIndexing: false, jobIsRunning: false,
                                                            isTrashingDuplicates: false, isRestoringFromTrash: false,
                                                            isInventorying: true, isRepairing: false, isAligning: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("inventario"))
    }

    /// Svuotare l'elenco durante l'inventario cancellerebbe il file su cui l'inventario sta scrivendo.
    func testResetGate_blocksDuringTheInventory() {
        let reason = LibraryIndexCommandGate.resetDisabledReason(isIndexing: false, jobIsRunning: false,
                                                                 isTrashingDuplicates: false, isInventorying: true)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("inventario"))
    }
}
