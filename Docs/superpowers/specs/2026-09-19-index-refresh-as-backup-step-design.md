# Spec — L'aggiornamento dell'elenco delle foto diventa l'ultimo passo del backup

**Stato: APPROVATA da Enrico (2026-09-19).** Le tre domande aperte in fondo sono chiuse con le raccomandazioni dell'Architect, tutte confermate da Enrico: 1→(b) togliere la lettura automatica al collegamento dell'SSD, 2→«Backup completato» con la riga «Hai fermato l'aggiornamento dell'elenco…» (non «interrotto»), 3→sì, mostrare «passo 1 di 2» durante la copia. ADR: `Docs/adr/0007-l-aggiornamento-dell-elenco-e-l-ultimo-passo-del-backup.md`.

Piano di esecuzione: `Docs/superpowers/plans/2026-09-19-index-refresh-as-backup-step.md`.

**Base di partenza.** Il lavoro parte da `main` **dopo** il merge di `fix/mainactor-isolation` (letto al commit `50be4fc`). Tutto quello che segue presuppone le garanzie di quel fix: `LibraryIndexer.scan` gira davvero fuori dal main (ADR-0006), `JobStartGate` esiste, `isTrashingDuplicates` vive nel runner, i flag di interruzione sono protetti.

## Il problema

Oggi, a fine MAC → SSD (e a fine importazione), `run(label:refreshesLibraryIndex:work:)` fa tre cose di fila nello stesso `MainActor.run`: `phase = .success`, notifica + `completionSnapshot` (compare «Backup completato») + `JobHistoryStore.save`, e **poi** `autoRefreshLibraryIndexIfEnabled()` → `rebuildLibraryIndex()`. Dal punto di vista dell'app sono due attività separate:

- il backup risulta **finito** (`isRunning == false`): i pulsanti della barra laterale si **riattivano** (`enabled: !runner.isRunning`);
- intanto parte la lettura dell'elenco (`isIndexing == true`), e chi preme un pulsante di backup si vede rispondere da `JobStartGate` con l'avviso «Meglio non farlo adesso — L'app sta leggendo le foto sull'SSD… fermala con «Interrompi» in Diagnostica».

Il pulsante sembra disponibile, poi l'app dice di no e rimanda a un'altra finestra. È il comportamento che Enrico vuole togliere.

## La decisione di Enrico (UX)

L'aggiornamento dell'elenco è **l'ultimo passo del backup stesso**, «normale amministrazione»:

```
● MAC -> SSD — passo 2 di 2
  ✓ Foto copiate (0 nuove, 18.399 già presenti)
  ◐ Aggiorno l'elenco delle foto sull'SSD…
  ████████████░░░░░░  62%
  48.300 / 78.000 file controllati
                         [ Interrompi ]
```

Stessa barra e stesso «Interrompi» del backup; riepilogo «Backup completato» e notifica **solo alla fine**; nel frattempo gli altri pulsanti disattivati come durante qualsiasi backup, **senza avvisi**.

## Un fatto trovato leggendo il codice: oggi la barra del passo 2 non si muoverebbe

`LibraryIndexer.scan` chiama `onProgress` **solo quando un blocco da 200 voci si riempie** (`flushBatchIfFull`), e un blocco si riempie solo con file **da rileggere** (nuovi o cambiati) o spostati di fuso orario. Un file già in elenco e invariato (`.fresh`) fa `progress.skipped += 1; continue` e non produce nessun avanzamento. Dopo un backup normale — poche foto nuove, 47.000 invariate — la lettura resterebbe **muta per minuti** e salterebbe a 100% alla fine. Il mockup chiede «48.300 / 78.000 file controllati»: senza un avanzamento anche sui file invariati quel numero non esiste.

Secondo dettaglio collegato: `Progress.total` vale `0` finché non si svuota il primo blocco, e `rebuildLibraryIndex` copia `p.total` in `indexedFileCount` a ogni avanzamento. Un avanzamento emesso prima del primo blocco farebbe leggere per un istante «0 foto nell'elenco» alla card di Diagnostica. `scan` conosce già il numero giusto fin dall'inizio (`knownKeys = try store.allKeys()`).

Entrambi si correggono in `scan` con un cambiamento additivo (D5). È l'unico punto in cui questo lavoro tocca il codice più testato del progetto, e va trattato come tale.

## Design

### D1 — Il job resta «in corso» per tutto il passo 2 (una sola attività, non due)

Raccomandazione: **`phase` resta `.running(label)` dalla prima copia all'ultima voce dell'elenco.** È la scelta che dà gratis quasi tutto il mockup, perché l'app decide già tutto su `isRunning`:

| Chi legge `isRunning` | Effetto durante il passo 2, senza toccarlo |
| :--- | :--- |
| pulsanti MAC→SSD / SSD→HDD / SSD→Cubbit (`SidebarView`) | disattivati, come durante la copia |
| wizard di importazione (`importStartDisabledReason`) | non parte, col suo motivo già scritto |
| pulsante «Interrompi» della finestra principale | visibile |
| `MenuBarIcon` (icona che pulsa, badge sul Dock), `MenuBarContent` («Backup in corso») | invariati |
| `beginDuplicateTrashing`, `DuplicatesStatus.trashDisabledReason` | lo spostamento nel Cestino resta vietato (lo era già per `isIndexing`) |
| `LibraryIndexCommandGate` (card di Diagnostica) | comandi disattivati; il motivo mostrato è quello di `isIndexing`, che ha la precedenza ed è quello giusto |
| conferma di uscita (`if runner.isRunning { runner.stop() }`) | ferma la lettura (vedi D3) |

`isIndexing` resta **anche lui** vero durante il passo 2: la lettura è la stessa di sempre, con la stessa istanza di store e di indexer, e le difese che guardano `isIndexing` (una sola lettura per volta, `JobStartGate` per il caso manuale) restano valide.

Alternativa scartata: un terzo stato «backup finito ma elenco in aggiornamento» consultato da ogni pulsante. Obbliga a toccare tutti i siti della tabella sopra, e il primo che se ne dimentica riapre esattamente il problema di partenza.

**Conseguenza da far valutare a Enrico (non nascosta):** finché il passo 2 non finisce **non si può avviare un SSD → HDD o un SSD → Cubbit** subito dopo un MAC → SSD. Oggi il passo 2 dura circa 6 minuti misurati **sul main thread**; fuori dal main la durata è da rimisurare (Task 9 del piano precedente). La via d'uscita è «Interrompi», che non tocca le foto copiate (D3).

### D2 — Come nasce e come finisce il passo 2

Oggi `run` ha **un** punto di fine per il successo. Diventa una sequenza di due metodi privati di `BackupRunner`, entrambi sul MainActor:

1. **`finishCopyStep(result:label:)`** — la parte di oggi che riguarda le foto: aggiorna `stats` dal `SyncResult` esattamente come ora, e **salva il `JobSummary` subito** (`succeeded: true`, stessi campi di oggi). Poi decide il passo 2 con la funzione pura `BackupListStep.shouldRun(refreshesLibraryIndex:enabled:indexedFileCount:isIndexing:isTrashingDuplicates:)` — nessun parametro con default, per la stessa ragione dei gate del fix precedente. Se è falso chiama subito `finishJob(listOutcome: nil)`. Se è vero avvia il passo 2 (D4).
2. **`finishJob(listOutcome:)`** — l'unico punto dove il job **finisce davvero**: `phase = .success("Completato: \(label)")`, `stats.elapsed` = durata complessiva, notifica, `completionSnapshot`. Tutto quello che oggi sta dopo `JobHistoryStore.save`.

Perché il `JobSummary` si salva alla fine del passo 1 e non alla fine del job: racconta **le foto**, che a quel punto sono copiate e verificate. Se l'app viene chiusa, va in crash o l'SSD sparisce durante il passo 2, il registro dell'ultimo backup resta vero. Salvarlo alla fine lo esporrebbe a perdersi per un motivo che con le foto non c'entra. **Nessun campo nuovo in `JobSummary`**: niente cambio di formato persistito (e quindi niente `decodeIfPresent` nuovo). Lo stato dell'elenco ha già un posto dove si legge, la card di Diagnostica, che durante e dopo il passo 2 mostra le stesse righe di una lettura manuale (`indexProgress`, `indexInterruptedByUser` restano pubblicati).

**Il passo 1 fallisce o viene interrotto: niente passo 2.** Il ramo `catch` e `stop()` durante la copia restano identici: nessuna lettura parte (com'è oggi — `autoRefreshLibraryIndexIfEnabled` è solo nel ramo di successo). Un job riuscito **con errori su singoli file** (`stats.errors > 0`) è comunque un successo per `run`, e il passo 2 parte: le foto copiate vanno in elenco.

**L'elenco non c'è ancora (`indexedFileCount == 0`) o l'interruttore è spento: niente passo 2**, e il job finisce come oggi senza nessuna riga in più. La prima creazione resta manuale da Diagnostica (dura 15-25 minuti, è una decisione di #31 e non cambia).

**«passo 1 di 2» durante la copia.** Raccomandazione: sì. All'avvio del job `run` calcola se un passo 2 è previsto (stessa `shouldRun`, con i valori di quel momento) e pubblica `listStepState = .planned`; l'intestazione diventa «MAC -> SSD — passo 1 di 2». Senza, il passo 2 comparirebbe a sorpresa dopo che la barra ha toccato 100%. Il calcolo si **ripete** alla fine della copia, perché le condizioni possono cambiare (l'interruttore spento a metà): in quel caso raro il job finisce dopo il passo 1 anche se l'intestazione diceva «di 2». Se il passo 2 non è previsto l'intestazione è quella di oggi, senza «passo».

### D3 — Cosa significa «Interrompi» durante il passo 2

Raccomandazione: **il backup risulta completato, con una riga che dice che l'elenco non è stato aggiornato.** Non «interrotto».

| Opzione | Pro | Contro |
| :--- | :--- | :--- |
| **A. «Backup completato» + nota (scelta)** | dice la verità sulle foto: sono copiate e verificate, il `JobSummary` è già salvato come riuscito; l'elenco è una cache (ADR-0002), una lettura parziale è valida e utile e la prossima riprende da lì | l'utente ha premuto «Interrompi» e legge «completato»: serve la nota per non farlo sembrare ignorato |
| B. «Backup interrotto» (esito di `stop()` di oggi) | coerente con il pulsante premuto | **falso sulle foto**: icona rossa, «Backup fallito», `JobSummary.succeeded = false` da sovrascrivere — insegna a Enrico che il backup non è andato, quando è andato. È lo stesso errore che il progetto ha già scelto di non fare con `copiedUnverified` («sovrastimare le corruzioni insegna a ignorare l'allarme») |
| C. «Backup completato» senza nota | nessun testo nuovo | una fermata che non si dice: la classe di problema che il progetto teme di più |

Comportamento di `stop()`:

- **durante la copia**: identico a oggi.
- **durante il passo 2**: **non** imposta `wasStopped`, **non** tocca `phase`, **non** salva un `JobSummary`. Chiama `cancelIndexing()` (che imposta `indexInterruptedByUser = true` e ferma l'indexer) e pubblica `listStopRequested = true`: il pulsante resta visibile ma disattivato con la scritta «Mi fermo…» finché `scan` non restituisce (fuori dal main è questione di un file). Poi arriva `finishJob` con esito «interrotto da te».
- «Interrompi» della **card di Diagnostica** durante il passo 2 chiama lo stesso `cancelIndexing()` e produce **lo stesso esito**: un comando, un significato, qualunque finestra lo mandi.
- **Uscita dall'app** durante il passo 2: la conferma chiama `stop()`, cioè ferma la lettura, poi `terminate`. Il `JobSummary` è già salvato; nessuna notifica (com'è oggi per ogni uscita a job in corso).
- **Smontaggio di un volume** durante il passo 2: l'osservatore esistente (`stopIndexingForVolumeChange`) ferma la lettura come oggi; l'esito dice che si è fermata per un disco scollegato (vedi D6), non «hai fermato tu».

Caso limite, non nuovo: «Interrompi» premuto nell'istante fra la fine della copia e il `MainActor.run` che la registra. Oggi finisce come «Interrotto dall'utente» e non parte nessuna lettura; resta così (il `guard !wasStopped` esistente lo copre).

### D4 — Il passo 2 riusa la lettura che c'è, senza passare dal gate dei comandi manuali

`rebuildLibraryIndex` oggi comincia con `LibraryIndexCommandGate.disabledReason(isIndexing:jobIsRunning: isRunning, …)`: **durante il passo 2 `isRunning` è vero per scelta (D1), quindi rifiuterebbe** (in silenzio, perché senza `onAlert`). Serve separare «posso partire?» da «parti»:

- nuovo `private func startLibraryIndexScan(full:onFinish:) -> ListScanStartFailure?`: contiene **tutto** quello che oggi `rebuildLibraryIndex` fa **dopo** il gate — apertura dello store, accesso all'SSD, controllo della radice del volume, `isIndexing = true`, `indexInterruptedByUser = false`, `indexProgress = Progress()`, `indexer = idx`, il `Task.detached` con `scan`, gli aggiornamenti `indexProgress`/`indexedFileCount`, e nel finale `stopAccessing`, `isIndexing = false`, `indexer = nil`. In più, nel finale, chiama `onFinish(progress, error)` sul MainActor. Invece di mostrare gli avvisi restituisce **il motivo** per cui non è partita (`storeUnavailable`, `ssdUnavailable`, `notVolumeRoot`), e passa l'errore di `scan` a `onFinish` invece di mostrarlo.
- `rebuildLibraryIndex(full:onAlert:)` diventa: gate come oggi → `startLibraryIndexScan(full:onFinish:)` → se restituisce un motivo, mostra **lo stesso avviso di oggi**, stesso testo, via `showIndexAlert`; `onFinish` mostra «Il controllo si è fermato» se `scan` ha lanciato, come oggi. **Il comportamento manuale da Diagnostica non cambia di una virgola.**
- il passo 2 chiama `startLibraryIndexScan(full: false, onFinish:)` dopo il proprio controllo (`BackupListStep.shouldRun`), e **non mostra mai un avviso**: qualunque cosa vada storta diventa l'esito del passo, scritto nel riepilogo finale. È «normale amministrazione»: un'operazione automatica non fa comparire finestre.

Garanzie del fix di isolamento, mantenute tutte:

- la lettura resta nello **stesso** `Task.detached` su `LibraryIndexer` `nonisolated`: nessuna riga di `scan` torna sul main, nessuna funzione diventa `async`, i `MainThreadIsolationTests` restano validi così come sono;
- **una sola istanza** di store e di indexer (`libraryIndexStore`, `indexer`): la regola SIGSEGV di #31 non si tocca;
- `JobStartGate` **resta** e resta necessario: protegge il caso della lettura **manuale** da Diagnostica (lì `isRunning` è falso e i pulsanti sono attivi). Durante il passo 2 non viene mai raggiunto, perché i pulsanti sono disattivati prima;
- `CancelFlag` di `FileSyncer`/`S3Syncer` non è coinvolto; la lettura usa il proprio flag con lock, che `cancelIndexing()` già usa. Un cancel arrivato prima che `scan` parta è rispettato (`testCancelBeforeScan_isHonored`).

### D5 — L'avanzamento del passo 2: il numero che il mockup chiede

**In `LibraryIndexer.scan`** (cambiamento additivo, due righe di sostanza):

1. **Avanzamento anche sui file invariati.** Parametro nuovo `progressEvery: Int = 250`: subito dopo `progress.scanned += 1`, se `progressEvery > 0 && progress.scanned % progressEvery == 0` si chiama `onProgress(progress)`. Non si scrive niente, non si interroga lo store, non cambia nessuna decisione. Con il default a 250 e i test esistenti tutti sotto i 250 file, **nessun test esistente vede una chiamata in più** (va verificato con `grep`, piano Task 2). Con 47.000 file sono circa 190 aggiornamenti, uno ogni mezzo secondo-un secondo a lettura veloce.
2. **`progress.total` parte da `knownKeys.count`**, non da 0: è il numero di voci nell'elenco in quel momento, cioè esattamente quello che `total` dichiara di essere. Toglie il lampo «0 foto» nella card appena gli avanzamenti arrivano prima del primo blocco. I punti in cui oggi `total` si ricalcola con `store.count()` restano tutti.

**La percentuale.** Il totale dei file da controllare non è noto prima di finire la lettura. Raccomandazione: **stima = voci nell'elenco prima del passo 2 + file nuovi copiati dal passo 1** (`indexedFileCount + stats.copied + stats.copiedUnverified`).

- è lo stesso tipo di numero di `scanned` (foto e video indicizzabili, esclusioni comprese: `scanned` conta solo i file che `IndexableKind` accetta);
- sovrastima un po' se fra i copiati ci sono file che non sono foto né video: la barra si ferma sotto il 100% e poi salta alla fine — il verso innocuo;
- se `scanned` supera la stima (file aggiunti da fuori), il totale mostrato diventa `scanned`: mai «50.100 / 48.000»;
- **mai 100% finché la lettura non è finita**: la percentuale in corsa è limitata a 99. Il 100% lo scrive solo `finishJob`.

Funzione pura `BackupListStep.progress(scanned:estimate:) -> (percent: Int, shownTotal: Int)`.

Alternativa scartata: una prima passata di solo conteggio dei file. Costa una seconda traversata dell'SSD (su exFAT/FSKit la traversata è la parte lenta quando i file sono invariati) per rendere esatto un numero che serve solo a una barra.

**Dove va il numero.** In una proprietà propria del runner, **mai dentro `stats`**: `stats` resta il riepilogo delle foto del passo 1, e il riepilogo finale lo mostra intatto. Il runner espone `displayPercent` (la percentuale del passo 2 durante il passo 2, `stats.percent` altrimenti), letto **da tutti** quelli che oggi leggono `stats.percent` per disegnare avanzamento: barra della finestra, `PhaseIndicator`, badge del Dock. Un solo numero, in un posto solo.

Badge del Dock: al passaggio al passo 2 scende da 100% a pochi punti. Raccomandazione: accettarlo — è lo stesso numero della barra, e la finestra dice «passo 2 di 2». L'alternativa (una percentuale complessiva pesata) richiede di sapere quanto durerà il passo 2 rispetto al passo 1, che non sappiamo.

### D6 — Gli esiti del passo 2 e dove si leggono

Funzione pura `BackupListStep.outcome(progress:interruptedByUser:startFailure:scanFailed:) -> Outcome`, con precedenze in quest'ordine:

| Esito | Quando | Riga nel riepilogo (bozza, tono) |
| :--- | :--- | :--- |
| `couldNotUpdate` | non è partita (store, SSD, radice) o `scan` ha lanciato | «Non è stato possibile aggiornare l'elenco delle foto sull'SSD. Le foto sono state copiate lo stesso: l'app riproverà al prossimo backup.» (avviso) |
| `stoppedByYou` | `interruptedByUser` | «Hai fermato l'aggiornamento dell'elenco delle foto sull'SSD. Le foto sono state copiate lo stesso: l'elenco si rimetterà in pari al prossimo backup.» (informazione) |
| `ssdDisconnected` | `progress.volumeVanished` | «L'SSD è stato scollegato prima che l'elenco delle foto fosse aggiornato. Le foto erano già state copiate: l'elenco si rimetterà in pari al prossimo backup.» (avviso) |
| `stoppedByAnotherDisk` | `progress.cancelled` senza le due sopra (smontaggio di un altro volume: l'osservatore non filtra per volume, per scelta di #31) | «L'aggiornamento dell'elenco delle foto si è fermato perché è stato scollegato un disco. Le foto erano già state copiate: l'elenco si rimetterà in pari al prossimo backup.» (avviso) |
| `updatedWithRemarks` | la card di Diagnostica mostrerebbe almeno una riga di avviso: `LibraryIndexStatus.lines(for: p, interruptedByUser: false).contains { $0.tone == .warning }` | «Elenco delle foto sull'SSD aggiornato, ma qualcosa non torna: trovi i dettagli in Diagnostica, alla voce «Foto già salvate sull'SSD».» (avviso) |
| `updated` | tutto il resto | «Elenco delle foto sull'SSD aggiornato.» (ok) |

`updatedWithRemarks` **non ridice** le dieci righe della card: le rimanda lì. Riusare `LibraryIndexStatus.lines` come criterio tiene **una sola** definizione di «qualcosa non torna»: se domani la card cambia idea su un caso, cambia anche il riepilogo. Il titolo della card oggi è un letterale in `LibraryIndexCard` (`GroupBox("Foto già salvate sull'SSD")`) e compare già in un altro messaggio: diventa `LibraryIndexCommands.cardTitle`, usato da tutti e tre i punti.

Dove compare:

- **CompletionSheet**: titolo e icona **come oggi** («Backup completato», verde — il job è `.success`). Sotto le righe esistenti, **una** riga in più con il testo e il tono dell'esito. Solo se c'è stato un passo 2 (`listOutcome != nil`). L'esito viaggia in un campo nuovo di `JobStats`, `listStepOutcome: BackupListStep.Outcome? = nil`, **non persistito** (`JobStats` non è `Codable`), che nessun conteggio legge: i numeri del passo 1 restano quelli della copia.
- **Notifica**: stesso titolo e stesso corpo di oggi («Copiati N · Skippati M · Errori E»), più ` · Elenco delle foto non aggiornato` quando l'esito non è `updated`/`updatedWithRemarks`. Parte da `finishJob`, cioè una volta sola, alla fine.
- **Log** (`output`): una riga `STATUS:` all'inizio del passo 2 e una con il testo dell'esito alla fine, così «Report Log» racconta anche il passo 2.
- **`JobHistoryStore`**: niente (D2).
- **Card di Diagnostica**: invariata, mostra la lettura come una qualsiasi.

### D7 — Cosa si vede durante il passo 2

`StatsPanel` riceve una presentazione opzionale del passo 2 (`BackupListStep.Presentation`, valore puro calcolato dal runner). Quando c'è:

- la riga «miniatura + stato» è sostituita dalle due righe dei passi: «✓ Foto copiate (0 nuove, 18.399 già presenti)» e «◐ Aggiorno l'elenco delle foto sull'SSD…». «nuove» = `copied + copiedUnverified`, «già presenti» = `skipped + duplicatesSkipped`; se `errors + hashErrors > 0` la prima riga lo dice («… , 3 non copiate per errore») e non porta la spunta verde. Plurali concordati («1 nuova», «1 già presente»);
- il blocco «Avanzamento» mostra `displayPercent` e, al posto di «done / total file», «48.300 / 78.000 file controllati»; la velocità mostra «—»;
- le tessere Copiati / Skippati / Errori restano quelle del passo 1, ferme; «Trascorso» continua a correre (il timer non si ferma più a fine copia ma a fine job); «ETA» «—»;
- intestazione (`PhaseIndicator`): «MAC -> SSD — passo 2 di 2». Serve un titolo esplicito accanto a `phase`: **non** si scrive il suffisso dentro `phase`, perché `stop()` usa `phase.label` come etichetta del `JobSummary` e la sporcherebbe.

Il pulsante «Interrompi» è **quello di oggi** nella barra in alto della finestra (il mockup lo disegna in basso a destra per chiarezza, non chiede un secondo pulsante). Il grafico della velocità resta fermo sul passo 1: fuori scope.

Tutti i testi stanno in `BackupListStep` (logica pura, testata), nessuno nella View. Registro anti-gergo: nessuna di «indice», «hash», «sha», «scansione», «sqlite», «mtime», «cache», «entry», «traversata», «incrementale» — la stessa lista di `LibraryIndexStatusTests`.

### D8 — L'importazione: stesso trattamento

Raccomandazione: **sì, identica.** `runImport` passa già `refreshesLibraryIndex: true` e quindi passa dalla stessa strada senza codice in più; l'importazione è anzi il consumatore dell'elenco (dedup per contenuto): che sia in pari a fine import conta più che dopo un MAC → SSD. Il wizard si chiude all'avvio del job, quindi non c'è una seconda interfaccia da allineare. Intestazione «Importa: <etichetta> — passo 2 di 2», stessa riga «Foto copiate (…)», dove «già presenti» include le foto riconosciute come già in libreria (`duplicatesSkipped`).

SSD → HDD e SSD → Cubbit restano senza passo 2 (sull'SSD leggono soltanto: `refreshesLibraryIndex` resta falso).

### D9 — Aggiornamento manuale da Diagnostica

**Resta separato, com'è oggi**: non è un backup, non tocca `phase`, i pulsanti di backup restano attivi, e se Enrico ne preme uno risponde `JobStartGate` con il suo avviso (risposta 1(a) della spec precedente). È un'azione che Enrico avvia apposta, in una finestra che mostra la barra e «Interrompi»: lì l'avviso è comprensibile. Portare anche questo dentro la finestra principale come «job» è possibile ma è un'altra decisione, fuori da questa spec.

### D10 — Il collegamento dell'SSD

Oggi `onChange(of: volumes.ssdMounted)`: se il backup automatico è acceso parte `runMacToSSD()` (che con questa spec include il passo 2: niente da cambiare), **altrimenti** parte `autoRefreshLibraryIndexIfEnabled()`, cioè una lettura **da sola**, fuori da qualsiasi backup. È l'unico caso che resterebbe dell'attività separata che Enrico vuole togliere: con il backup automatico spento, collegare l'SSD e premere MAC → SSD entro qualche minuto riproduce esattamente l'avviso «Meglio non farlo adesso».

**Domanda aperta 1 (raccomandazione: b).**

| Opzione | Effetto | Costo |
| :--- | :--- | :--- |
| a. lasciarlo | nessun cambiamento | resta un caso (backup automatico spento) con l'avviso; `LibraryIndexAutoRefresh.shouldRun` e `autoRefreshLibraryIndexIfEnabled` restano per questo solo uso |
| **b. toglierlo** | al collegamento parte solo il backup automatico (se acceso); l'elenco si aggiorna **solo** come ultimo passo di un backup o di un'importazione, o a mano da Diagnostica | se l'SSD viene modificato fuori dall'app (Finder, un altro Mac) l'elenco resta indietro fino al prossimo backup. Innocuo: una voce in più si ricontrolla sempre prima di saltare un file (ADR-0003), una voce in meno fa solo ricopiare un doppione in un'importazione. Il pannello Doppioni aggiorna già l'elenco da sé quando sposta nel Cestino |
| c. lettura automatica che si fa da parte | se Enrico preme un backup mentre la lettura automatica gira, la lettura si ferma e il backup parte (e la rifarà come passo 2) | l'avvio del job deve **aspettare** che `scan` si fermi prima di scrivere sull'SSD: uno stato «in attesa di partire» nuovo, con le sue corse. Molto codice per un caso che (b) elimina |

Con (b) cambia anche il testo dell'interruttore in Impostazioni, che oggi promette «Quando colleghi l'SSD, o appena finisce una copia…» (e «un'occhiata veloce solo alle foto nuove», impreciso: la lettura passa **ogni** file, rilegge per intero solo quelli nuovi o cambiati). Bozza: «**Aggiorna l'elenco delle foto alla fine di ogni backup**» / «Dopo ogni copia verso l'SSD l'app controlla le foto che ci sono e aggiunge all'elenco quelle nuove: è l'ultimo passo del backup, e puoi fermarlo con «Interrompi». La prima creazione dell'elenco resta manuale, da Diagnostica: quella dura diversi minuti.» La chiave `UserDefaults` (`autoRefreshLibraryIndex`) **non cambia**: nessuna migrazione, l'interruttore di Enrico resta dove l'ha lasciato.

## Cosa NON cambia

- **Regola assoluta invariata.** Nessuna riga nuova chiama `removeItem`, `trashItem`, `copyItem`, `moveItem`, o fa richieste S3. Il passo 2 legge l'SSD e scrive solo nel file SQLite dell'elenco sul disco interno (`~/Library/Application Support/AppBackupFoto/`), come la lettura di oggi.
- Nessuno schema SQLite, nessun formato su disco, nessuna chiave `UserDefaults` nuova o rinominata. `JobSummary` identico.
- `LibraryIndexer.scan`: stesse decisioni, stesse rimozioni, stesse difese (`errorHandler`, `st_dev`, traversata incompleta, guardia di plausibilità). Cambiano solo **quante volte** chiama `onProgress` e il valore iniziale di `total`.
- La lettura manuale da Diagnostica, i suoi avvisi e i suoi gate: identici.
- SSD → HDD, SSD → Cubbit, ripristino, pannello Doppioni: identici.

## Test (logica pura, nello stile della suite)

File nuovo `AppBackupFotoTests/BackupListStepTests.swift` (4 punti in `project.pbxproj`), circa 26 test:

- `shouldRun`: niente passo 2 se il job non scrive sull'SSD, se l'interruttore è spento, se l'elenco è vuoto (prima creazione mai automatica), se c'è già una lettura, se c'è uno spostamento nel Cestino; sì quando tutto è in ordine (6).
- stima e percentuale: stima = elenco + copiati + non verificati; percentuale mai 100 in corsa; `scanned > stima` ⇒ totale mostrato = `scanned`; stima 0 ⇒ 0% senza divisione per zero (5).
- esiti: uno per riga della tabella D6, più le due precedenze che contano (fermato da te **e** SSD scollegato ⇒ «fermato da te»; `updatedWithRemarks` segue **esattamente** le righe di avviso di `LibraryIndexStatus`, verificato su un `Progress` con una sola riga `fuso`, che è informativa, ⇒ `updated`) (8).
- testi: riga «Foto copiate» con plurali, con errori, con doppioni d'importazione; intestazione «passo 1 di 2» / «passo 2 di 2» / senza passo; notifica con e senza «Elenco delle foto non aggiornato»; registro anti-gergo su **ogni** testo prodotto, da una lista di casi condivisa (come `LibraryIndexStatusTests`) (7).

In `LibraryIndexerTests`, 3 test: una lettura di 600 file **tutti invariati** con `progressEvery: 100` riporta almeno 5 avanzamenti con `scanned` crescente (il mutante «togliere l'emissione» muore); il primo avanzamento di una seconda lettura riporta `total` = voci già in elenco (muore il mutante «`total` da 0»); con `progressEvery: 0` nessun avanzamento intermedio.

Se Enrico sceglie (b) in D10: `LibraryIndexAutoRefresh.shouldRun` e i suoi 6 test in `LibraryIndexStatusTests` vengono rimossi (la condizione vive in `BackupListStep.shouldRun`); il test sull'interruttore (`testAutoRefreshSwitch_isOnUntilTheUserTurnsItOff`) resta. Il saldo dei test va dichiarato nel commit, non scoperto.

**Numeri nei test**: le righe usano `n.formatted()` (separatore delle migliaia della lingua del sistema). I test usano numeri sotto 1.000, oppure costruiscono l'atteso con lo stesso `formatted()`: mai «18.399» scritto a mano.

**Non coperto, dichiarato**: il cablaggio in `BackupRunner` (`finishCopyStep`, `finishJob`, `stop()` nel passo 2, `startLibraryIndexScan`), `StatsPanel`, `PhaseIndicator`, badge del Dock, `onChange(of: ssdMounted)`. Sono SwiftUI e bookmark veri: li copre la verifica sull'app reale. È testato tutto ciò che sta ai due capi del cablaggio.

## Verifica sull'app reale (con Enrico)

1. MAC → SSD con l'interruttore acceso: intestazione «passo 1 di 2», poi «passo 2 di 2» con le due righe; la barra **si muove** durante il passo 2 e il conteggio «… file controllati» cresce; i pulsanti di backup sono grigi; nessun avviso compare; il riepilogo e la notifica arrivano **una volta sola**, alla fine, con «Elenco delle foto sull'SSD aggiornato».
2. Un secondo MAC → SSD, «Interrompi» durante il passo 2: «Mi fermo…», poi «Backup completato» verde con la riga «Hai fermato l'aggiornamento…»; in Diagnostica la card dice «Hai fermato tu il controllo»; in Revisione l'ultimo job è riuscito.
3. Con `sample <pid>` durante il passo 2: main thread fermo nel run loop, `LibraryIndexer.scan` su un altro thread (stesso criterio del Task 9 del piano precedente). Annotare la **durata** del passo 2: è il costo che Enrico accetta al punto D1.
4. Interruttore spento: nessun «passo», riepilogo come prima di questa spec.
5. Solo se Enrico sceglie (b): collegare l'SSD con il backup automatico spento non fa partire niente.

## Rischi

1. **Il backup dura di più, per come lo vede Enrico.** È voluto, ma cambia un'abitudine: SSD → HDD subito dopo MAC → SSD aspetta il passo 2 (o «Interrompi»). La durata fuori dal main non è ancora misurata.
2. **`scan` è il codice più testato e più delicato del progetto.** Il cambiamento è additivo e non tocca nessuna decisione, ma una chiamata in più a `onProgress` è anche un punto in più in cui un chiamante può fare `cancel()` (i test di #31 lo fanno di proposito). Mitigazione: default 250 sopra la dimensione di ogni test esistente, test nuovi dedicati, mutation testing sulle due righe.
3. **Un passo 2 che non finisce tiene il backup «in corso».** Se `scan` restasse bloccata in una lettura su un disco morto, oggi resterebbe bloccata solo la lettura; con questa spec anche i pulsanti di backup restano grigi e il riepilogo non arriva. «Interrompi» funziona solo quando `scan` torna a controllare il flag (fra un file e l'altro). Non è un caso nuovo per la lettura, lo è per il job. Da osservare, non da risolvere a priori.
4. **Il `JobSummary` salvato prima della fine del job.** Durante il passo 2 il pannello Revisione mostra già l'ultimo job come riuscito, mentre la finestra dice «in corso». È coerente (le foto sono copiate) ma è la prima volta che le due cose divergono per qualche minuto.
5. **Conflitto con il piano «volume-space-indicator»** (bozza dello stesso giorno, tocca `S3Syncer` e la barra laterale): nessuna sovrapposizione di funzioni trovata, ma entrambi toccano la zona dei pulsanti della barra laterale. Chi arriva secondo fa il rebase. Numero dell'ADR: il primo libero al momento della scrittura.

## Bozza di ADR (da scrivere in `Docs/adr/` solo dopo l'approvazione, Task 0 del piano)

**Titolo:** `NNNN-l-aggiornamento-dell-elenco-e-l-ultimo-passo-del-backup.md`

**Contesto.** Dopo ogni MAC → SSD e ogni importazione l'elenco delle foto già salvate va rimesso in pari, perché il job ha scritto sull'SSD. Fino al 2026-09-19 lo faceva una lettura avviata *dopo* la fine del job: il backup risultava finito, i pulsanti tornavano attivi, e premerli produceva un avviso che rimandava a un'altra finestra. Una lettura che l'utente non ha chiesto si presentava come un ostacolo.

**Opzioni valutate.** (A) la lettura come ultimo passo del job, che resta «in corso» fino alla fine; (B) un terzo stato «backup finito ma elenco in aggiornamento» controllato da ogni pulsante; (C) lasciare la lettura separata e disattivare i pulsanti durante `isIndexing` con il motivo scritto. Per «Interrompi» durante il passo: esito «completato con nota», «interrotto», «completato senza nota».

**Decisione e motivo.** (A), con «Interrompi» ⇒ «Backup completato» più una riga che dice che l'elenco non è stato aggiornato. Il job che resta `.running` riusa tutti i controlli che già leggono `isRunning`; (B) li avrebbe dovuti toccare tutti, e il primo dimenticato riapre il problema. «Completato» perché le foto sono copiate e verificate: dire «interrotto» o «fallito» insegnerebbe a diffidare di un backup riuscito. **Cosa si accetta di perdere**: dopo un MAC → SSD gli altri backup aspettano la fine della lettura (o «Interrompi»); il registro dell'ultimo job non dice se l'elenco è stato aggiornato (lo dice la card in Diagnostica). **Per riaprire la decisione** serve un argomento nuovo: per esempio una lettura così lenta da rendere il passo 2 più lungo della copia nella maggior parte dei backup.

**Conseguenze.** `BackupRunner.run` finisce in due tempi (`finishCopyStep`, `finishJob`); il `JobSummary` si salva alla fine del passo 1. La lettura ha due ingressi — il passo 2, silenzioso, e il comando manuale da Diagnostica, con i suoi avvisi — sopra un'unica `startLibraryIndexScan`. `LibraryIndexer.scan` emette avanzamento anche sui file invariati. [Se (b) in D10:] al collegamento dell'SSD non parte più nessuna lettura da sola.

## Domande aperte per Enrico — CHIUSE (2026-09-19)

1. **Collegamento dell'SSD con il backup automatico spento (D10).** **Decisione: (b)** — non parte più nessuna lettura da sola; l'elenco si aggiorna alla fine di ogni backup o importazione, o a mano da Diagnostica.
2. **«Interrompi» durante il passo 2 (D3).** **Decisione: «Backup completato» con la riga «Hai fermato l'aggiornamento dell'elenco…»**, non «interrotto».
3. **«passo 1 di 2» durante la copia (D2).** **Decisione: sì**, per non far comparire il passo 2 a sorpresa quando la barra è già al 100%.

Tutto il resto (importazione allo stesso modo, `JobSummary` senza campi nuovi, stima della percentuale, badge del Dock che segue la barra, Diagnostica separata) è raccomandato sopra e resta come scritto: nessuna obiezione in review.
