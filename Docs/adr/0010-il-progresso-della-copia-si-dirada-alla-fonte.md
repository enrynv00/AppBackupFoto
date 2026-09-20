# ADR-0010 — Il progresso della copia si dirada alla fonte

**Data:** 2026-09-20
**Stato:** Accettata

## Contesto

`FileSyncer.syncFile` pubblica un `onProgress` per ogni file copiato (`DispatchQueue.main.async { onProgress(snap) }`); `BackupRunner.publishProgress` fa un secondo salto (`Task { @MainActor }`) e muta ~12 campi `@Published` di `stats`, invalidando `ContentView` e tutto ciò che osserva il runner. Misurato dal vivo il 2026-09-19 (Task 9 del fix di isolamento MainActor, spec `2026-09-19-mainactor-default-isolation-fix-design.md`): durante un MAC → SSD con quasi tutti i file già presenti (~575 file/s per ~25s) il main thread risultava occupato al ~100% in flush di transazioni CoreAnimation/`NSHostingView` — non bloccato (gli eventi passavano), ma saturo per l'intera fase. Osservazione registrata come ROADMAP #37, priorità media.

## Opzioni valutate

**A. Diradare in `FileSyncer`, alla sorgente (scelta).** Nuovo value type puro `ProgressThrottle`, passato per `inout` da `sync` a `syncDir`/`syncFile`: al massimo un aggiornamento ogni 100ms, sempre l'ultimo valore garantito prima di ogni uscita da `sync` (successo, interruzione, errore).

**B. Diradare in `BackupRunner.publishProgress`.** Scartata: i ~575 salti al secondo dalla coda di lavoro al main resterebbero (il costo del salto stesso, non solo del ridisegno, non sparirebbe), e servirebbe gestire un valore «in attesa» da scartare o applicare in tre punti diversi di fine job (`finishCopyStep`, `stop()`, il ramo `catch` di `run`) — tre posti dove un valore vecchio arrivato tardi potrebbe sovrascriverne uno nuovo.

**C. Un aggiornamento ogni N file, invece che ogni tot di tempo.** Scartata: a 575 file/s e a 5 file/s (un job con pochi file grandi) serve una cadenza a schermo diversa in numero di file, ma la stessa in tempo — l'occhio vede la barra, non il contatore.

## Decisione e motivo

**Opzione A.** `ProgressThrottle` (`nonisolated struct`, nessuno stato condiviso: ogni istanza vive sullo stack del thread che la usa) dirada a ~10 aggiornamenti al secondo (100ms, raccomandazione della spec, confermata da Enrico il 2026-09-19/20). `sync` pubblica **sempre** un ultimo `onProgress` prima di ogni uscita, indipendentemente da `done == total`: è la garanzia «sempre l'ultimo valore», e coincide con quanto la funzione restituisce, quindi arrivare in ritardo rispetto a `finishCopyStep` non cambia i numeri finali.

**Cosa non cambia**: i conteggi finali (vengono da `finishCopyStep` a copia riuscita, dall'ultimo `onProgress` — ora sempre completo fino al punto dell'errore — su errore); la barra del passo 2 (legge `LibraryIndexer`, già diradata da `progressEvery`, ADR-0007); le righe di stato e di log (non diradate: sono per file **copiato**, non per file esaminato, e nella fase misurata — quasi tutti già presenti — non partono quasi mai).

**Cosa si accetta di perdere.** Lo `stop()` manuale salva il riepilogo con lo `stats` dell'istante del clic: con il diradamento può essere indietro di al massimo ~100ms di file (a 575 file/s, ~57 file), contro i pochi salti in coda di prima. Correggerlo farebbe aspettare `stop()` la fine del thread di copia — scartato. Se una copia con molti file **nuovi** (non solo già presenti) mostrasse ancora il main saturo dopo questo intervento, il passo successivo è raggruppare le righe di log in `publishStatus` ogni ~100ms senza perderne nessuna — condizionato alla misura, non implementato a occhio (Task 12 del piano).

**Per riaprire questa decisione** serve una misura che mostri la barra non più fluida all'occhio con 100ms, o un caso reale in cui il ritardo di ~100ms sullo `stop()` è un problema concreto.

## Conseguenze

- `FileSyncer.init` guadagna `progressIntervalNanos: UInt64 = ProgressThrottle.defaultMinimumIntervalNanos`, iniettato solo dai test (stesso schema di `hashFunction`).
- `syncDir`/`syncFile` guadagnano un parametro `progress: inout ProgressThrottle` senza default, sui metodi privati già commentati in tal senso.
- Nessuna funzione diventa `async`, nessun `Task.detached` cambia posto.

Vedi `.claude/rules/architecture.md`, sezione `FileSyncer`, spec `Docs/superpowers/specs/2026-09-19-remaining-main-thread-work-design.md` §3, piano `Docs/superpowers/plans/2026-09-19-remaining-main-thread-work.md`.
