# I punti dove l'interfaccia può ancora bloccarsi — «Annulla l'ultimo spostamento», progresso della copia, controllo dello spazio

**Stato: BOZZA — in attesa di approvazione di Enrico.** Nessuna riga di codice scritta. Piano collegato: `Docs/superpowers/plans/2026-09-19-remaining-main-thread-work.md`. Base: `main` @ `230097d`.

Tre punti della `Docs/ROADMAP.md`, capitolo «trovati lavorando al fix di isolamento MainActor»:

| Punto | Cosa | Priorità |
| :--- | :--- | :--- |
| **#34** | «Annulla l'ultimo spostamento» gira sul main thread | **alta** — è il percorso di ritorno dell'unica operazione distruttiva (ADR-0005) |
| **#37** | Troppi aggiornamenti di progresso durante la copia (main al ~100% in ridisegno) | media |
| **#39** | `hasSufficientSpace` legge la capacità del volume sul main | bassa |

**Fuori scope, deliberatamente**: #32 (upload Cubbit sul main) e #33 (campione d'integrità sul main) — da misurare prima con Enrico; #35 (apertura SQLite nel getter `lazy`) e #36 (lavoro lungo nel pool cooperativo) — accettati come sono. Questa spec non li tocca e non ne cambia le premesse.

Regole che valgono per tutto l'intervento (da `Docs/CLAUDE.md` e `.claude/rules/architecture.md`):

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` resta (ADR-0006). Ogni tipo nuovo chiamato da un lavoro di fondo è `nonisolated`, con **accanto** la riga che dice perché è sicuro. Nessuna funzione di fondo diventa `async` (caso D della tabella dei sei casi); se mai servisse, `@concurrent`.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in Debug: la build deve restare a zero warning.
- Zero delete, zero overwrite. Questo intervento **non aggiunge** nessuna chiamata a `trashItem`, `removeItem` o `copyItem`; l'unico `moveItem` sui file foto resta quello del ripristino dal Cestino, che esiste già.
- Mutation testing solo su una copia del repository nello scratchpad, mai sull'albero di lavoro di Enrico.

---

## 1. Cosa c'è oggi — letto nel codice, non dedotto

### #34 — `TrashManifestStore.restore` e il bottone «Annulla l'ultimo spostamento»

`DuplicatesView.undoLastBatch()` chiama `manifest.restore(manifest.lastBatch())` **in modo sincrono dal main thread** e mostra un `SimpleAlert` con l'esito. Per ogni voce `restore` fa, nell'ordine: `fileExists` sul file nel Cestino → `fileExists` sul percorso originale (zero-overwrite) → `sha256Measured` del file nel Cestino (dimensione e hash dallo stesso descrittore) → `createDirectory(withIntermediateDirectories:)` → `moveItem`.

Fatti che la spec deve correggere o preservare:

1. **Il costo non sono i `moveItem`, è la rilettura.** Sullo stesso volume `moveItem` è una rename (misurato per `trashItem`: ~56 file/s incluso il record). Il tempo lo prende `sha256Measured` di ogni file. Un blocco è limitato da `duplicateBatchFileCap = 500` file e `duplicateBatchByteCap = 50 GB` (la cifra «2.000» della ROADMAP è il tetto del **registro**, `TrashManifestStore.maxItems`, non di un blocco). Con la lettura+SHA256 misurata sull'SSD vero (fatto n. 17: 279-616 MiB/s), un blocco al tetto dei 50 GB costa **~80-180 secondi di main thread bloccato**: un beachball di minuti, sul gesto che l'utente fa quando qualcosa gli sembra andato storto.
2. **Il registro non ricorda i ripristini.** `restore` non modifica il registro: dopo un annullamento riuscito `lastBatch()` restituisce **lo stesso blocco**, il bottone resta attivo, e una seconda pressione produce N voci `missingInTrash` con la frase «probabilmente il Cestino è stato svuotato» — **falsa**: le foto sono al loro posto. Due test esistenti fissano questo comportamento: `testRestoringTwice_isNotAnError` (si aspetta `.missingInTrash` alla seconda volta) e `testRestore_doesNotDropTheOtherBatchesFromTheRegister` (si aspetta `itemCount == 2` dopo il ripristino di una voce).
3. **Nessun controllo `st_dev`.** Il fatto misurato n. 9 (`NSFileNoSuchFileError` indistinguibile dallo scollegamento) e il n. 2 (`fileExists` risponde `true` fino a ~2,2 s dopo uno smontaggio) valgono anche in questa direzione: con l'SSD scollegato prima o durante l'annullamento, ogni voce finisce in `missingInTrash` («Cestino svuotato») o in `alteredInTrash` (perché `sha256Measured` restituisce `nil` su un file illeggibile) — due frasi false, una delle quali dice all'utente che le sue foto sono perse. È la classe di bug che `Docs/CONTEXT.md` indica come la più temuta: il guasto raccontato come «tutto a posto» o come il guasto sbagliato.
4. **Hash illeggibile e hash diverso sono la stessa voce.** `guard let measured = …, measured.hash == item.hash, measured.size == item.size else { .alteredInTrash }`: un errore di lettura viene raccontato come «la foto nel Cestino non è più identica».
5. **Zero-overwrite: regge, e resta com'è.** La guardia è nostra (`fileExists` sull'originale), e dietro c'è `moveItem` che rifiuta una destinazione esistente con `NSCocoaErrorDomain/516` (misurato il 2026-08-27, sezione 4 della spec del pannello Doppioni) — quindi anche la finestra fra il controllo e la mossa è coperta da un secondo strato. Su exFAT (case-insensitive) un file che differisce solo per maiuscole conta come «occupato»: verso sicuro. **Nessun cambiamento qui**: si aggiunge solo un test sulla corsa (vedi §2.6).
6. **`createDirectory` su un volume sparito** proverebbe a ricreare `/Volumes/SSD - Enri/…` sul disco interno. Oggi lo impedisce solo il permesso di `/Volumes` (`drwxr-xr-x root wheel`, verificato su questo Mac il 2026-09-19): una difesa per caso, non nostra.
7. **Mutua esclusione: assente in un verso, accidentale nell'altro.** Il bottone è disattivato solo durante uno spostamento nel Cestino (`runner.isTrashingDuplicates`). Si può premere **durante un backup o una lettura dell'elenco** (verso mancante, oggi reale: la UI si blocca per minuti mentre il job prosegue). Nell'altro verso nessun job può partire durante l'annullamento **solo perché il main è bloccato** — la stessa mutua esclusione accidentale del punto 6 di BUG-7. Spostato fuori dal main, quel verso sparisce se non lo si scrive.
8. **Il bottone non sa se l'SSD è collegato.** A SSD scollegato si può premere, e si ottengono le frasi false del punto 3.
9. **`hasRestorableBatch` è calcolato nel `body`**: `lastBatch()` prende il lock dello store e filtra fino a 2.000 voci a ogni ridisegno; durante uno spostamento quel lock è tenuto da `record()` mentre scrive il JSON su disco, quindi il ridisegno della finestra aspetta la scrittura.
10. **Anche il trasher usa `restore`**: `DuplicateTrasher.run`, se la copia tenuta sparisce a metà gruppo, rimette a posto i file appena spostati con `manifest.restore(trashedInGroup)`. Qualunque cambiamento a `restore` cambia anche quel ramo.

### #37 — progresso per singolo file

`FileSyncer.syncFile` chiude ogni file con `DispatchQueue.main.async { onProgress(snap) }`; `BackupRunner.publishProgress` fa un secondo salto (`Task { @MainActor }`) e muta ~12 campi di `stats` (`@Published`), cioè invalida `ContentView` e tutto ciò che osserva il runner. Nella fase misurata il 2026-09-19 (Mac → SSD, quasi tutti file già presenti, ~575 file/s per ~25 s) sono ~575 ridisegni richiesti al secondo: main al ~100% in flush di transazioni CoreAnimation/`NSHostingView`, **non bloccato** (gli eventi passano).

Da dove vengono i numeri finali, oggi: a copia riuscita `finishCopyStep` **sovrascrive** `stats` dal `SyncResult` restituito (il riepilogo non dipende dall'ultimo `onProgress`); su **stop** `stop()` salva il `JobSummary` con lo `stats` di quell'istante; su **errore** il ramo `catch` di `run` salva lo `stats` dell'ultimo progresso arrivato. `RestoreEngine` (ripristino guidato da SSD/HDD) usa lo stesso `FileSyncer` e prende il totale finale dal risultato restituito. La barra del passo 2 non passa da qui: legge `indexProgress` di `LibraryIndexer`, già diradato da `progressEvery`.

Le altre sorgenti di progresso (`S3Syncer.sync` per file caricato, `downloadMany`, `DuplicateTrasher` per gruppo) hanno cadenze molto più basse e **restano come sono**.

### #39 — `hasSufficientSpace`

Gira dentro il `Task { @MainActor }` di `runMacToSSD`/`runSSDToHDD`/`runImport`, una volta per job. Tre difetti oltre al thread:

- legge `resourceValues` **sull'URL del bookmark**, cioè dalla cache dell'istanza (fatto misurato n. 1) — sul main la cache scade ai giri del run loop, quindi oggi è innocuo, ma è la lettura sbagliata da spostare fuori dal main così com'è;
- una lettura fallita diventa `available = 0`, e l'alert dice «Spazio insufficiente… liberi Zero KB»: blocca (verso giusto) con un motivo falso;
- se al posto del volume c'è una cartella normale, legge la capacità del **disco che la contiene** (il Mac), e può lasciar partire il job — lo stesso buco che #40 ha chiuso per `ssdMounted`, qui ancora aperto. `isLikelyVolumeRoot` non lo intercetta: `/Volumes/SSD - Enri` ha 3 componenti anche quando è una cartella.

`VolumeCapacityReader.read(path:)` (ADR-0008) risolve tutti e tre: URL nuovo a ogni chiamata, guardia sul punto di montaggio per componenti canoniche, `volumeAvailableCapacityKey` (la stessa chiave di oggi — **mai** `…ForImportantUsage`, che vale 0 sull'SSD exFAT/FSKit, fatto n. 18).

---

## 2. #34 — «Annulla l'ultimo spostamento» fuori dal main

### 2.1 Il principio

Il ripristino riceve **la stessa cura del cestinamento**, perché ne è la rete di sicurezza: se il ritorno indietro mente, l'utente non ha più modo di sapere dove sono le sue foto. Le regole sono le stesse di `DuplicateTrasher.run`, lette al contrario: una voce alla volta, registro aggiornato **subito**, `st_dev` riletto a ogni fallimento, mai `NSFileNoSuchFileError` come «già fatto», interruzione solo **fra** una foto e l'altra.

### 2.2 D1 — Il registro ricorda cosa è già tornato a posto (schema)

`TrashedItem` guadagna `restoredAt: Date?` (default `nil`, `decodeIfPresent` nella `init(from:)` esistente — regola del fatto n. 5: un registro scritto dalla versione attuale deve decodificarsi identico, con `restoredAt == nil`). Nuove operazioni su `TrashManifestStore`, tutte dietro il lock esistente:

- `markRestored(_ item: TrashedItem, at: Date) throws` — trova la voce per **identità** (`batchId` + `trashedPath` + `originalDisplayPath`, mai `==` sull'intero valore), imposta `restoredAt`, **scrive su disco prima di tornare** (stessa disciplina di `record`). Una voce con `trashedPath` vuoto non si marca mai (non era ripristinabile).
- `pendingInLastBatch() -> [TrashedItem]` — le voci dell'ultimo blocco registrato con `restoredAt == nil`. È **questo**, non `lastBatch()`, che «Annulla» rimette a posto.
- `restorableSummary() -> RestorableBatchSummary?` — valore piccolo e puro (`pendingCount`, `batchCount`, `trashedAt` del blocco), `nil` se non c'è niente da rimettere a posto. Serve alla UI (§2.8).

**Cosa significa per l'utente**: l'annullamento resta **a un livello** («l'ultimo spostamento»), come oggi. Una volta rimesso a posto tutto il blocco, il bottone si spegne con un motivo scritto; un blocco più vecchio **non** diventa annullabile dall'app (resta nel registro come storia, recuperabile a mano dal Cestino). **Alternativa scartata ma da far scegliere a Enrico — domanda 1**: togliere dal registro le voci rimesse a posto (letteralmente «escono dal registro»), il che trasforma il bottone in un annullamento a più livelli: dopo aver annullato l'ultimo blocco, la pressione successiva annullerebbe quello di prima, magari di settimane fa. Più potente, e più facile da premere per sbaglio.

Perché D1 tiene il registro coerente anche su un guasto: la marcatura è per voce e immediata, quindi un'interruzione, uno scollegamento o un crash lasciano il registro che dice esattamente quali foto sono tornate e quali no. L'unica finestra è fra il `moveItem` riuscito e la scrittura del registro (millisecondi): la chiude la riconciliazione di D3.

### 2.3 D2 — `TrashRestorer`, il motore di ripristino (tipo nuovo, `nonisolated`)

Stesso stampo di `DuplicateTrasher`: `nonisolated final class TrashRestorer: @unchecked Sendable`, solo proprietà `let`, stato tutto locale a `run`. Riga di sicurezza: «solo `let`; `run` può girare su qualunque thread, uno alla volta (lo garantisce `BackupRunner.isRestoringFromTrash`); il registro è protetto dal proprio lock». Funzioni iniettabili **solo dai test**, con default reali: `moveFunction` (default `FileManager.moveItem`), `hashFunction` (default `sha256Measured`), `volumeIdentity: (URL) -> dev_t?` (default `deviceIdentifier(of:)`). Il motivo è lo stesso già scritto sul trasher: uno scollegamento a metà non si produce su file veri senza una corsa, e un test basato su una corsa è verde col bug ogni volta che la corsa va nell'altro verso.

```swift
func run(_ items: [TrashedItem],
         onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
         isCancelled: () -> Bool = { false }) -> RestoreOutcome
```

`RestoreOutcome` (esistente) guadagna, additivi: `alreadyInPlace: [TrashedItem]`, `interrupted: Bool`, `stoppedBecauseVolumeVanished: Bool`, `notAttempted: Int`.

**Sequenza per voce** (ogni passo cita il perché):

0. **Prima di iniziare**: `deviceAtStart = volumeIdentity(libraryRoot)`. Se `nil`, nessuna voce viene tentata: `stoppedBecauseVolumeVanished = true`, `notAttempted = items.count`.
1. `isCancelled()` → `interrupted = true`, stop. Solo qui, fra una voce e l'altra: una foto a metà non esiste, perché `moveItem` è una rename.
2. **Confinamento dell'origine**: il percorso originale deve stare dentro la root della libreria, confrontato per **componenti canoniche** (le due forme di `rootForms`, stesso helper `relativePath(of:under:)` del trasher). Altrimenti `.outsideLibrary`. Non è teoria: il registro è un file JSON scrivibile dall'utente, e un percorso con `..` o su un altro disco non deve diventare la destinazione di una mossa.
3. **Il file nel Cestino c'è?** Se no:
   a. `volumeIdentity(libraryRoot) != deviceAtStart` → **scollegamento**: stop dell'intero ripristino (fatto n. 9);
   b. altrimenti, se al percorso originale c'è un file con **stessa dimensione e stesso hash** registrati → `alreadyInPlace` (vedi D3) e la voce si marca;
   c. altrimenti `.missingInTrash` (frase invariata: qui il volume c'è davvero, e il Cestino è stato svuotato o il file spostato a mano).
4. **Il file nel Cestino sta sullo stesso disco della libreria?** `volumeIdentity(trashed) == deviceAtStart`, altrimenti `.outsideLibrary`. Garantisce anche che `moveItem` sia una rename e mai una copia fra volumi seguita da una cancellazione.
5. **Zero-overwrite**: se al percorso originale esiste qualcosa → `.originalPathOccupied`. Invariato.
6. **Rilettura**: `hashFunction(trashed)`. `nil` → si rilegge `st_dev`: cambiato → scollegamento, stop; invariato → **`.unreadableInTrash`** (nuovo, frase propria). Hash o dimensione diversi → `.alteredInTrash` (invariato).
7. **Ricontrollo del disco subito prima di scrivere**: `volumeIdentity(libraryRoot) == deviceAtStart`, altrimenti scollegamento, stop. È la difesa **nostra** contro il `createDirectory` che ricreerebbe `/Volumes/SSD - Enri/…` sul Mac (§1, punto 6); il permesso di `/Volumes` resta secondo strato.
8. `createDirectory(withIntermediateDirectories:)` + `moveFunction(trashed, original)`. Errore → `st_dev`: cambiato → scollegamento, stop; invariato → `.moveFailed(dettaglio)`. **Mai «già fatto».**
9. Successo → `restored`, poi `manifest.markRestored(item)`. Se la scrittura del registro fallisce la foto **è** comunque tornata: conta fra le `restored`, e alla prossima pressione D3 la riconosce.
10. `onProgress(indice + 1, totale)` alla fine di ogni voce, qualunque esito (stessa convenzione del trasher: misura il lavoro fatto).

Su scollegamento o interruzione `notAttempted` = voci non ancora tentate. Nessun ramo lancia: `run` restituisce sempre un esito (serve al blocco finale che spegne il flag, come per il trasher).

`TrashManifestStore.restore(_:)` **viene rimossa** e i due chiamanti passano a `TrashRestorer`: il ramo `keeperVanished` di `DuplicateTrasher.run` (che ha già `libraryRoot` e `manifest`) e i test di `TrashManifestTests`. Tenerla come involucro avrebbe lasciato due strade per la stessa operazione, una senza `st_dev` — la classe di errore che il progetto ha già pagato tre volte (`LibraryExclusions`, `realResolvedPath`, `makeThumbnail`).

### 2.4 D3 — Riconciliazione: «era già tornata al suo posto»

Se il file non è più nel Cestino, il disco è quello di prima, e al percorso originale c'è un file con **dimensione e hash registrati** (rilettura dallo stesso descrittore, `sha256Measured`), la foto è al suo posto: la voce va in `alreadyInPlace` e si marca. Nessun file si muove; è una sola lettura in più, e solo in questo caso.

Copre tre situazioni reali che oggi producono la frase falsa «il Cestino è stato svuotato»: la seconda pressione dopo un annullamento riuscito scritto da una versione precedente (voci senza `restoredAt`), l'utente che ha fatto «Rimetti a posto» dal Finder (caso previsto dalla spec del pannello Doppioni, riga «L'utente fa Rimetti a posto dal Finder»), e il crash fra `moveItem` e `markRestored`.

**Cambia l'asserzione di un test esistente, di proposito**: `testRestoringTwice_isNotAnError` oggi si aspetta `.missingInTrash` alla seconda volta; con D3 si aspetterà `alreadyInPlace.count == 1` e nessuno `skipped`. L'intento del test («ripristinare due volte non è un errore») resta, e si rafforza: la seconda volta ora dice anche il vero.

### 2.5 D4 — Mutua esclusione in entrambi i versi, scritta

Nuovo `BackupRunner.isRestoringFromTrash` (`@Published private(set)`), impostato da `beginTrashRestore() -> SimpleAlert?` e `endTrashRestore()`, stesso schema di `beginDuplicateTrashing`/`endDuplicateTrashing`: controllo e impostazione atomici perché entrambi sul MainActor; `end` chiamato **nello stesso** `MainActor.run` che pubblica l'esito (`run` non lancia mai, quindi nessun percorso lo salta).

| Chi vuole partire | Chi lo ferma | Come |
| :--- | :--- | :--- |
| annullamento | job (anche passo 2), lettura dell'elenco, spostamento nel Cestino, un altro annullamento, SSD scollegato | `beginTrashRestore()` + `DuplicatesStatus.undoDisabledReason(...)` (nuova, pura) |
| job che scrive (Mac→SSD, SSD→HDD, SSD→Cubbit, import) | annullamento | `JobStartGate.blockedReason(..., isRestoringFromTrash:)` in `run(label:...)` |
| lettura dell'elenco (manuale) | annullamento | `LibraryIndexCommandGate.disabledReason(..., isRestoringFromTrash:)` |
| spostamento nel Cestino | annullamento | `DuplicatesStatus.trashDisabledReason(..., isRestoringFromTrash:)` + `beginDuplicateTrashing()` |

Il nuovo parametro è **senza default**, come `isTrashingDuplicates:` il 2026-09-19: una chiamata dimenticata diventa un errore di compilazione, non un buco silenzioso. Precedenza nei messaggi: spostamento > annullamento > lettura (le due operazioni sul Cestino sono le più vicine al danno; comunque non possono coesistere).

**Non toccati, con motivo**: `LibraryIndexCommandGate.resetDisabledReason` (svuotare l'elenco non tocca file, e l'annullamento non tocca l'elenco); `BackupListStep.shouldRun` (il passo 2 fa parte di un job, e un job e un annullamento già si escludono tramite `isRunning`/`JobStartGate`); `RestoreEngine` e il campione d'integrità (leggono l'SSD e non scrivono lì — stessa esclusione già dichiarata per lo spostamento nel Cestino).

**Alternativa valutata**: un solo stato `trashActivity: TrashActivity?` (`.trashing`/`.restoring`) al posto di due `Bool`, che rende impossibile per costruzione lo stato «entrambi veri». Scartata qui perché rinominerebbe un parametro già in ~55 punti (app + test) per un'impossibilità che `begin…()` garantisce già; da riconsiderare se nascesse una terza operazione sul Cestino.

### 2.6 D5 — Progresso e «Interrompi»

- Lo stato vive nel **runner**, non in `@State` della finestra: `trashRestoreProgress: (done, total)?`, `trashRestoreStopRequested`, il `CancelFlag` privato, `lastTrashRestoreOutcome`. Motivo: `DuplicatesView` è una scena di primo livello; chiuderla e riaprirla azzera gli `@State`, e con loro sparirebbero la barra e il bottone «Interrompi» di un'operazione ancora in corso (è esattamente ciò che succede oggi allo **spostamento** nel Cestino — vedi Scoperte collaterali).
- Il progresso passa dal `ProgressThrottle` di #37 (§3): al massimo ~10 aggiornamenti al secondo, sempre l'ultimo.
- «Interrompi» → `CancelFlag.cancel()`, `trashRestoreStopRequested = true`, il bottone diventa «Mi fermo dopo la foto in corso…» e si disattiva. Una foto grande (un video da qualche GB) può richiedere ~10 s di rilettura prima che l'interruzione abbia effetto: è voluto, perché la rilettura non si interrompe a metà per poi spostare il file.
- **Cosa significa interrompere a metà**: le foto già rimesse a posto sono marcate nel registro e non tornano indietro; le altre restano nel Cestino, intatte, e restano **annullabili** — premere di nuovo il bottone riprende da dove ci si era fermati (lavora solo su `pendingInLastBatch()`). Nessun gruppo resta in uno stato pericoloso: rimettere a posto una copia aggiunge un file, non ne toglie.

### 2.7 D6 — SSD scollegato a metà

Coperto dalla sequenza di D2 (passi 0, 3a, 6, 7, 8): al primo segnale lo `st_dev` decide; se il disco è cambiato si ferma **tutto**, si riportano quante foto erano già tornate e quante sono ancora nel Cestino dell'SSD, e il registro dice esattamente quali. Al ricollegamento, «Annulla» riprende; la voce che era in volo al momento dello scollegamento finisce in D3 (se la rename era arrivata a disco) o viene ritentata (se no). Il bottone è comunque disattivato a SSD scollegato (`undoDisabledReason`, `ssdMounted` da `VolumeMonitor`).

**Non verificato**: una rename su exFAT interrotta da uno scollegamento fisico. exFAT non ha journal; nel caso peggiore la voce risulta presente in entrambi i posti (→ `originalPathOccupied`, nessuna sovrascrittura) o in nessuno (→ `missingInTrash` con volume presente — lo stesso rischio che `trashItem` corre già in andata, non introdotto da qui). Non lo si prova staccando l'SSD vero: vedi Rischi.

### 2.8 D7 — Cosa vede l'utente (testi puri, nessuna stringa nuova nella View)

Nuovo enum puro `TrashRestoreStatus` (stessa disciplina di `DuplicatesStatus`/`LibraryIndexStatus`), testato su registro anti-gergo (niente «hash», «indice», «registro», «manifest», «volume», «scansione», «entry», «cache», «sha»), plurali e `id` stabili:

- **Conferma prima di partire** (nuova, non distruttiva — domanda 2): titolo «Rimettere a posto le foto?», messaggio «Le 312 foto spostate nel Cestino il 18 settembre alle 22:10 tornano nelle cartelle da cui erano state tolte. Ogni foto viene ricontrollata prima di essere spostata, quindi può volerci qualche minuto. Se al posto di una foto nel frattempo c'è un altro file, l'app non lo sovrascrive: la lascia nel Cestino e te lo dice.» Bottoni «Rimetti a posto» / «Annulla».
- **Bottone disattivato, con motivo** (`undoDisabledReason`): SSD scollegato («L'SSD non è collegato: le foto da rimettere a posto sono nel suo Cestino. Ricollegalo e riprova.»), backup in corso, elenco in aggiornamento, spostamento in corso, annullamento già in corso, niente da rimettere a posto («L'ultimo spostamento è già stato annullato.» / «Da qui non hai ancora spostato niente nel Cestino.»).
- **Durante**: «Rimetto a posto le foto: 120 di 312» con barra e «Interrompi».
- **Esito** (righe nel pannello, come l'esito dello spostamento — non più un alert, così resta visibile anche riaprendo la finestra):
  - tutto: «312 foto sono tornate al loro posto.»
  - già a posto: «4 erano già al loro posto (forse le avevi rimesse tu dal Finder).»
  - interrotto: «Ti sei fermato a metà: 120 foto sono tornate al loro posto, le altre 192 sono ancora nel Cestino, al sicuro. Premi di nuovo «Annulla l'ultimo spostamento» per finire.»
  - scollegamento: «L'SSD si è scollegato mentre rimettevo a posto le foto: 120 sono tornate al loro posto, le altre 192 sono ancora nel Cestino dell'SSD. Ricollegalo e premi di nuovo «Annulla l'ultimo spostamento» per finire.»
  - saltate, raggruppate per motivo con il numero e la frase di `RestoreSkipReason.explanation` (le due nuove: `.unreadableInTrash` «Non è stato possibile rileggere questa foto nel Cestino, quindi è rimasta lì. Riprova più tardi; se il problema resta, puoi spostarla a mano.»; `.outsideLibrary` «Questa foto doveva tornare in un posto fuori dall'SSD delle foto, quindi l'app non l'ha toccata: è ancora nel Cestino.»)
  - sempre, se almeno una è tornata: «Le foto tornate a posto ricompariranno fra le copie doppie dopo il prossimo aggiornamento dell'elenco.» (vero oggi e non detto: ADR-0005 vieta di reinserirle a mano nell'elenco).
- **Messaggi dei gate** (niente gergo): `JobStartGate` — «L'app sta rimettendo a posto le foto che avevi spostato nel Cestino. Aspetta che finisca, oppure fermala con «Interrompi» nella finestra Doppioni.»; `LibraryIndexCommandGate` — «L'app sta rimettendo a posto le foto spostate nel Cestino: leggere le foto adesso darebbe un elenco sbagliato. Riprova quando ha finito.»; `trashDisabledReason` — «L'app sta rimettendo a posto le foto dell'ultimo spostamento: aspetta che finisca.»

### 2.9 D8 — Niente più letture del registro nel `body`

`hasRestorableBatch` sparisce. Il runner pubblica `restorableBatch: RestorableBatchSummary?`, calcolato **fuori dal main** (`Task.detached` + `restorableSummary()`) in tre momenti: all'apertura della finestra Doppioni (`.task`), alla fine di uno spostamento, alla fine di un annullamento. La View lo legge in O(1). Il getter `lazy` di `trashManifestStore` resta sul main (decodifica di un JSON ≤2.000 voci, millisecondi): stessa categoria di #35, accettata.

### 2.10 Orchestrazione

`BackupRunner.startTrashRestore()` (MainActor) fa, nell'ordine: `beginTrashRestore()` (rifiuto → avviso nella finestra Doppioni, mai `runner.pendingAlert`, regola di `AlertSink`) → risoluzione di store, root SSD, voci `pendingInLastBatch()` (lette fuori dal main) → `Task.detached(priority: .utility) { restorer.run(...) }` → `MainActor.run { endTrashRestore(); pubblica esito; ricalcola restorableBatch }`. `stopTrashRestore()` per «Interrompi». `DuplicatesView` si limita a: conferma → `startTrashRestore()`; barra/«Interrompi»/esito letti dal runner; `loadGroups()` quando `isRestoringFromTrash` torna `false`. Stessa forma del lavoro di fondo già in produzione per il trasher (caso C della tabella); come quello occupa un thread del pool cooperativo per la durata (#36, accettato).

---

## 3. #37 — Progresso della copia: al massimo ~10 aggiornamenti al secondo

### 3.1 D9 — Dove si dirada: alla fonte, in `FileSyncer`

Nuovo value type puro `ProgressThrottle` (`nonisolated`, nessuno stato condiviso: ogni istanza vive sullo stack del thread di `sync`):

```swift
nonisolated struct ProgressThrottle {
    static let defaultMinimumIntervalNanos: UInt64 = 100_000_000   // 100 ms
    init(minimumIntervalNanos: UInt64 = defaultMinimumIntervalNanos)
    /// `true` se l'aggiornamento va pubblicato adesso. `isFinal` pubblica sempre.
    mutating func shouldEmit(nowNanos: UInt64, isFinal: Bool) -> Bool
}
```

Regole: il primo aggiornamento passa sempre; poi solo se sono trascorsi ≥ 100 ms dall'ultimo pubblicato; `isFinal` passa sempre; un orologio che torna indietro (non dovrebbe: si usa `DispatchTime.now().uptimeNanoseconds`, monotono) pubblica e riparte, mai un silenzio.

In `FileSyncer`:

- `sync(...)` crea un `ProgressThrottle` locale e lo passa **per `inout`** a `syncDir`/`syncFile` (parametro nuovo, **senza default** — regola già scritta su quei due metodi privati);
- `syncFile` pubblica `onProgress` solo se `shouldEmit(..., isFinal: result.done == result.total)`;
- **`sync` pubblica sempre un ultimo `onProgress(result)` prima di ogni `cont.resume`** — riuscita, interruzione (che in `FileSyncer` esce come ritorno normale con risultato parziale) ed errore lanciato da `syncDir` (il valore `inout` è già stato riscritto quando l'errore arriva al `catch`). È la garanzia «sempre l'ultimo valore»: non dipende da `done == total`, che può non verificarsi mai se il conteggio iniziale e la copia vedono un numero diverso di file.
- `FileSyncer.init` guadagna `progressIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos`, **iniettato solo dai test** (stesso schema di `hashFunction`): con un intervallo di un'ora il test sa esattamente quali aggiornamenti devono arrivare, senza cronometro.

**Perché alla fonte e non in `BackupRunner.publishProgress`**: diradare a valle lascerebbe i ~575 salti al secondo sul main (due per file), e costringerebbe a gestire un valore «in attesa» da scartare o applicare in `finishCopyStep`/`stop()`/`catch` — tre punti dove un valore vecchio arrivato tardi può sovrascriverne uno nuovo. Alla fonte c'è un solo punto di uscita (`sync`), e l'ultimo valore pubblicato **coincide** con quello restituito: anche se arrivasse dopo `finishCopyStep` (può succedere: `publishProgress` fa un secondo salto), scriverebbe gli stessi numeri. Vale gratis anche per l'importazione e per `RestoreEngine`, che usano lo stesso `FileSyncer`.

### 3.2 Cosa non cambia, e cosa cambia di poco

- **Conteggi finali**: invariati. A copia riuscita vengono da `finishCopyStep` (dal risultato restituito); su errore dall'ultimo `onProgress`, che ora è sempre il risultato completo fino al punto dell'errore (prima era l'ultimo arrivato, equivalente).
- **Barra del passo 2**: non toccata (legge `LibraryIndexer`, che ha già `progressEvery`).
- **Stop manuale**: `stop()` salva il riepilogo con lo `stats` dell'istante del clic; con il diradamento quello `stats` può essere indietro di **al massimo ~100 ms di file** (a 575 file/s, ~57 file saltati — mai file copiati mancanti dal conteggio in modo significativo, perché la copia vera va a decine di file al secondo). Oggi era indietro dei soli salti in coda. Accettato e dichiarato; correggerlo significherebbe far aspettare `stop()` la fine del thread di copia.
- **ETA**: `smoothEta` è una media esponenziale per campione (0,15): con 10 campioni al secondo invece di 575 risponde più lentamente in tempo reale (costante di ~1 s). È più stabile, non meno corretta.
- **Righe di stato e log** («Copia (n/N)…», «Verifica integrità…», avvisi): **non diradate** — ogni riga del log resta, compresi gli avvisi di hash diverso e di copia non verificata. Sono per file **copiato**, non per file esaminato: nella fase misurata (quasi tutti già presenti) non partono. Se dopo questo intervento la misura su una copia vera (molti file nuovi) mostrasse ancora il main saturo, il passo successivo è raggruppare le righe di log in `publishStatus` ogni ~100 ms **senza perderne nessuna** — lasciato come passo condizionato alla misura (Task 5 del piano), non implementato a occhio.

---

## 4. #39 — Spazio libero letto fuori dal main, con un motivo onesto

- Nuovo enum puro `FreeSpaceCheck` (MainActor di default: gira sul main, costa nulla): `verdict(bytesNeeded: Int64, reading: VolumeCapacityReading) -> Verdict`, con `Verdict` = `.enough` / `.notEnough(available:)` / `.notADisk` / `.unreadable`. Il margine è **lo stesso di oggi**: `max(5% di bytesNeeded, 500 MB)`, confronto `available >= bytesNeeded + margin`. Una sola definizione, testata ai bordi.
- In `runMacToSSD`/`runSSDToHDD`/`runImport` la lettura diventa `await Task.detached(priority: .userInitiated) { VolumeCapacityReader.read(path: url.path) }.value` — caso C: `read` è già `nonisolated static`. `hasSufficientSpace` viene rimossa: **una** funzione che legge lo spazio in tutta l'app.
- Esiti: `.enough` → il job parte come oggi; `.notEnough` → **stesso alert di oggi, stesso testo**; `.notADisk` → blocca: «L'SSD non sembra collegato: al suo posto c'è una cartella normale del Mac. Ricollega l'SSD e riprova.» (HDD analogo); `.unreadable` → blocca: «Non riesco a leggere quanto spazio libero c'è sull'SSD in questo momento (può succedere se il disco si sta ancora svegliando). Riprova tra qualche secondo.»
- **Comportamento che cambia**: `.unreadable` bloccava già (come «spazio insufficiente, liberi Zero KB»): ora blocca con il motivo vero. `.notADisk` oggi **lasciava partire** il job sul disco del Mac: ora blocca. Nessun caso che oggi parte smette di partire, tranne questo.
- Il doc-comment di `VolumeCapacityReader` («chiamata SOLO dalla `probeQueue`») va aggiornato: ora la chiama anche `BackupRunner`, sempre fuori dal main.

---

## 5. Test

Tutti su directory temporanee reali, nessun mock del filesystem; le sole iniezioni sono le funzioni già elencate (stesso schema di `FileSyncer`/`DuplicateTrasher`).

- **`TrashManifestTests`** (esistente, aggiornato): i test di `restore` passano a `TrashRestorer` (stesse asserzioni; l'unica che cambia è quella di `testRestoringTwice_isNotAnError`, §2.4). Nuovi: registro scritto dalla versione attuale (senza `restoredAt`) che si decodifica con `restoredAt == nil`; `markRestored` è su disco prima di tornare (riapertura da zero); `pendingInLastBatch` esclude le marcate; identità della voce (due voci con stesso `originalDisplayPath` in blocchi diversi non si confondono); `restorableSummary` `nil` a blocco completamente ripristinato.
- **`TrashRestorerTests`** (nuovo): ripristino riuscito marca la voce; zero-overwrite con file presente (contenuto dell'occupante invariato byte per byte); **corsa sull'occupante**: `moveFunction` iniettata che crea il file di destinazione subito prima di delegare alla vera `moveItem` → la mossa fallisce, l'occupante è intatto, la voce resta nel Cestino e non marcata; hash illeggibile → `.unreadableInTrash` (non `.alteredInTrash`); hash diverso → `.alteredInTrash`; **scollegamento** in ciascuno dei tre punti di fallimento (file mancante, hash `nil`, `moveItem` che lancia `NSCocoaErrorDomain/4`) tramite `volumeIdentity` che cambia valore → stop totale, conteggi onesti, voci non tentate non marcate; disco assente all'avvio → niente tentato; **ricontrollo prima di `createDirectory`**: disco cambiato dopo la rilettura → nessuna cartella creata; interruzione dopo k voci → k marcate, le altre in `pendingInLastBatch`, e una seconda `run` le completa; riconciliazione `alreadyInPlace`; origine fuori dalla root (anche con `..`) e file nel Cestino su un altro disco → `.outsideLibrary`, nessuna mossa; `onProgress` chiamato una volta per voce, anche per le saltate.
- **`DuplicateTrasherTests`** (esistente): `testKeeperVanished_restoresWhatWasJustTrashed` resta verde passando da `TrashRestorer`; in più, le voci rimesse a posto in quel ramo risultano marcate.
- **`JobStartGateTests`, `DuplicatesStatusTests`, `LibraryIndexStatusTests`** (esistenti): chiamate aggiornate col nuovo parametro, asserzioni invariate; nuovi casi per `isRestoringFromTrash` (blocca, messaggio distinto, precedenze, anti-gergo), e per `undoDisabledReason` (ogni ramo raggiunto dal proprio caso, stile `testEveryBranchIsActuallyReachedByItsCase`).
- **`TrashRestoreStatusTests`** (nuovo): ogni riga di esito, plurali, anti-gergo, `id` stabili; la riga «ricompariranno fra le copie doppie» presente se e solo se almeno una foto è tornata.
- **`ProgressThrottleTests`** (nuovo, puro): primo sempre; soppresso entro l'intervallo; pubblicato allo scadere; `isFinal` sempre; orologio all'indietro; intervallo zero.
- **`FileSyncerProgressThrottleTests`** (nuovo): con intervallo di un'ora e 50 file, l'ultimo `onProgress` ricevuto è uguale al `SyncResult` restituito e le chiamate sono ≤ 4 (non 50); con `cancel()` chiamato a metà (dall'hook `isDuplicate`, deterministico) l'ultimo `onProgress` è uguale al risultato parziale restituito — è il test che prende la rimozione dell'ultimo aggiornamento in `sync`.
- **`FreeSpaceCheckTests`** (nuovo): bordo esatto (`available == needed + margin` → basta; un byte in meno → no), margine minimo 500 MB su job piccoli, 5% su job grandi, `bytesNeeded == 0`, `.notAMountPoint` → `.notADisk`, `.unreadable` → `.unreadable`.
- **`MainThreadIsolationTests`** (esistente, +4): `TrashRestorer.run` (funzioni iniettate che non toccano niente), `TrashManifestStore.pendingInLastBatch`/`restorableSummary`, `ProgressThrottle`, `VolumeCapacityReader.read` — ciascuno in un `Task.detached` col main tenuto occupato. Limite già dichiarato: verificano i tipi, non la forma dei call site.

**Non coperto, dichiarato** (SwiftUI e bookmark veri): la conferma e la barra nella finestra Doppioni, `startTrashRestore`/`stopTrashRestore`, il ricalcolo di `restorableBatch`, il cablaggio dello spazio nei tre job. È testato tutto ciò che sta ai due capi del cablaggio.

**Mutation testing** (copia nello scratchpad): togliere il controllo `st_dev` su ciascuno dei tre fallimenti; togliere il ricontrollo prima di `createDirectory`; togliere `markRestored`; trattare `hash == nil` come `alteredInTrash`; togliere la guardia zero-overwrite nostra (deve prenderlo il test dell'occupante — l'occupante resta intatto grazie a `moveItem`, ma la voce deve risultare `.originalPathOccupied` e non `.moveFailed`); togliere `isRestoringFromTrash` da `JobStartGate`; togliere l'ultimo `onProgress` in `sync`; togliere `nonisolated` da `TrashRestorer`/`ProgressThrottle`. Ogni mutante deve rendere rosso almeno un test o la build.

---

## 6. Verifiche manuali (con Enrico, a fine intervento)

1. **#34, sull'SSD vero, blocco piccolo**: spostare nel Cestino 2-3 gruppi scelti da Enrico, «Annulla» → conferma, barra, esito; seconda pressione → bottone spento con «L'ultimo spostamento è già stato annullato».
2. **#34, interruzione**: blocco di ~50 file, «Interrompi» a metà → esito «ti sei fermato a metà»; nuova pressione → completa.
3. **#34, gate dal vivo**: durante un annullamento premere Mac → SSD → alert di `JobStartGate`; durante un backup il bottone «Annulla» è spento con motivo.
4. **#34, finestra chiusa e riaperta** durante l'annullamento → barra e «Interrompi» ancora lì.
5. **#37**: `sample <pid> 4` durante la fase «quasi tutti già presenti» di un Mac → SSD, come il 2026-09-19 → il main non deve più essere al ~100% in ridisegno. E una copia con molti file nuovi (se disponibile) per decidere il Task 5 del piano.
6. **#39**: un Mac → SSD normale parte come prima (nessuna differenza visibile).

**Lo scollegamento a metà annullamento NON si prova sull'SSD vero** (rischio exFAT senza journal, §2.7): lo coprono i test con `volumeIdentity` iniettata. Se Enrico lo vuole vedere dal vivo, si fa con una sonda su un'immagine exFAT (`hdiutil`), come le misure del 2026-08-27, non dall'app sull'SSD delle foto.

---

## 7. Rischi

- **Un ripristino che mente è peggio di uno lento.** Il rischio principale di #34 non è di prestazioni: è riportare lo scollegamento come «Cestino svuotato» o un hash illeggibile come «foto cambiata». La sequenza di D2 e i test per ciascun punto di fallimento esistono per questo; sono la parte da non semplificare in review.
- **Cambio di schema del registro** (`restoredAt`). Retrocompatibile in lettura (`decodeIfPresent`); una versione **vecchia** dell'app che rilegge un registro scritto dalla nuova ignora il campo (la decodifica per chiavi lo scarta) e torna al comportamento di oggi — nessuna perdita. Richiede un ADR (0009) prima dell'implementazione.
- **Churn dei test**: il parametro senza default tocca ~40 chiamate nei test esistenti. È meccanico e il compilatore le trova tutte, ma una review deve controllare che nessuna asserzione sia stata ammorbidita nel passaggio — stessa regola del piano del 2026-09-19.
- **Voci irrecuperabili che restano «da rimettere a posto».** Con D1 una voce `missingInTrash` (Cestino svuotato davvero) resta non marcata, quindi il bottone resta acceso per quel blocco e ogni pressione ripete la stessa frase. Accettato: marcarla «persa» è una decisione più delicata (e se il Cestino tornasse leggibile?); la frase dice il vero ogni volta.
- **Un nuovo spostamento dopo un annullamento interrotto** rende «ultimo» il blocco nuovo: le foto rimaste nel Cestino dal blocco precedente escono dalla portata del bottone (restano nel registro e nel Cestino, recuperabili a mano). È il limite dell'annullamento a un livello (domanda 1); accettato se Enrico sceglie D1.
- **#37, stop manuale**: il riepilogo di un job interrotto può contare ~100 ms di file in meno (§3.2). Accettato.
- **#39, un blocco in più**: una cartella al posto dell'SSD ora ferma il job. È il verso voluto (#40), ma è un cambiamento di comportamento.
- **Stime non misurate**: la durata del caso peggiore di #34 (80-180 s) è calcolata dal throughput misurato, non cronometrata sull'app; il guadagno di #37 va verificato con `sample` (verifica 5), non dato per scontato.

---

## 8. Domande aperte per Enrico (con raccomandazione)

1. **Dopo «Annulla», le foto rimesse a posto: marcate nel registro (annullamento a un livello, come oggi) o tolte dal registro (annullamento a più livelli)?** Raccomandazione: **marcate** (D1). Il bottone continua a voler dire «l'ultimo spostamento» e si spegne quando è tutto rimesso a posto; con la versione a più livelli una pressione in più annullerebbe uno spostamento vecchio che magari non si ricorda di aver fatto.
2. **Aggiungere una conferma prima di «Annulla»** (con numero di foto e data dello spostamento)? Oggi parte al clic. Raccomandazione: **sì** — non è distruttivo, ma ora dura minuti, ferma i backup per quel tempo e ricrea doppioni: vale una riga di conferma con i numeri, non un alert rosso.
3. **#37: bastano ~10 aggiornamenti al secondo?** Raccomandazione: **sì** — la barra resta fluida all'occhio e il costo scende di ~50 volte nella fase misurata; se la verifica 5 mostrasse ancora il main saturo durante una copia vera, si affronta il log (Task 5 del piano) invece di abbassare ancora la cadenza.

---

## 9. Scoperte collaterali (fuori scope, non corrette qui)

- **Lo spostamento nel Cestino perde barra e «Interrompi» se si chiude e riapre la finestra Doppioni.** `trashProgress` e `activeCancelFlag` sono `@State` di `DuplicatesView`: riaprendo, `isTrashingDuplicates` è vero ma la barra (condizionata a `trashProgress != nil`) e il bottone «Interrompi» non compaiono — un'operazione a danno alto che l'utente non può più fermare finché non finisce. Si corregge con lo stesso schema di D5 (stato nel runner). Consigliato come intervento successivo, piccolo; non incluso per non allargare questo.
- **`RestoreEngine` (ripristino guidato da SSD/HDD) può mostrare un avanzamento oltre il totale per un istante**: la closure di `onProgress` cattura `offset` per riferimento e somma `offset` aggiornato al `snap.done` della cartella precedente se il salto sul main arriva tardi. Preesistente, solo visivo (il totale finale viene dal risultato restituito). Il diradamento di #37 non lo peggiora.
- **Il log del job (`runner.output`) è mostrato nella finestra principale e ogni riga lo ripubblica**: durante una copia con molti file nuovi ogni file produce 2-3 righe, e ognuna invalida la finestra. È il candidato naturale del Task 5 condizionato del piano.
