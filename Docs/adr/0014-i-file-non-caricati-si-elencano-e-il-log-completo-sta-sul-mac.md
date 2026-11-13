# ADR-0014 — I file non caricati su Cubbit si elencano, e il registro completo di ogni job sta sul disco del Mac

**Data:** 2026-10-27
**Stato:** Accettata

## Contesto

Il 2026-09-26 un backup SSD → Cubbit si è chiuso con 102 errori e nessun nome: il `catch` del task di ogni file in `S3Syncer.sync` contava l'errore e basta, e le 99 righe di nuovo tentativo non dicevano il motivo. Il registro salvato dalla scheda Log era lungo esattamente 60.000 caratteri e cominciava a metà di una riga: `BackupRunner.output` è tagliato a `maxOut`, e «Salva» esportava quello. Le righe non avevano orario, quindi non si poteva distinguere un minuto di rete caduta da ore di Cubbit lento. La causa (una VPN accesa) l'ha trovata Enrico a mano. Numeri di ADR (0014) e ROADMAP (#43) erano stati lasciati liberi apposta il 2026-09-26. Piano: `Docs/superpowers/plans/2026-09-26-s3-upload-failures-visible.md`.

## Opzioni valutate

- **Alzare `maxOut`.** Scartata: la `Text` della scheda Log ridisegna tutta la stringa a ogni riga, lo stesso problema di prestazioni chiuso da ADR-0010; e un tetto più alto si supera comunque con un primo backup completo (~120.000 righe).
- **Solo l'elenco dei file non caricati nel riepilogo di fine job.** Non basta: si perde chiudendo il foglio, e non dice cosa è successo prima.
- **Il registro completo su file (scelta).** Un file per job in `~/Library/Logs/AppBackupFoto/`, sul disco del Mac: mai sull'SSD o sull'HDD, che sono archivi di foto, e lì dove macOS tiene i registri delle app (si apre anche con Console). L'ora su ogni riga. «Salva» esporta il file intero.
- **Conservazione:** tenere tutto (i file crescono per sempre: un primo backup verso Cubbit scrive qualche MB) oppure gli ultimi 50 job (scelta).
- **Tentativi:** restare a 3 (attese 1 e 2 s) oppure 5 (attese 1, 2, 4, 8 s, scelta); e, con 5, far sentire al gate adattivo anche i tentativi falliti poi riusciti oppure no (scelta: no, per ora).
- **Ritentativi condivisi con il progetto 4** (`RetryingAlignmentCloud`): scartato. Hanno in comune la sola regola su cosa è passeggero (`S3Syncer.isRetryable`), che resta una; per il resto lì si ritentano letture con attese lunghe che «Interrompi» spezza, qui scritture del backup con una riga di log.

## Decisione e motivo

Ogni file che non si carica lascia una riga «Non caricato: «percorso» — motivo» e finisce in `S3Syncer.SyncResult.failures`; `errors` e `failures` si muovono insieme, da un solo punto. Ogni nuovo tentativo dice il motivo. Il riepilogo di fine job elenca al massimo 8 file più «…e altri N», e l'elenco completo va in fondo al registro. Il registro di ogni job va in un file con l'ora su ogni riga; si tengono gli ultimi 50. I tentativi passano a 5, con attese 1, 2, 4, 8 secondi. Lezione: un contatore di errori senza l'elenco di cosa è fallito non è una diagnosi, è un allarme.

**Cosa si accetta di perdere.** (1) Il gate adattivo continua a ricevere un solo esito per unità di lavoro, quello finale: con 5 tentativi più errori si risolvono prima della fine, e il gate rallenta meno spesso di prima. Se i motivi raccolti diranno congestione, si farà sentire al gate anche ogni tentativo fallito; se diranno connessioni chiuse da Cubbit, no. (2) Uno slot resta occupato più a lungo: fino a 15 s di attese in più, fino a ~25 minuti se ogni tentativo scade dopo 300 s. (3) La conservazione è una cancellazione nuova (`removeItem`): solo file regolari con il nome esatto `backup_AAAA-MM-GG_hh-mm-ss.log`, direttamente nella cartella dei log dell'app, mai quello del job che parte, mai sotto `/Volumes` nemmeno passando da un collegamento. Nessuna foto può arrivarci. (4) Le righe che arrivano dopo la chiusura del job (aggiornamenti in ritardo) si vedono nell'app ma non nel file; l'elenco dei file non caricati entra prima, in modo sincrono. (5) Lo stesso buco nelle copie locali (`FileSyncer.syncFile`) resta: ticket a parte (ROADMAP #49). Seguito per le copie locali: ADR-0020.

**Per riaprire questa decisione** serve un backup vero in cui i motivi nel registro mostrino che 5 tentativi non bastano o sono troppi, o che il gate dovrebbe sentire i tentativi intermedi.

## Risposte di Enrico (2026-10-27)

D1 = A (ultimi 50 registri), D2 = A (codice fra parentesi nell'app e nel file), D3 = A (gate invariato, si misura prima), D4 = A (copie locali in un ticket a parte), D5 = A (registro per tutti i job), D6 = A (ora su ogni riga del file).

## Conseguenze

- Tipi nuovi, tutti `nonisolated`: `FailedFile`, `S3UploadText`, `UploadFailureSummary`, `S3Syncer.FileUploadOutcome`, `JobLogFile`. Funzione nuova `S3Syncer.runWithRetry`; `retrying` ne diventa un involucro e perde il parametro `maxAttempts`.
- `FileSyncer.SyncResult.failedFiles` e `JobStats.failedFiles` (non persistiti); `SpeedLogPanel` riceve `onSave`.
- Nessuna richiesta S3 nuova; nessuna riga cambiata in `AdaptiveUploadGate`, `isRetryable`, `RetryingAlignmentCloud`.
