# ADR-0009 — L'annullamento dello spostamento gira fuori dal main, e il registro ricorda cosa è tornato

**Data:** 2026-09-20
**Stato:** Accettata

## Contesto

`DuplicatesView.undoLastBatch()` chiama `TrashManifestStore.restore(manifest.lastBatch())` in modo sincrono dal main thread. Il costo non sono i `moveItem` (rename sullo stesso volume, ~56 file/s) ma la rilettura: ogni voce viene rihashata con `sha256Measured` prima di essere rimessa a posto, e un blocco al tetto dei 50 GB costa ~80-180 secondi di main thread bloccato — un beachball di minuti sul gesto che l'utente fa quando qualcosa gli sembra già andato storto (ADR-0005: il pannello Doppioni è il percorso a danno più alto del progetto, e l'annullamento ne è la rete di sicurezza).

Oltre al thread, `restore` di oggi ha quattro difetti trovati leggendo il codice (spec `Docs/superpowers/specs/2026-09-19-remaining-main-thread-work-design.md`, §1 #34):

1. **Il registro non ricorda i ripristini**: una seconda pressione di «Annulla» dopo un successo produce N voci `missingInTrash` con la frase «probabilmente il Cestino è stato svuotato» — falsa, le foto sono al loro posto.
2. **Nessun controllo `st_dev`**: uno scollegamento a metà annullamento produce le stesse due frasi false (`missingInTrash` o `alteredInTrash`), la classe di bug che questo progetto teme di più — raccontare un guasto come «tutto a posto» o come il guasto sbagliato.
3. **Hash illeggibile e hash diverso sono la stessa voce** (`alteredInTrash` copre entrambi).
4. **Mutua esclusione assente in un verso** (si può premere «Annulla» durante un backup o una lettura dell'elenco) e **accidentale nell'altro** (nessun job può partire durante l'annullamento solo perché il main è bloccato — la stessa mutua esclusione per caso di BUG-7).

## Opzioni valutate

**A. Registro marcato — annullamento a un livello (scelta).** `TrashedItem` guadagna `restoredAt: Date?`. «Annulla» rimette a posto solo `pendingInLastBatch()` (le voci del blocco più recente non ancora marcate). Una volta rimesso a posto tutto il blocco, il bottone si spegne con un motivo scritto. Un blocco più vecchio non diventa annullabile dall'app — resta nel registro come storia, recuperabile a mano dal Cestino.

**B. Voci tolte dal registro — annullamento a più livelli.** Rimuovere le voci rimesse a posto invece di marcarle trasformerebbe il bottone in un annullamento a più livelli: dopo aver annullato l'ultimo blocco, la pressione successiva annullerebbe quello di prima, magari di settimane fa. Più potente, e più facile da premere per sbaglio senza rendersi conto di quale blocco si sta annullando.

**C. `restore` lasciata sul main con un semplice `Task.detached` attorno.** Scartata: senza le altre correzioni (registro che marca, `st_dev`, mutua esclusione) lascerebbe intatte le frasi false e la mutua esclusione accidentale — sposterebbe solo il thread, non il problema.

## Decisione e motivo

**Opzione A**, con una conferma non distruttiva prima di partire (numero di foto e data dello spostamento, in linguaggio comune, per esempio «Rimetto a posto 312 foto spostate il 2 settembre»). Decisioni di Enrico (2026-09-19/20):

1. **Annullamento a un solo livello** (raccomandazione della spec, opzione A qui sopra): il bottone continua a voler dire «l'ultimo spostamento» e si spegne quando tutto è rimesso a posto. Premendo di nuovo, l'app dice che non c'è altro da annullare, con un testo vero — non finge che l'operazione sia ripartita.
2. **Conferma prima di annullare**: sì, con il numero di foto e la data dello spostamento, perché l'operazione ora dura minuti, ferma i backup per quel tempo e ricrea doppioni nell'elenco — non è più un clic reversibile all'istante.

Il ripristino riceve la stessa cura del cestinamento, letta al contrario: una voce alla volta, registro aggiornato subito dopo ogni successo, `st_dev` riletto a ogni fallimento, mai `NSFileNoSuchFileError` interpretato come «già fatto», interruzione solo fra una foto e l'altra. Il motore (`TrashRestorer`, nuovo tipo `nonisolated`) sostituisce `TrashManifestStore.restore`, che viene rimossa: tenerla come involucro avrebbe lasciato due strade per la stessa operazione, una senza `st_dev` — la classe di errore già pagata tre volte (`LibraryExclusions`, `realResolvedPath`, `makeThumbnail`).

**Riconciliazione (D3)**: se il file non è più nel Cestino ma al percorso originale c'è un file con la stessa dimensione e lo stesso hash registrati, la foto è considerata già al suo posto (`alreadyInPlace`) invece che «Cestino svuotato». Copre tre situazioni reali: la seconda pressione dopo un annullamento scritto da una versione precedente (senza `restoredAt`), l'utente che ha fatto «Rimetti a posto» dal Finder, e un crash fra `moveItem` e la marcatura del registro.

**Mutua esclusione in entrambi i versi**: nuovo `BackupRunner.isRestoringFromTrash`, consultato da `JobStartGate` (i job non partono durante un annullamento), da `LibraryIndexCommandGate` (la lettura manuale non parte durante un annullamento) e da `DuplicatesStatus.trashDisabledReason`/`undoDisabledReason` (spostamento e annullamento non possono coesistere, in entrambi i versi).

**Cosa si accetta di perdere.** Una voce `missingInTrash` (Cestino davvero svuotato) resta non marcata per sempre: il bottone resta acceso per quel blocco e ogni pressione ripete la stessa frase — corretta, ma ripetuta. Marcarla «persa» sarebbe una decisione più delicata (e se il Cestino tornasse leggibile?). Un nuovo spostamento dopo un annullamento interrotto rende «ultimo» il blocco nuovo: le foto rimaste nel Cestino dal blocco precedente escono dalla portata del bottone (restano nel registro e nel Cestino, recuperabili a mano) — è il limite intrinseco dell'annullamento a un livello, accettato con la scelta dell'opzione A.

**Per riaprire questa decisione** serve un argomento nuovo — per esempio un caso reale in cui Enrico ha bisogno di annullare un blocco più veccio dell'ultimo, non solo recuperarlo a mano dal Cestino.

## Conseguenze

- **Schema del registro**: `TrashedItem.restoredAt: Date?` (default `nil`, `decodeIfPresent` nella `init(from:)` esistente). Retrocompatibile in lettura in entrambi i versi: un registro scritto dalla versione attuale (senza `restoredAt`) si decodifica con `restoredAt == nil`; una versione **vecchia** dell'app che rilegge un registro scritto dalla nuova ignora il campo e torna al comportamento di oggi — nessuna perdita, solo la marcatura che non è più visibile a quella versione (la riconciliazione D3 la recupera comunque al prossimo giro).
- `TrashManifestStore.restore(_:)` rimossa; i due chiamanti (`DuplicatesView.undoLastBatch()` tramite il runner, e `DuplicateTrasher.run` nel ramo `keeperVanished`) passano a `TrashRestorer.run(...)`.
- Quattro gate guadagnano un parametro `isRestoringFromTrash: Bool` **senza default**: `JobStartGate.blockedReason`, `LibraryIndexCommandGate.disabledReason`, `DuplicatesStatus.trashDisabledReason`, più la nuova `DuplicatesStatus.undoDisabledReason`.
- Nessuno schema SQLite, nessuna chiave `UserDefaults` nuova o rinominata.

Vedi `.claude/rules/architecture.md` per i dettagli implementativi, spec `Docs/superpowers/specs/2026-09-19-remaining-main-thread-work-design.md` §2, piano `Docs/superpowers/plans/2026-09-19-remaining-main-thread-work.md`.

---

**2026-09-24**: lo stesso schema è stato applicato allo spostamento nel Cestino (ROADMAP #41, spec `Docs/superpowers/specs/2026-09-20-trash-progress-survives-window-close-design.md`, piano `Docs/superpowers/plans/2026-09-20-trash-progress-survives-window-close.md`): `BackupRunner` guadagna `duplicateTrashProgress`/`duplicateTrashStopRequested`/`lastDuplicateTrashOutcome`/`startDuplicateTrashing`/`stopDuplicateTrashing`, simmetrici a quelli dell'annullamento. Il difetto che questo doc-comment citava come «ancora aperto dello spostamento nel Cestino» (righe di `architecture.md` su `restorableBatch`) è **chiuso**: chiudere e riaprire la finestra Doppioni durante uno spostamento non fa più perdere barra, «Interrompi» o l'esito.

Due scelte minori decise in questo secondo intervento, non nuove architetture:

- **L'elenco dei gruppi non si ricarica mentre lo spostamento è in corso** (a differenza della ricarica a fine operazione): un elenco letto a metà è già vecchio quando compare, perché il trasher toglie chiavi dallo stesso elenco mentre lo spostamento procede sullo stesso volume.
- **L'esito dello spostamento vive solo in memoria nel runner, non su disco**: il documento durevole di cosa è stato spostato resta il registro (`TrashManifestStore`), e un secondo posto dove la stessa verità può divergere non aggiunge nulla.
