# ADR-0008 — Spazio dei volumi letto fuori dal main e pubblicato a parte

**Data:** 2026-09-19
**Stato:** Accettata

## Contesto

Enrico vuole vedere quanto sono pieni SSD, HDD e Cubbit: una barra e «X liberi su Y» per i due dischi, «X usati» per Cubbit. Spec: `Docs/superpowers/specs/2026-09-19-volume-space-indicator-design.md`. Piano: `Docs/superpowers/plans/2026-09-19-volume-space-indicator.md`.

Spec e piano sono stati scritti prima di due lavori arrivati su `main` lo stesso giorno: il fix di isolamento MainActor (BUG-7, ADR-0006, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` con `nonisolated` annotato esplicitamente dove serve, `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` in Debug) e il passo 2 del backup (ADR-0007, `BackupRunner.run` finisce in due tempi: `finishCopyStep`/`finishJob`). Questo ADR numera 0008 perché 0006 e 0007 sono già presi da quei due lavori.

Due questioni tecniche misurate durante il brainstorming, entrambe nella spec:

1. **Quale chiave di capacità.** Sull'SSD ExFAT montato via FSKit, `volumeAvailableCapacityForImportantUsageKey` restituisce **0**, non `nil`: un indicatore costruito su quella chiave mostrerebbe l'SSD pieno al 100%, in rosso, sempre. `volumeAvailableCapacityKey` risponde correttamente (448 GB liberi, confermato con `df`), ed è la stessa chiave già usata da `BackupRunner.hasSufficientSpace`.
2. **Come contare Cubbit senza pagare rete/Keychain all'avvio.** `S3Syncer.listAll` fa già un elenco completo del bucket in sei punti dell'app (sync, anteprima, restore, campione d'integrità). Sommare le dimensioni di quell'elenco è gratis, ma solo se l'elenco è **completo** — dopo uno stop, `listAll` esce dal ciclo in silenzio e restituisce un dizionario troncato senza errore.

## Opzioni valutate

**Per la lettura di capacità.** Nessuna alternativa reale a `volumeAvailableCapacityKey`: l'altra chiave misurata restituisce 0 su ExFAT/FSKit, e non esiste una terza chiave Foundation per lo stesso dato. La vera scelta era *dove* farla girare: sul main (come oggi fa `hasSufficientSpace`, side-finding non corretto qui, vedi «Scoperte collaterali» della spec) o sulla `probeQueue` già esistente di `VolumeMonitor`, `nonisolated` per poterla chiamare da lì senza saltare sul main (BUG-7, classe A). Scelta la seconda: `VolumeMonitor` già fa `stat()` fuori dal main ogni 3s, è il posto naturale.

**Per l'oggetto osservabile.** A) una nuova `@Published` su `VolumeMonitor` stesso (scartata: propagherebbe `objectWillChange` a tutte le cinque view che osservano `VolumeMonitor`, ogni volta che cambia lo spazio — lo stesso difetto n. 3 del 2026-09-03 su `VolumeMonitor`, che questa feature aggraverebbe invece di risolvere); B) un `ObservableObject` annidato separato, osservato solo dalla riga che mostra la barra (scelta: SwiftUI non propaga il cambiamento di un `ObservableObject` annidato a chi osserva il contenitore).

**Per il numero di Cubbit.** A) agganciare la somma dentro `listAll` con un sink iniettabile, notificato solo se l'elenco è completo (scelta: un punto solo, tutti e sei i chiamanti aggiornano il numero gratis); B) una callback esplicita solo su `sync`/`previewUpload` (scartata: il numero si aggiornerebbe solo col backup su Cubbit, e ogni nuovo chiamante di `listAll` dovrebbe ricordarsi di cablarla); C) un conteggio dedicato periodico o all'avvio (scartata: 70-121 richieste di rete e una lettura del Keychain a ogni avvio, la stessa classe di problema di BUG-2, più la lezione del 2026-09-03 sull'avvio lento).

## Decisione e motivo

- **`VolumeCapacityReader.read(path:)`**: funzione `nonisolated`, sincrona, chiamata solo dalla `probeQueue` di `VolumeMonitor`. Usa `volumeAvailableCapacityKey`, mai `…ForImportantUsage`. Un `URL` nuovo a ogni chiamata (mai tenuto in una proprietà: la cache di `resourceValues` fuori dal main non è garantita scadere) e una guardia sul punto di montaggio (`volumeURLKey` confrontato per componenti canoniche con `realResolvedPath`/`canonicalPathComponents`, la fonte unica già in uso da `LibraryIndexer`/`ReviewEngine`): senza, una cartella normale lasciata al posto dell'SSD scollegato farebbe leggere la capacità del disco interno sotto il nome dell'SSD.
- **`VolumeSpaceModel`**, `ObservableObject` separato, esposto come `VolumeMonitor.shared.space`, con `ssd`/`hdd: VolumeSpaceState`. Pubblica solo se il valore (percentuale intera + testo già formattato, non i byte grezzi) è cambiato — stessa disciplina già in `VolumeMonitor.check()` per `ssdMounted`/`hddMounted`.
- **`S3Syncer.collectPages`**: il ciclo di paginazione estratto in una funzione statica testabile, con `S3Listing.isComplete` vero **solo** se il ciclo è uscito perché il token è `nil`. Il sink (`CloudUsageSink`, iniettato nell'`init` di `S3Syncer` con un default che scrive su `CloudUsageStore.shared`) viene chiamato solo se `isComplete`. Dopo un `sync()`, il numero si **corregge** (`CloudUsageTotals.afterSync`) sommando gli upload riusciti invece di rifare un secondo elenco — esatto per la regola zero-overwrite (si caricano solo chiavi assenti), e solo se l'elenco iniziale era completo e il job non è stato interrotto.
- **`CloudUsageStore`**: persistenza in `UserDefaults`, `init(from:)` esplicita con `decodeIfPresent` fin dal primo giorno (regola del fatto misurato n. 5 di #31, non da riscoprire una terza volta). Il ricalcolo manuale (bottone ↻) usa una **`S3Syncer()` dedicata**, non quella dei job: condividere `cancelFlag` con un job in corso darebbe un elenco vuoto dopo uno stop.

**Deviazioni dal piano originale, dichiarate:**

1. **Colore della barra: quello di ogni destinazione, non un token unico legato all'accent di sistema.** La spec raccomandava un solo `AppColor.spaceNormal = Color.accentColor` (domanda aperta 4, risposta "raccomando il colore di sistema"). Enrico ha deciso il contrario: il colore di ogni destinazione (`AppColor.macToSSD`, blu, per l'SSD; `AppColor.ssdToHDD`, teal, per l'HDD) — la palette di `AppColor` (2026-08-12) li aveva già assegnati a queste destinazioni. Verificato che né il blu né il teal sono confondibili con `AppColor.warning` (arancione) o `AppColor.error` (rosso): sono tre hue diversi sulla ruota (blu/teal contro arancione/rosso), non serve scegliere un colore più lontano. Nessun `AppColor.spaceNormal` nuovo: `VolumeSpaceLine` riceve il colore normale come parametro dal chiamante (`kind` già lo implica).
2. **Soglie: confermate 86%/96% incluse**, come proposto dalla spec e confermato da Enrico — nessuna deviazione, ma la spec la marcava come domanda aperta (5) e ora è chiusa.
3. **Testo: solo la percentuale**, come proposto dalla spec e confermato da Enrico (domanda 3) — nessuna deviazione.
4. **Bottone ↻ per Cubbit: sì**, come raccomandato dalla spec e confermato da Enrico (domanda 1) — Task 7 Step 3 del piano si esegue.
5. **Aggiornamento automatico di Cubbit all'avvio: no**, come raccomandato dalla spec e confermato da Enrico (domanda 2) — nessuno step aggiuntivo.
6. **Side-finding della spec su `S3Syncer.cancelled` da riverificare** (nota dell'orchestratore): confermato sul codice attuale che `S3Syncer` non ha più un `private var cancelled = false` nudo — usa `CancelFlag` (`cancelFlag.isCancelled`, ADR-0006) dal fix di isolamento MainActor. Il comportamento che la spec descrive («dopo uno stop il flag resta true finché un `sync()`/`downloadMany()` non lo azzera») resta **identico** con `CancelFlag`: `cancel()` chiama `cancelFlag.cancel()`, `sync()`/`downloadMany()` chiamano `cancelFlag.reset()` in testa, `previewUpload()` non lo fa — lo stesso side-finding («l'anteprima SSD→Cubbit dopo uno stop mostra un elenco vuoto») resta vero, non è stato introdotto né corretto da questo lavoro, e resta fuori scope come dichiarato dalla spec.
7. **Punto di aggancio della correzione del passo 2**: la spec parlava genericamente di «`sync()` elenca il bucket all'inizio» — sul codice attuale `sync()` (SSD→Cubbit) è una funzione unica che non passa per `finishCopyStep`/`finishJob` (quelli sono di `BackupRunner.run`, il passo che copre Mac→SSD/import con l'elenco foto, non SSD→Cubbit). `S3Syncer.sync()` resta la funzione giusta e unica dove agganciare `CloudUsageTotals.afterSync`: nessun conflitto con ADR-0007, che riguarda un passo 2 diverso (la scansione dell'indice foto, non lo spazio Cubbit).

**Cosa si accetta di perdere**: il numero di Cubbit può essere vecchio di settimane se non si fa mai un ↻ o un'operazione che elenchi il bucket — mitigato mostrando sempre la data. Sull'HDD APFS lo spazio *purgeable* non è contato (differenza misurata: 1 MB, irrilevante su un disco esterno). Le parti di upload multipart orfane non entrano nel conteggio Cubbit (si vedono e si puliscono altrove, Tools → Revisione).

**Per riaprire questa decisione** servirebbe un argomento nuovo — per esempio se `…ForImportantUsage` iniziasse a rispondere correttamente su ExFAT/FSKit con un futuro aggiornamento macOS, o se il costo di un conteggio Cubbit scendesse abbastanza da rendere sensato un aggiornamento automatico all'avvio.

## Conseguenze

- `VolumeMonitor.check()` guadagna una lettura di capacità (solo per i volumi presenti) e un flag `probeInFlight` (letto/scritto solo sul main) contro l'accumulo di sondaggi se una lettura dura più di 3s.
- `S3Syncer.listAll` non cambia firma né comportamento visibile ai sei chiamanti esistenti — il troncamento silenzioso su stop resta, dichiarato fuori scope (già lo era nella spec).
- Nessuna scrittura su SSD, HDD o Cubbit: solo `statfs` via Foundation e `GET` di elenco S3.
- Nessuno schema SQLite toccato. Nuova chiave `UserDefaults` (`cloudUsageSnapshot`) per la persistenza del numero Cubbit.
