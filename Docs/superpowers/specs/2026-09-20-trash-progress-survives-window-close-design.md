# Lo spostamento nel Cestino non perde barra e «Interrompi» se si chiude la finestra — ROADMAP #41

**Stato: BOZZA — in attesa di approvazione di Enrico.** Nessuna riga di codice scritta. Piano collegato: `Docs/superpowers/plans/2026-09-20-trash-progress-survives-window-close.md`.

**Base:** `main` **dopo** il merge di `fix/remaining-main-thread-work`. Il codice citato qui è stato letto a `2e63dc4` (ultimo commit di quel branch); i nomi valgono, i numeri di riga no — si cerca con `grep -n`.

| Punto | Cosa | Priorità |
| :--- | :--- | :--- |
| **#41** | Lo spostamento nel Cestino perde barra e «Interrompi» se si chiude e riapre la finestra Doppioni | **alta** — è l'unica operazione che toglie file dalla loro posizione (ADR-0005), e l'utente non può più fermarla |

**Questo intervento non sceglie niente di nuovo.** La stessa forma di difetto è stata risolta due giorni fa per «Annulla l'ultimo spostamento» (#34, ADR-0009): lo stato dell'operazione è uscito dagli `@State` di `DuplicatesView` ed è andato in `BackupRunner`. Qui si applica **quella** soluzione allo spostamento, non una seconda. Il progetto ha già pagato tre volte la duplicazione della stessa decisione (`LibraryExclusions`, `realResolvedPath`, `makeThumbnail`): una seconda orchestrazione, scritta con nomi diversi, sarebbe la quarta.

Regole che valgono per tutto l'intervento (da `Docs/CLAUDE.md` e `.claude/rules/architecture.md`):

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` resta (ADR-0006). **Questo intervento non introduce nessun tipo nuovo `nonisolated`**: sposta stato e orchestrazione fra due tipi che sono già entrambi `@MainActor` (`BackupRunner`, `DuplicatesView`) e non tocca il motore di fondo. Se comparisse un warning di isolamento, è il segnale che qualcosa è stato spostato dalla parte sbagliata: fermarsi e rimandare all'Architect, non annotare `nonisolated` per tentativi.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in Debug: la build resta a zero warning.
- Zero delete, zero overwrite. **Nessun diff di questo intervento aggiunge o sposta una chiamata a `trashItem`, `removeItem`, `copyItem`, `moveItem` o `createDirectory`.** `DuplicateTrasher.run` **non cambia di una riga**: cambia solo *chi* lo chiama e *dove* finisce il suo esito.
- Testi a schermo solo in tipi puri (`DuplicatesStatus`), mai costruiti nella View. Niente gergo: niente «hash», «indice», «registro», «scansione», «entry», «cache».

---

## 1. Cosa c'è oggi — letto nel codice, non dedotto

`DuplicatesView.startTrashing(_:)` è l'unico punto che avvia `DuplicateTrasher.run`. Fa, nell'ordine: rivaluta `trashDisabledReasonNow`; risolve `runner.libraryIndexStore` / `runner.trashManifestStore` / `BookmarkManager.shared.urls[.ssd]`; chiama `runner.beginDuplicateTrashing()`; costruisce le `Decision` dal blocco congelato; crea un `CancelFlag`; azzera `lastOutcome` e `runner.lastTrashRestoreOutcome`; imposta `trashProgress = (0, decisions.count)`; lancia un `Task.detached` che al termine, in un solo `MainActor.run`, chiama `runner.endDuplicateTrashing()`, azzera progresso e flag, pubblica l'esito, svuota la selezione, ricarica l'elenco e ricalcola `restorableBatch`.

Tre di quei valori sono `@State` **della view**:

```swift
@State private var trashProgress: (done: Int, total: Int)? = nil
@State private var activeCancelFlag: CancelFlag? = nil
@State private var lastOutcome: DuplicateTrashOutcome? = nil
```

Fatti che la spec deve correggere o preservare:

1. **La barra è condizionata a due cose, e solo una sopravvive alla finestra.** Il `body` mostra la barra se `runner.isTrashingDuplicates && trashProgress != nil`. Chiudendo la finestra la view viene distrutta e i suoi `@State` con lei; riaprendola, `isTrashingDuplicates` è ancora `true` (vive nel runner — l'ha spostato lì il Task 4 del pannello Doppioni, proprio per questo motivo) ma `trashProgress` riparte da `nil`: **barra assente, bottone «Interrompi» assente**.
2. **«Interrompi» non è solo invisibile, è irrecuperabile.** Il `CancelFlag` vivo è tenuto dal solo `activeCancelFlag`; la finestra chiusa lo porta via. L'unica referenza rimasta è la cattura dentro il `Task.detached`, che nessuno può raggiungere. Da quel momento lo spostamento non si può più fermare, e riaprire la finestra non lo rimedia: non c'è nessun percorso che riagganci il flag. Un blocco può arrivare a 500 file / 50 GB, e ogni file viene riletto e rihashato prima di essere spostato.
3. **Il lavoro, però, finisce bene.** `Task.detached` è non strutturato e non muore con la view; `runner` è un riferimento a un oggetto vivo, quindi `endDuplicateTrashing()` viene comunque chiamato e il flag non resta bloccato a `true`. **Non è un difetto di sicurezza dei dati**: le foto vengono spostate e registrate esattamente come sempre. È un difetto di controllo e di visibilità — il che, sull'unica operazione che toglie file dalla loro posizione, è abbastanza.
4. **L'esito si perde.** `lastOutcome` è la sola fonte delle righe di `DuplicatesStatus.outcomeLines`. Se la finestra era chiusa quando l'operazione è finita, riaprendola non c'è **niente** che dica com'è andata: né quanti file sono stati spostati, né quali gruppi sono stati saltati e perché, né l'avvertenza sull'elenco. Il registro su disco c'è, ma non è raccontato da nessuna parte nella UI.
5. **Due scritture su stato morto e una query inutile.** Il blocco finale del `Task.detached` scrive `trashProgress`, `lastOutcome`, `selectedHashes`, `pendingBatch` in `@State` non più installati (SwiftUI lo tollera e lo segnala a runtime, non è un crash) e chiama `loadGroups()`, che lancia un `duplicateGroups()` sulla coda dello store più un `DuplicateBatch(groups:)` completo — il percorso pesante misurato il 2026-09-02 — per pubblicarlo in una view che non esiste più.
6. **Cosa fa la finestra riaperta a metà spostamento, oggi.** `.task` vede `loadState == .idle` e chiama `loadGroups()`: si rilegge l'intero elenco dei doppioni **mentre il trasher sta rimuovendo chiavi dallo stesso store** e sta leggendo e rihashando file sullo stesso volume. La coda seriale dello store rende l'operazione sicura, non utile: il risultato è già vecchio quando compare. Nel frattempo `headerLine` viene disegnata con `loadedBatch == nil`, cioè `groupCount == 0`, e `DuplicatesStatus.headerLine(indexBuilt: true, groupCount: 0, …)` restituisce **«non ci sono copie doppie da smaltire sull'SSD»** — falso, e falso proprio mentre l'app ne sta smaltendo centinaia. Oggi è un transitorio di pochi secondi a ogni apertura; con la decisione D4 di questa spec diventerebbe permanente per tutta la durata dello spostamento, quindi va corretto qui.
7. **Il modello da copiare esiste già, finito e in produzione.** `BackupRunner` tiene `trashRestoreProgress`, `trashRestoreStopRequested`, `lastTrashRestoreOutcome`, `restorableBatch`, `trashRestoreCancelFlag` (privato), `startTrashRestore(onAlert:)`, `stopTrashRestore()`. Il doc-comment di quel blocco cita ROADMAP #41 per nome: «è esattamente il difetto già noto dello spostamento nel Cestino».
8. **La mutua esclusione non è in discussione.** `isTrashingDuplicates` è già nel runner ed è già letto da `JobStartGate.blockedReason`, `LibraryIndexCommandGate.disabledReason`, `DuplicatesStatus.trashDisabledReason`/`undoDisabledReason` e dalla guardia di `beginTrashRestore()`. Questo intervento **non cambia una virgola** di quel reticolo: cambia solo chi chiama `beginDuplicateTrashing()`.

---

## 2. Le decisioni

### D1 — Lo stato dell'operazione vive nel runner, con i nomi simmetrici a quelli di #34

`BackupRunner` guadagna, accanto al blocco dell'annullamento e con lo stesso doc-comment sul perché non sono `@State`:

```
@Published private(set) var duplicateTrashProgress: (done: Int, total: Int)? = nil
@Published private(set) var duplicateTrashStopRequested = false
@Published private(set) var lastDuplicateTrashOutcome: DuplicateTrashOutcome? = nil
private var duplicateTrashCancelFlag: CancelFlag? = nil

func startDuplicateTrashing(_ batch: DuplicateBatch, onAlert: @escaping (SimpleAlert) -> Void)
func stopDuplicateTrashing()
```

`DuplicatesView` perde `trashProgress`, `activeCancelFlag`, `lastOutcome` e il corpo di `startTrashing(_:)`, che si riduce a `runner.startDuplicateTrashing(batch, onAlert: { pendingAlert = $0 })` — esattamente come `startUndo()` oggi.

**Due proprietà di #34 si stringono a `private(set)`.** `trashRestoreProgress` e `lastTrashRestoreOutcome` sono oggi `@Published var` solo perché la view scrive `runner.lastTrashRestoreOutcome = nil` all'avvio di uno spostamento. Quella riga si sposta dentro il runner (D5), quindi non resta nessun scrittore esterno: si chiudono anche loro. È una stretta di una riga ciascuna, non un rifacimento.

**Perché `private(set)` e non `var`:** l'invariante «un `begin` riuscito è sempre seguito da un `end` nello stesso `MainActor.run` che pubblica l'esito» è verificabile leggendo una sola funzione solo se nessun altro può muovere quello stato.

### D2 — Le precondizioni si rivalutano dentro il runner, all'avvio vero

`startDuplicateTrashing` comincia con le due guardie di oggi, **nello stesso ordine**:

1. `DuplicatesStatus.trashDisabledReason(isRunning:isIndexing:ssdMounted:isTrashingDuplicates:isRestoringFromTrash:)` — il motivo **specifico**, quello che l'utente può usare;
2. `beginDuplicateTrashing()` — l'alert generico, ultima rete.

L'ordine non è estetico: invertirlo sostituirebbe «C'è un backup in corso: aspetta che finisca» con «C'è già un'altra operazione in corso», e il progetto ha una regola esplicita contro i motivi vaghi.

La rivalutazione **deve** restare all'avvio vero e non al click che apre il riepilogo: è il rilievo di review del 2026-09-01, già pagato due volte (qui e in `rebuildLibraryIndex`). Spostandola nel runner diventa più difficile perderla, perché sta nella stessa funzione che fa partire il `Task.detached`.

`ssdMounted` viene da `VolumeMonitor.shared.ssdMounted`, letto direttamente dal runner. **È una dipendenza nuova** (`BackupRunner` oggi non nomina `VolumeMonitor`): è una lettura di un `Bool` sul MainActor, nessun I/O — il polling sta sulla `probeQueue` — e una lettura dentro un metodo non crea nessuna sottoscrizione a `objectWillChange`, quindi non aggiunge ridisegni. L'alternativa (passare `ssdMounted:` come parametro dalla view) evita la dipendenza ma riporta la rivalutazione dove sta chi fa il click: scartata per lo stesso motivo del 2026-09-01. Vedi §8 domanda 3 per la sua coda.

### D3 — Cosa resta `@State` nella view, e la regola per decidere

Restano nella view: `loadState`, `loadedBatch`, `selectedHashes`, `pendingBatch`, `showSummarySheet`, `showDestructiveConfirm`, `showUndoConfirm`, `pendingAlert`, `thumbnailCache`.

La regola, scritta una volta e valida anche per la prossima finestra: **lo stato di un'operazione che sopravvive alla finestra vive nel runner; lo stato della conversazione con l'utente in quella finestra vive nella view.** Una selezione di checkbox, un riepilogo aperto, un alert in attesa di risposta non sopravvivono alla chiusura perché non devono: se l'utente chiude la finestra mentre sta decidendo, ricomincia a decidere.

**Il blocco congelato resta un `@State` della view e viaggia come parametro.** `pendingBatch` si congela in `beginConfirmation()` e la **stessa istanza** arriva a `startDuplicateTrashing(_:)`: l'invariante del Task 2/4 («fra il riepilogo e il cestinamento la scelta di quale copia tenere non cambia sotto i piedi dell'utente») è preservata parola per parola. Il runner riceve un `DuplicateBatch` già deciso e ne ricava le `Decision`; non ricalcola mai `duplicateKeepChoice`.

### D4 — Cosa vede la finestra riaperta a metà spostamento

Tre cose, nell'ordine in cui si leggono:

- **La riga che spiega**: `trashDisabledReasonNow` dice già «Uno spostamento nel Cestino è già in corso: aspetta che finisca». Invariata.
- **La barra e «Interrompi»**: tornano, perché ora vengono dal runner. È il punto di questo intervento.
- **L'elenco: non si ricarica finché lo spostamento non è finito.** `.task` chiama `loadGroups()` solo se `DuplicatesPanelLoad.shouldLoadOnAppear(isIdle:isTrashingDuplicates:isRestoringFromTrash:)` dice sì. Motivo: l'elenco letto a metà operazione è un bersaglio in movimento (il trasher sta togliendo chiavi dallo stesso store), è già vecchio quando compare, costa il percorso pesante del 2026-09-02 **mentre** il trasher legge e rihasha sullo stesso volume, e comunque non è utilizzabile (il bottone è disattivato con il motivo scritto). L'elenco arriva da solo quando l'operazione finisce, via `.onChange`.
- **L'intestazione non mente.** `DuplicatesStatus.headerLine` guadagna `groupsKnown: Bool`: a `false` restituisce una riga che dice che l'elenco non è ancora stato letto, mai «non ci sono copie doppie». È la stessa classe di errore già corretta con `sawNothing` in #31 — un elenco che non si conosce e un elenco vuoto sono due situazioni opposte — e oggi è già sbagliata per un transitorio a ogni apertura (§1.6).

**Quando la finestra resta aperta il comportamento non cambia**: `loadState` è già `.loaded`, la lista resta visibile per tutta la durata come oggi, e a fine operazione si ricarica come oggi.

### D5 — L'esito si vede anche se la finestra era chiusa, e quanto dura

`lastDuplicateTrashOutcome` vive nel runner, quindi le righe di `DuplicatesStatus.outcomeLines` compaiono riaprendo la finestra, anche molto dopo. È la stessa scelta già motivata nel doc-comment di `TrashRestoreStatus.outcomeLines`: «restano nel pannello (non un alert): così si vedono ancora riaprendo la finestra».

**Durata: in memoria, fino all'operazione successiva.** L'esito non è persistito su disco e non sopravvive alla chiusura dell'app. Non è una dimenticanza: il documento durevole di cosa è stato spostato è il registro (`TrashManifestStore`), e l'annullamento continua a leggere quello. Persistere anche il racconto significherebbe un secondo posto dove la stessa verità può divergere.

**Invalidazione reciproca, in entrambi i versi.** Oggi `startTrashing` azzera `runner.lastTrashRestoreOutcome` (un nuovo spostamento rende obsoleto il racconto di un annullamento), ma `startTrashRestore` **non** azzera l'esito dello spostamento — solo perché non poteva raggiungerlo, stando in un `@State`. Con entrambi nel runner la simmetria si chiude: `startDuplicateTrashing` azzera `lastTrashRestoreOutcome`, `startTrashRestore` azzera `lastDuplicateTrashOutcome`. Si legge sempre il racconto di una sola operazione, l'ultima.

### D6 — «Interrompi», e la riga che dice che ci si sta fermando

`stopDuplicateTrashing()` è idempotente come `stopTrashRestore()`: il secondo clic non fa niente (`guard !duplicateTrashStopRequested`). La barra mostra `DuplicatesStatus.trashStoppingLine` al posto del bottone appena la richiesta è partita.

Serve perché `DuplicateTrasher.run` controlla `isCancelled` **solo fra un gruppo e l'altro**, e un gruppo in corso può contenere file grandi da rileggere e rihashare: senza la riga, l'utente preme, non succede niente di visibile per secondi, e preme di nuovo. La frase non deve promettere l'immediato («Mi fermo dopo il gruppo in corso…», non «Interruzione in corso»).

È l'unico cambiamento **visibile** che questo intervento aggiunge oltre al ripristino della barra. Vale la pena dirlo esplicitamente perché non è una pura riorganizzazione.

### D7 — La cadenza del progresso non cambia: niente `ProgressThrottle`

`DuplicateTrasher.onProgress` scatta **una volta per gruppo**, non per file: anche nel caso peggiore misurato (~56 file/s per `trashItem`, con la rilettura di ogni membro prima) restano pochi aggiornamenti al secondo. ADR-0010 dirada la copia perché lì la cadenza misurata era ~575/s, e dice esplicitamente che le altre sorgenti «restano come sono». Aggiungere un throttle qui metterebbe un pezzo in più fra la misura e la UI senza un numero che lo giustifichi.

### D8 — Testi nuovi, tutti in `DuplicatesStatus`

Tre, tutti puri e testabili:

- `trashProgressLine(done:total:)` — oggi la stringa è costruita inline nel `body` («Sposto le copie nel Cestino: X di Y gruppi») ed è l'ultima riga di testo del pannello che non sta in un tipo puro. Si sposta, e **guadagna il plurale** (`count(total, "gruppo", "gruppi")`): oggi scrive «0 di 1 gruppi».
- `trashStoppingLine` — la riga di D6, gemella di `TrashRestoreStatus.stoppingLine`.
- `headerLine(indexBuilt:groupsKnown:groupCount:reclaimableBytes:)` — il parametro nuovo di D4, **senza default**, come tutti i parametri dei gate aggiunti in #34: un default farebbe compilare i chiamanti vecchi con il comportamento sbagliato, che è esattamente il modo in cui questa classe di bug sopravvive.

### D9 — Cosa non si tocca

- **`DuplicateTrasher.run`: zero righe cambiate.** Nemmeno la firma.
- **`TrashManifestStore`, `TrashedItem`, `TrashRestorer`, `RestoreOutcome`**: invariati.
- **Il reticolo della mutua esclusione** (`isTrashingDuplicates`/`isRestoringFromTrash`/`JobStartGate`/`LibraryIndexCommandGate`/`trashDisabledReason`/`undoDisabledReason`): invariato, nessun parametro nuovo, nessuna precedenza cambiata.
- **`beginDuplicateTrashing()`/`endDuplicateTrashing()`**: invariati, cambia solo il chiamante. L'invariante resta scritta e va ricontrollata in review: fra un `begin` riuscito e il `Task.detached` non ci deve essere nessun `return`, e `end` sta nello stesso `MainActor.run` che pubblica l'esito.
- **Nessuno schema SQLite, nessuna chiave `UserDefaults`, nessun formato su disco.** Questo intervento non scrive niente di nuovo da nessuna parte.

---

## 3. Test

Lo schema è quello di #34: si testa **tutto ciò che sta ai due capi del cablaggio**, e si dichiara ciò che non è raggiungibile senza una corsa reale.

**Coperto (logica pura, stile della suite — oggi 756 test):**

| Tipo | Cosa | File |
| :--- | :--- | :--- |
| `DuplicatesStatus.trashProgressLine` | numeri, ordine `done`/`total`, singolare/plurale, niente gergo | `DuplicatesStatusTests` |
| `DuplicatesStatus.trashStoppingLine` | non vuota, niente gergo, non promette l'immediato | `DuplicatesStatusTests` |
| `DuplicatesStatus.headerLine` | `groupsKnown == false` non produce mai la riga «non ci sono copie doppie»; con `groupsKnown == true` le tre diramazioni di oggi restano identiche | `DuplicatesStatusTests` |
| `DuplicatesPanelLoad.shouldLoadOnAppear` | le otto combinazioni di `isIdle`/`isTrashingDuplicates`/`isRestoringFromTrash` | `DuplicatesStatusTests` (stesso file: è lo stato dello stesso pannello) |

**Non coperto, dichiarato:** `BackupRunner.startDuplicateTrashing`/`stopDuplicateTrashing`, il corpo di `DuplicatesView` (barra, bottoni, `.task`, `.onChange`). Stessa ragione delle altre parti SwiftUI/bookmark di questo pannello, e stessa dichiarazione già fatta per `startTrashRestore` in #34: servono una finestra vera, un SSD vero e un blocco vero. Le verifiche corrispondenti sono in §4.

**Isolamento MainActor:** nessun test nuovo in `MainThreadIsolationTests`. Nessun tipo nuovo `nonisolated`, nessun tipo esistente cambia isolamento: il motore che gira fuori dal main (`DuplicateTrasher`) è già coperto lì e non viene toccato.

---

## 4. Verifiche dal vivo (Enrico, con l'SSD collegato — non le fa l'Implementer)

Servono un elenco costruito e almeno un gruppo di doppioni reale. **Un blocco piccolo basta per 1-2 e 5-6; per la 3 serve un blocco abbastanza grande da durare più della chiusura della finestra.**

1. **Barra e «Interrompi» sopravvivono.** Avvia uno spostamento, chiudi la finestra Doppioni, riaprila (Diagnostica → «Vedi le copie doppie…»): barra presente, numeri che avanzano, bottone «Interrompi» presente.
2. **«Interrompi» funziona dalla finestra riaperta.** Premilo: compare «Mi fermo dopo il gruppo in corso…», lo spostamento si ferma fra un gruppo e l'altro, e l'esito dice che ti sei fermato a metà con i numeri giusti.
3. **L'esito si vede anche a finestra chiusa.** Avvia uno spostamento, chiudi la finestra, aspetta che finisca, riapri: le righe dell'esito sono lì, l'elenco è ricaricato e nessun gruppo appena smaltito compare più, nessuna spunta è rimasta.
4. **Finestra sempre aperta: niente è cambiato.** Uno spostamento con la finestra aperta dall'inizio alla fine si comporta come prima — barra, esito, elenco ricaricato, spunte svuotate.
5. **L'intestazione non mente.** Con la finestra riaperta a metà spostamento, la riga in cima **non** deve dire «non ci sono copie doppie da smaltire».
6. **La mutua esclusione regge ancora.** Durante uno spostamento, prova «Annulla l'ultimo spostamento» (dalla stessa finestra) e un backup dalla finestra principale: entrambi rifiutati con il motivo di sempre.
7. *(facoltativa, da Xcode)* Con la finestra chiusa durante uno spostamento, la console non deve più mostrare avvisi SwiftUI di accesso a `State` fuori da una view installata.

---

## 5. Rischi

1. **Regressione sul percorso «finestra sempre aperta».** A fine operazione oggi la view ricarica l'elenco e svuota la selezione dentro lo stesso blocco finale; dopo lo spostamento nel runner quel compito passa a un `.onChange(of: runner.isTrashingDuplicates)`. Se quell'aggancio manca o viene scritto sul flag sbagliato, la finestra resta con l'elenco vecchio e le spunte di gruppi appena smaltiti — peggio di oggi. È il rischio principale dell'intervento; la verifica 4 esiste per questo.
2. **Il transitorio dell'intestazione.** `groupsKnown` va passato `false` in tutti gli stati in cui `loadedBatch` è `nil`, non solo durante uno spostamento, altrimenti si corregge il caso nuovo e si lascia quello vecchio.
3. **`DuplicateTrashOutcome` non è `Equatable`** (contiene un array di tuple): non si può fare la dedup di pubblicazione come per `restorableBatch`. Irrilevante — viene pubblicato una volta sola a fine operazione — ma non provare ad aggiungere un `guard … != …`: non compila e non serve.
4. **La nuova dipendenza `BackupRunner` → `VolumeMonitor.shared`** (D2). Piccola e sul MainActor, ma è una freccia nuova nel grafo: va scritta nel commento accanto alla lettura, perché il runner finora non conosceva i volumi.
5. **Due `.onChange` che chiamano `loadGroups()`** (uno per lo spostamento, uno per l'annullamento). Non possono scattare insieme — le due operazioni si escludono a vicenda — ma vanno lasciati separati e non fusi in un `if !isTrashing && !isRestoring`, che ricaricherebbe anche all'apertura.
6. **Firma di `headerLine` cambiata**: tocca chiamate esistenti in `DuplicatesStatusTests`. Adattare la chiamata è ammesso; **cambiare cosa asserisce un test esistente no** — se un'asserzione esistente «deve» cambiare, è un segnale da rimandare all'Architect.

---

## 6. Domande aperte per Enrico (con raccomandazione)

1. **ADR nuovo o nota in coda ad ADR-0009?** Qui non si decide niente di architetturale di nuovo: si applica una decisione già presa e già scritta. Un ADR-0011 che ripete ADR-0009 crea due posti dove leggere la stessa regola. **Raccomandazione: nessun ADR nuovo, una nota datata in coda ad ADR-0009** («2026-09-XX: lo stesso schema applicato allo spostamento nel Cestino, ROADMAP #41; il difetto che quel doc-comment citava è chiuso»), più le due scelte minori di questo intervento (elenco non ricaricato durante l'operazione, esito in memoria e non su disco) scritte in `.claude/rules/architecture.md`.
2. **Riaprendo la finestra a metà spostamento, l'elenco: non si ricarica (D4) o si ricarica comunque come oggi?** **Raccomandazione: non si ricarica** — è già vecchio quando compare, costa il percorso pesante proprio mentre il trasher lavora sullo stesso volume, e il bottone è comunque disattivato. Cosa si perde: chi riapre la finestra per «guardare la lista mentre aspetta» vede solo la barra e la riga che spiega, finché non finisce.
3. **Allineare anche `startTrashRestore` alla rivalutazione di D2?** Oggi «Annulla l'ultimo spostamento» ricontrolla all'avvio vero solo `beginTrashRestore()`, non `undoDisabledReason`: se l'SSD viene scollegato mentre la conferma è aperta, l'annullamento parte e si ferma da solo con un esito onesto (`TrashRestorer` legge `st_dev` prima di toccare qualunque cosa), ma è una frase più tortuosa di «L'SSD non è collegato». **Raccomandazione: sì, allinearlo** — sono tre righe, riusa una funzione già scritta e testata, e lascia le due operazioni gemelle con la stessa disciplina. Se preferisci lo scope stretto, resta fuori e va in ROADMAP come punto nuovo.

---

## 7. L'aggiornamento manuale dell'elenco da Diagnostica: verificato, il difetto **non** c'è

Richiesto esplicitamente. Letto nel codice a `2e63dc4`, non dedotto.

`LibraryIndexCard` **non ha nessun `@State`** per progresso, interruzione o esito. Tutto quello che serve sta già in `BackupRunner`: `isIndexing` e `indexProgress` (`@Published`), `indexInterruptedByUser`, l'istanza `indexer` per l'interruzione, `cancelIndexing()` e `stopIndexingForVolumeChange()`. La card legge `runner.indexProgress` per la barra, mostra il bottone `LibraryIndexCommands.stop` quando `runner.isIndexing`, e disegna le righe finali con `LibraryIndexStatus.lines(for:interruptedByUser:)` quando `!runner.isIndexing && runner.indexProgress != nil`.

Conseguenza: **chiudere e riaprire la finestra Diagnostica a metà lettura restituisce barra, «Interrompi» e — a lettura finita — le righe di esito.** `indexProgress` non viene azzerato alla fine (solo `resetLibraryIndex` lo fa), quindi l'esito sopravvive alla chiusura della finestra esattamente come si vuole che faccia quello dei doppioni dopo questo intervento. Nessun intervento necessario, nessun punto nuovo da aprire in ROADMAP.

**Una sola coda, adiacente e minore, che non è #41 e non si corregge qui:** se la lettura **fallisce con un errore** mentre la finestra Diagnostica è chiusa, l'avviso («Il controllo si è fermato…») viene consegnato a `onAlert`, cioè al `postAlert` della card, che scrive in un `@State` non più installato — l'avviso si perde. Le righe di esito compaiono comunque riaprendo (`indexProgress` conserva l'ultimo valore emesso), quindi l'utente non resta senza informazione, ma non vede il messaggio d'errore. Vale anche per gli altri avvisi di avvio, che però nascono da un click in una finestra viva e quindi non sono raggiungibili da questo caso. È un difetto della consegna degli avvisi (`AlertSink`), non dello stato dell'operazione: se lo si volesse chiudere, la strada è una coda di avvisi nel runner per finestra, che è un intervento di forma diversa da questo. **Segnalato, non corretto, non incluso.**
