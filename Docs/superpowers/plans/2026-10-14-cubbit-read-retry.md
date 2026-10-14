# Progetto 4, aggiunta del 2026-10-14: le letture su Cubbit si ritentano da sole

Branch `feature/archive-alignment`, base `0d43588` (1.412 test). **Da far approvare a Enrico, non approvato.**

## Contesto

La corsa vera su Cubbit si è fermata dopo 44.574 copie con `AlignmentStopReason.cubbitError`.
L'ultima riga del registro era un `removed`, quindi l'errore è arrivato in una **lettura**:
`versioning()`/`lifecycleRules()` all'inizio di un blocco, oppure una `head(key:)` della copia
successiva (`ArchiveAligner.runCubbitBlock`). Subito dopo Cubbit rispondeva normalmente. Su
~89.000 copie (~9 ore, ~270.000 richieste) un errore passeggero è quasi certo, e oggi ognuno
ferma la corsa e costringe Enrico a ripartire a mano.

Oggi il progetto 4 non ritenta niente: `S3AlignmentCloud` passa ogni richiesta una volta sola a
`S3Syncer`. L'upload invece ritenta da anni (`S3Syncer.retrying`, `isRetryable`: `URLError`,
5xx, 429; mai un altro 4xx, mai `CancellationError`).

## Cosa cambia

1. **`RetryingAlignmentCloud`** (nuovo, `nonisolated final class`, subito dopo `S3AlignmentCloud`):
   un decoratore di `AlignmentCloud`.
   - `head`, `versioning`, `lifecycleRules`, `versions` passano da `reading { … }`: su un errore
     per cui `S3Syncer.isRetryable` dice sì, aspetta e ritenta, **3 tentativi in più dopo 2, 5,
     15 s** (`defaultDelays`, ~22 s di pazienza per lettura); poi restituisce l'**ultimo** errore
     e il motore si ferma come oggi.
   - `delete` e `removeDeleteMarker` passano **dritte, una volta sola**. Motivo (da scrivere in
     ADR-0019): con le versioni accese un DELETE ripetuto dopo una risposta persa crea un secondo
     segno di cancellazione che il registro non conosce; «Annulla» toglierebbe solo il primo e la
     foto resterebbe nascosta. Lo stesso vale per la rimozione di un segno.
   - Interruzione: `isCancelled` (il `CancelFlag` della corsa) o il task cancellato, controllati
     prima di ogni attesa e subito dopo: nessun tentativo in più, esce con l'ultimo errore.
     L'attesa vera (`pause`) dorme a fette di 250 ms e smette appena arriva «Interrompi».
   - `sleep` iniettabile (i test non aspettano davvero), `delays` iniettabile.
2. **`S3Syncer.isRetryable` diventa `nonisolated static`** (una parola): è pura, e senza
   l'annotazione ogni tentativo chiamato dal motore (fuori dal main) salterebbe sul main thread
   (BUG-7). Nessun cambio per i chiamanti di oggi.
3. **`BackupRunner`**: i tre punti che costruiscono `S3AlignmentCloud` (controllo senza togliere,
   corsa, annullamento) lo avvolgono in `RetryingAlignmentCloud`. Nella corsa e nell'annullamento
   `let flag = CancelFlag()` sale di qualche riga (prima del Cubbit, per passargli
   `{ flag.isCancelled }`); il resto dell'ordine non cambia. Se `beginAlignment()` rifiuta, il flag
   creato si butta: nessun effetto.
4. **Il motore (`ArchiveAligner`) non cambia**, né i testi: dopo i tentativi la corsa si ferma con
   la stessa frase di oggi («Cubbit non ha risposto come doveva: mi sono fermato…»).

La richiesta parlava di due punti (~15350 e ~15407): sono tre, e il terzo è l'annullamento
(~15478). L'ho incluso perché anche lì le letture (regole, HEAD, elenco versioni, HEAD di
verifica) sono sicure da ripetere e un «Annulla» di 2.000 copie fermato a metà da un singhiozzo è
lo stesso problema. Se Enrico preferisce lasciarlo fuori, basta non applicare la quinta patch e
cambiare il conteggio nel test di guardia da 3 a 2.

## Alternative scartate

- **Ritentare dentro `S3Syncer`** (in `headObject`, `bucketVersioning`, …): `headObject` lo usa
  anche la riparazione (ADR-0016) e cambierebbe un comportamento già verificato dal vivo;
  `S3Syncer` è `@MainActor`; i test richiederebbero rete finta (`URLProtocol`). Scartata.
- **Ritentare dentro `ArchiveAligner`**, attorno a ogni chiamata: sei punti da toccare nel motore
  già rivisto, e il rischio concreto di avvolgere per sbaglio il `delete` vicino. Il decoratore lo
  rende impossibile per costruzione (le due scritture non passano da `reading`). Scartata.
- **Ripartire da sola a livello di corsa** (in `BackupRunner`, su `.cubbitError` rifare il
  blocco): grossolana (rilegge versioni e regole, rifà le HEAD già fatte), e dopo un DELETE con
  risposta persa farebbe sembrare normale un caso che oggi giustamente ferma la corsa. Scartata.
- **Classificazione più stretta solo per il progetto 4** (solo `URLError`/5xx/429, non gli altri
  stati che `isRetryable` già considera passeggeri): vedi la decisione D1 sotto.

## Decisioni con un costo da far valutare a Enrico

- **D1 — Quali errori si ritentano.** Uso **la stessa** `S3Syncer.isRetryable` dell'upload, come
  chiesto. Effetto collaterale da sapere: `isRetryable` considera passeggero anche tutto ciò che
  non è un 4xx — quindi anche un 3xx, una risposta «non HTTP» (`statusCode -1`) e i due errori
  che il progetto 4 lancia con `statusCode 200` («elenco versioni illeggibile/troncato», «HEAD
  senza dimensione»). Su una lettura è innocuo (rileggere non cambia niente su Cubbit) e anzi
  utile se il corpo era troncato da una connessione caduta; il costo è al massimo ~22 s in più
  prima di fermarsi su un errore che non passerebbe. Alternativa: una regola più stretta solo qui
  (una funzione in più da tenere allineata). Raccomando di tenere quella comune.
- **D2 — «Interrompi» durante un'attesa.** L'attesa si chiude entro ~¼ s, ma la corsa si ferma
  con la frase di `.cubbitError` («Cubbit non ha risposto come doveva»), non con quella di
  `.interrupted`: è vera (Cubbit non aveva risposto), ma Enrico aveva premuto Interrompi. Per
  dire «interrotta» bisognerebbe toccare il motore (`isCancelled() ? .interrupted :
  .cubbitError(…)` nei cinque `catch` di corsa e annullamento). Non l'ho fatto per tenere il
  motore intatto; è un cambio piccolo se Enrico lo vuole.
- **D3 — Attese 2/5/15 s.** Su un guasto vero la corsa si ferma dopo ~22 s per lettura (fino a
  ~44 s all'inizio di un blocco, versioni + regole) invece che subito. Più tentativi o attese più
  lunghe coprirebbero buchi più lunghi a costo di un'attesa più lunga prima del messaggio.
- **D4 — Anche il «Controlla senza togliere» ritenta.** Lì non c'è «Interrompi»: con Cubbit giù,
  la rotella gira fino a ~22 s prima di mostrare che le versioni non si leggono (la seconda
  lettura non parte se la prima fallisce). Se non lo si vuole, quella riga resta com'è e il test
  di guardia conta 2.

## Rischi

- **DELETE con risposta persa (resta come oggi, fuori da questo intervento).** La corsa si ferma
  con `failed` nel registro, senza la versione del segno: una corsa successiva vede la copia
  «già sparita da Cubbit» e la salta, «Annulla» non sa rimetterla, e la versione della foto resta
  su Cubbit per i giorni della regola (recuperabile a mano dall'elenco versioni). È il motivo per
  cui il DELETE **non** si ritenta. Un passo futuro possibile, non proposto ora: dopo un errore di
  rete sul DELETE, leggere `versions(key:)` e registrare il segno trovato.
- **Più richieste su un Cubbit in difficoltà**: una copia alla volta, al massimo 3 letture in più
  per guasto, con attese crescenti. Trascurabile.
- **La corsa in corso**: questa modifica vale solo per una build nuova. Non installare in
  /Applications mentre gira la corsa vera; dopo l'installazione la corsa si riprende dal
  «Controlla senza togliere» come oggi (il registro sa già cosa è stato tolto).
- **Non coperto da test, dichiarato** (come il resto del cablaggio del progetto 4): che
  `BackupRunner` passi davvero il `flag` giusto. Il test di guardia controlla solo che ogni
  `S3AlignmentCloud` sia avvolto.

## Prototipo (verificato fuori da Xcode)

- Patch: `/private/tmp/claude-501/align-retry/patches/01-align-retry.py` (5 sostituzioni, ogni
  «trova» una volta sola nel `ContentView.swift` di `0d43588`); applicatore
  `/private/tmp/claude-501/align-retry/apply.py` (`REPO=… python3 apply.py`, copia anche i test).
- Test (file esistenti, **nessun file nuovo, nessun ID pbxproj**):
  `tests/AlignmentEngineCubbitTests.swift` (+11 test, `FlakyAlignmentCloud`,
  `AlignmentWaitRecorder`, `engine(cloud:)`), `tests/AlignmentDeleteGuardTests.swift` (+1),
  `tests/MainThreadIsolationTests.swift` (+1).
- Diff di riferimento in `/private/tmp/claude-501/align-retry/diffs/`.
- `fasttest.sh` sullo scratch: **1.425 test, 0 fallimenti, 0 warning app, 0 warning test**.
- Mutanti: `mutants/mutate.py N` + `mutants/run-all.sh N…`, esiti in `mutants/mutants.log`. Tutti e 8 uccisi:

| # | Mutante | Ucciso da |
| :-- | :-- | :-- |
| 1 | niente ritentativi | `testATransientReadError_isRetried_afterTheWaitsInOrder`, `testEveryRead_isRetried`, `testAfterThreeMoreAttempts_…`, `testTheBlockGoesOn_afterATransientErrorInEveryRead`, `testUndo_retriesItsReads_…`, `testInterruptDuringAWait_…`, `MainThreadIsolationTests.testRetryingAlignmentCloud_…` |
| 2 | ritentare anche il DELETE | `testTheDeleteAndTheMarkerRemoval_areNeverRetried`, `testADeleteWhoseAnswerIsLost_isNotSentAgain_andTheRunStops` |
| 3 | ritentare un 403 | `testPermanentErrors_areNotRetried` |
| 4 | `isRetryable` senza `nonisolated` | warning app (1 → «error in Swift 6») e `MainThreadIsolationTests.testRetryingAlignmentCloud_retriesWithoutTheMainThread` |
| 5 | interruzione ignorata dopo l'attesa | `testInterruptDuringAWait_noMoreAttempts` |
| 6 | attesa intera, non a fette | `testTheRealWait_endsSoonAfterAnInterrupt` |
| 7 | corsa con `S3AlignmentCloud` nudo | `AlignmentDeleteGuardTests.testEveryCubbitGivenToTheEngine_retriesItsReads` |
| 8 | ritentare la rimozione del segno | `testTheDeleteAndTheMarkerRemoval_areNeverRetried` |

## Testo per la nota in coda ad ADR-0019

```markdown
## Nota del 2026-10-14 — le letture su Cubbit si ritentano, i DELETE mai

La prima corsa vera su Cubbit si è fermata dopo 44.574 copie su un errore passeggero di Cubbit in
una lettura; subito dopo Cubbit rispondeva normalmente. Su ~89.000 copie (~9 ore, ~270.000
richieste) un errore così è quasi certo. Da qui: le sole **letture** del motore (HEAD, stato
delle versioni, regole di scadenza, elenco versioni) si ritentano da sole su un errore passeggero
(stessa regola dell'upload: rete, 5xx, 429; mai un altro 4xx, mai un'interruzione), 3 volte in
più dopo 2, 5 e 15 secondi, prima di fermare la corsa con lo stesso messaggio di prima.
`RetryingAlignmentCloud`, attorno a `S3AlignmentCloud` nei tre punti di `BackupRunner`.

**Il DELETE senza versione e la rimozione di un segno non si ritentano mai.** Con le versioni
accese un DELETE ripetuto dopo una risposta persa crea un secondo segno di cancellazione che il
registro non conosce, e «Annulla» toglierebbe solo il primo: la foto resterebbe nascosta. Un
errore su una di queste due richieste ferma la corsa subito, come prima.
```

## Riga per `.claude/rules/architecture.md`

Nella sezione «Doppioni su HDD e Cubbit», dopo il punto «Le richieste a Cubbit e la regola delle
versioni (Task 3)»:

```markdown
- **Errori passeggeri (2026-10-14, nota in ADR-0019)** — `RetryingAlignmentCloud` (`nonisolated`, decoratore di `AlignmentCloud`) avvolge `S3AlignmentCloud` nei tre punti di `BackupRunner` (controllo, corsa, annullamento; guardia `testEveryCubbitGivenToTheEngine_retriesItsReads`): `head`/`versioning`/`lifecycleRules`/`versions` si ritentano 3 volte dopo 2/5/15 s se `S3Syncer.isRetryable` (resa `nonisolated` per questo, BUG-7) dice sì; `delete` e `removeDeleteMarker` passano una volta sola, **mai ritentati** (un secondo segno di cancellazione sfuggirebbe al registro e ad «Annulla»). Attesa a fette di 250 ms, chiusa da «Interrompi» (`isCancelled`) o dal task cancellato; `sleep` iniettabile nei test.
```
