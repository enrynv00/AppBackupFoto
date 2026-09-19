# Spec — Indicatore di spazio per SSD, HDD e Cubbit

**Stato: BOZZA, in attesa di approvazione di Enrico.** Niente di questa spec è approvato finché Enrico non lo dice esplicitamente. Le domande aperte sono in fondo: la 1 e la 2 cambiano il piano, le altre sono di rifinitura.

Piano di esecuzione: `Docs/superpowers/plans/2026-09-19-volume-space-indicator.md`.

## Richiesta

Enrico vuole vedere quanto sono pieni i tre posti dove finiscono le sue foto: l'SSD, l'HDD e Cubbit.

### Decisioni già prese da Enrico (non si riaprono)

1. **Dove e come.** Nella sezione «Volumi» di `SidebarView`, sotto ogni volume: una barra sottile, una riga di testo tipo «580 GB liberi su 2 TB» e la percentuale. Colore normale fino all'85%, **arancione sopra l'85%**, **rosso sopra il 95%**.
2. **Cubbit: solo lo spazio usato** (es. «812 GB usati»). Niente barra, niente campo per la dimensione del piano. Il numero si ricava sommando le dimensioni degli oggetti del bucket.

Vincoli di progetto che valgono qui: niente I/O bloccante sul main thread (la lezione di `VolumeMonitor` del 2026-09-03), accesso ai volumi con `FileManager`/Foundation e mai con subprocess, tutto il codice in `ContentView.swift`, niente gergo per un utente non tecnico.

---

## Misure (2026-09-19, SSD e HDD veri collegati)

Fatte dal terminale con il bridge Objective-C di JavaScript for Automation (`osascript -l JavaScript`), che chiama le stesse API Foundation dell'app. Swift da riga di comando in questo momento non parte perché la licenza di Xcode non è accettata. Sono misure di sola lettura.

### Quale chiave di capacità: la domanda aveva una risposta sola

| volume | formato | `volumeTotalCapacity` | `volumeAvailableCapacity` | `…ForImportantUsage` | `…ForOpportunisticUsage` | tempo |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| `/Volumes/SSD - Enri` | **ExFAT (FSKit)** | 1.000.170.717.184 | 448.056.262.656 | **0** | **0** | 9,8 ms |
| `/Volumes/BackupHDD` | APFS | 999.995.129.856 | 611.292.762.112 | 611.293.839.360 | 610.009.305.088 | 18,2 ms |
| `/` (disco interno) | APFS | 494.384.795.648 | 81.671.745.536 | 120.363.860.821 | 100.516.343.053 | 12,7 ms |

**Sull'SSD ExFAT montato via FSKit, `volumeAvailableCapacityForImportantUsageKey` restituisce 0.** Non nil: zero. Un indicatore costruito su quella chiave mostrerebbe l'SSD **pieno al 100%, in rosso, con 0 byte liberi**, cioè un falso allarme permanente sul disco più importante. `df` sullo stesso volume conferma 437.555.072 KiB liberi (≈448 GB), in linea con `volumeAvailableCapacityKey`.

**Decisione: si usa `volumeAvailableCapacityKey`**, la stessa chiave che già usa `BackupRunner.hasSufficientSpace` per bloccare un job quando lo spazio non basta. Il vantaggio è anche di coerenza: la barra nella sidebar e l'avviso «liberi X su …» del controllo di spazio mostrano **lo stesso numero**. Due numeri diversi per la stessa domanda, in due punti dell'app, sarebbero un difetto di per sé.

Cosa si perde: sull'HDD APFS `volumeAvailableCapacity` non conta lo spazio *purgeable* (snapshot locali, cache che il sistema può liberare), e il Finder invece sì. Oggi la differenza misurata è di **1 MB** (611.292.762.112 contro 611.293.839.360): su un disco di backup esterno non c'è quasi niente di purgeable. Se un giorno l'HDD avesse snapshot, la barra lo mostrerebbe un po' più pieno di quanto dica il Finder. È il verso prudente.

Anche la chiave del totale è verificata: `volumeTotalCapacityKey` restituisce il valore corretto su entrambi i formati.

### Letto da una sottocartella, il volume è lo stesso

`/Volumes/SSD - Enri/Foto iPhone` restituisce gli stessi valori della radice, e `volumeURL` = `/Volumes/SSD - Enri/`. Serve alla guardia sul punto di montaggio (vedi sotto).

### Come vengono i numeri formattati

`ByteCountFormatter` con `countStyle = .file` (decimale, come il Finder), locale `it_IT`:

| byte | `isAdaptive = true` (default) | `isAdaptive = false` |
| ---: | :--- | :--- |
| 448.056.262.656 | 448,06 GB | **448 GB** |
| 1.000.170.717.184 | 1 TB | **1 TB** |
| 812.345.678.901 | 812,35 GB | **812 GB** |
| 1.500.000.000.000 | 1,5 TB | **1,5 TB** |
| 1.234.567.890 | 1,23 GB | **1,23 GB** |
| 0 | Zero KB | Zero KB |

**Si usa `isAdaptive = false`**, che dà tre cifre significative: «448 GB liberi su 1 TB» si legge meglio di «448,06 GB». C'è anche un secondo effetto, voluto: con tre cifre il testo cambia ogni GB circa, non ogni 10 MB, e questo è ciò che tiene basso il numero di ridisegni durante una copia (vedi «Cosa si pubblica e quando»). Per lo zero serve `allowsNonnumericFormatting = false`, così si legge «0 byte» invece di «Zero KB».

### Quanto costa contare Cubbit

- **Numero di oggetti.** La richiesta parla di circa 70.000 oggetti; `Docs/ROADMAP.md` (punto 5, 2026-08-02) ne riportava già **120.842**. Il costo cresce in modo lineare, quindi lo stimo su entrambi i valori. **Da misurare davvero** nella verifica manuale.
- **Richieste.** `ListObjectsV2` restituisce al massimo 1.000 chiavi per pagina: **70-121 richieste GET** per un conteggio completo.
- **Dati scaricati.** Ogni voce dell'XML (Key, LastModified, ETag, Size, StorageClass) pesa circa 250-400 byte: **~20-45 MB** in totale. È una stima, non una misura.
- **Tempo.** Dipende dalla latenza di Cubbit per pagina, che non ho misurato. Con 0,3-1,5 s per pagina fa **da ~20 secondi a ~3 minuti**. È la stessa attesa che oggi si paga all'inizio di ogni SSD→Cubbit e di ogni anteprima («Connessione a Cubbit S3 — recupero lista file remoti…»).
- **Soldi.** Cubbit non fa pagare le chiamate API né il traffico in uscita: tariffa fissa per TB al mese ([Cubbit Pricing FAQ](https://help.cubbit.io/pricing-faqs)). Un conteggio costa quindi tempo, non denaro.
- **Memoria.** `listAll` costruisce un dizionario `[chiave: dimensione]`: con 120.000 chiavi sono qualche decina di MB, per pochi secondi. È accettabile, e lo si paga già a ogni sync.

---

## Design

### Parte 1 — SSD e HDD

#### La lettura: `VolumeCapacityReader`

Una funzione `nonisolated` e sincrona, **chiamata solo dalla `probeQueue` di `VolumeMonitor`** e mai dal main thread:

```swift
enum VolumeCapacityReading: Equatable {
    case notAMountPoint                     // il percorso esiste ma non è la radice di un volume
    case unreadable                         // la lettura è fallita, o il totale è 0
    case measured(total: Int64, available: Int64)
}
static func read(path: String) -> VolumeCapacityReading
```

Tre regole, e ognuna ha un motivo misurato o documentato:

1. **Un URL nuovo a ogni lettura** (`URL(fileURLWithPath: path)` dentro la funzione, mai un URL tenuto in una proprietà). `URL.resourceValues` risponde dalla cache dell'istanza, e l'invalidazione automatica di quella cache è legata ai giri del run loop **del main thread**. Su una coda in background senza run loop non è garantito che la cache scada mai: lo conferma Apple DTS in [questo thread](https://developer.apple.com/forums/thread/813641), ed è lo stesso difetto già pagato due volte nel progetto (fatto misurato n. 1 in `.claude/rules/architecture.md`). Con un URL riusato, la barra resterebbe ferma per sempre al primo valore letto. Un secondo caso documentato di valori vecchi dopo una scrittura è [qui](https://developer.apple.com/forums/thread/736115).
2. **Guardia sul punto di montaggio.** Insieme ai due valori si legge `volumeURLKey` e si confronta, **per componenti canoniche** (stessa regola di `canonicalPathComponents`), con il percorso interrogato. Se non coincidono il risultato è `.notAMountPoint`. Il caso non è teorico: se sul disco di sistema esiste una cartella normale chiamata `/Volumes/SSD - Enri` (la lascia una copia fatta mentre l'SSD era scollegato, o uno smontaggio sporco), `fileExists` risponde `true` e la capacità letta sarebbe quella del **Mac**. La sidebar mostrerebbe lo spazio del disco interno sotto il nome dell'SSD.
3. **Chiavi lette:** `.volumeTotalCapacityKey`, `.volumeAvailableCapacityKey` e `.volumeURLKey`. Mai `…ForImportantUsage` (vedi le misure). Un totale ≤ 0, o una lettura che lancia un errore, danno `.unreadable`.

#### Cosa si mostra: `VolumeSpaceState`, logica pura

```swift
enum SpaceLevel: Equatable { case normal, warning, critical }
struct VolumeSpaceDisplay: Equatable {
    let percentUsed: Int          // 0...100, arrotondato per difetto
    let level: SpaceLevel
    let freeLine: String          // "448 GB liberi su 1 TB"
    let accessibilityLabel: String
}
enum VolumeSpaceState: Equatable {
    case disconnected             // → «Non collegato», nessuna barra
    case unreadable               // → «Spazio libero non disponibile», nessuna barra
    case measured(VolumeSpaceDisplay)
    static func from(mounted: Bool, reading: VolumeCapacityReading?) -> VolumeSpaceState
}
```

- **Percentuale** = `floor((totale − disponibile) / totale × 100)`, con il disponibile limitato a `0...totale`. Arrotondare per difetto significa che «100%» compare solo quando il disco è pieno davvero, mai quando restano 4 GB. Barra e testo usano **lo stesso intero**, così quello che si legge e quello che si vede non possono dire cose diverse.
- **Soglie** sullo stesso intero mostrato: `> 85` arancione, `> 95` rosso. Quindi «85%» è ancora normale, «86%» è arancione, «96%» è rosso. Sono le parole di Enrico («sopra l'85%») prese alla lettera, e i confini sono fissati da test.
- `.notAMountPoint` e `.unreadable` producono entrambi `.unreadable`: per l'utente la conseguenza è la stessa. `mounted == false` produce sempre `.disconnected`, qualunque sia la lettura.
- Il testo non contiene gergo: niente «capacità», «volume», «byte» (tranne «0 byte» sul disco pieno), «montato». L'SSD scollegato dice **«Non collegato»**, come richiesto.

#### Cosa si pubblica e quando: il punto delicato

Lo spazio libero cambia di continuo durante una copia (a 200 MB/s sono 600 MB ogni 3 secondi). Se venisse pubblicato così com'è, `VolumeMonitor` tornerebbe a ridisegnare ogni 3 secondi tutte le view che lo osservano: `ContentView`, `RestoreView`, `ImportView`, `DuplicatesView`, `SetupView`. È lo stesso difetto n. 3 corretto il 2026-09-03, e allora si moltiplicava con il ricalcolo di `DuplicateBatch`. Le difese sono due, indipendenti:

1. **Un oggetto osservabile separato.** Lo spazio **non** diventa una `@Published` di `VolumeMonitor`. Si pubblica in `VolumeSpaceModel` (`ObservableObject`, `final class`), esposto come `VolumeMonitor.shared.space`, con due proprietà: `ssd` e `hdd`, entrambe di tipo `VolumeSpaceState`. SwiftUI non propaga il cambiamento di un `ObservableObject` annidato a chi osserva il contenitore: chi osserva `VolumeMonitor` (le cinque view) **non viene ridisegnato** quando cambia lo spazio. Lo osserva solo la piccola view della riga (`VolumeSpaceLine`). È questa la difesa che conta davvero.
2. **Si pubblica solo se cambia quello che l'utente vede.** Il valore pubblicato è `VolumeSpaceState`, che contiene la percentuale intera e il testo già formattato, non i byte grezzi. Il confronto è `!=` su quel valore: se da un giro all'altro spariscono 30 MB, testo e percentuale restano uguali, lo stato è `==` e non si assegna niente. Non serve una soglia inventata: la granularità è quella della formattazione (tre cifre significative, circa 1 GB su un disco da 1 TB) e della percentuale intera.

Durante una copia a 200 MB/s la riga dell'SSD si ridisegna quindi circa una volta ogni 5-6 secondi, e si ridisegna **solo quella**. Ai confini fra due valori (447,9 ↔ 448 GB) il testo può oscillare, ma al massimo una volta per giro di sondaggio (3 s) e sempre sulla sola riga: è un limite accettabile e non serve un'isteresi.

#### Dentro `VolumeMonitor.check()`

- La sequenza sulla `probeQueue` resta quella di oggi: prima `fileExists` sui due percorsi, poi `VolumeCapacityReader.read` **solo** per i volumi presenti, poi `VolumeSpaceState.from(...)`, tutto fuori dal main thread.
- Un solo salto sul main, che pubblica i due booleani (come oggi) e i due stati di spazio, **ognuno solo se cambiato**. Collegamento e spazio si aggiornano quindi nello stesso giro: non c'è un istante in cui l'SSD risulta scollegato con la barra ancora piena.
- **Niente accumulo di sondaggi.** Oggi, se una lettura dura più di 3 secondi (un HDD che si sveglia), il timer accoda un altro `check()` sulla coda seriale, e poi un altro ancora. Si aggiunge un flag `probeInFlight`, letto e scritto **solo sul main thread** (il timer scatta lì e il salto di ritorno arriva lì): se il sondaggio precedente non è finito, il giro si salta. È un cambiamento piccolo e senza lock, e la lettura della capacità rende quel caso un po' più probabile.
- I percorsi restano quelli già scritti in `VolumeMonitor` (`/Volumes/SSD - Enri`, `/Volumes/BackupHDD`): la barra descrive lo stesso volume che il pallino verde dice collegato. Quando il configuratore generico (#27) renderà i dispositivi configurabili, questa parte lo seguirà insieme al resto di `VolumeMonitor`.

#### La UI

`VolumeRow` non cambia firma per Cubbit. Sotto la riga esistente di SSD e HDD compare una `VolumeSpaceLine(kind: .ssd/.hdd)`, che osserva `VolumeMonitor.shared.space`:

- `.measured` → una barra alta 4 pt (`SpaceBar`, disegnata a mano con due `Capsule`, perché su macOS il `.tint` di una `ProgressView` lineare non è garantito), poi sotto una riga `caption` con «448 GB liberi su 1 TB» a sinistra e «55%» a destra (`monospacedDigit`). Rientro allineato al nome del volume (16 + 20 + 8 pt).
- `.disconnected` → solo «Non collegato» in `caption` `.secondary`.
- `.unreadable` → solo «Spazio libero non disponibile» in `caption` `.secondary`.
- Colori: `.normal` usa un nuovo token `AppColor.spaceNormal` (= `Color.accentColor`, vedi la domanda 4), `.warning` usa `AppColor.warning`, `.critical` usa `AppColor.error`. Nessun colore scritto a mano fuori dai token, come vuole la Fase 1 del design (#21).
- Accessibilità: la riga è un solo elemento, con etichetta tipo «SSD - Enri, 448 GB liberi su 1 TB, occupato al 55%».
- `SidebarView` non passa nuovi parametri: `VolumeSpaceLine` legge da sola l'oggetto condiviso, così `SidebarView` non si abbona allo spazio.

### Parte 2 — Cubbit

#### Da dove viene il numero: dai conteggi che l'app fa già

`S3Syncer.listAll(config:)` scarica già l'elenco completo del bucket, con chiave e dimensione, in **sei punti**: all'inizio di ogni SSD→Cubbit (`sync`), nell'anteprima (`previewUpload`), nel ripristino (`downloadMany`, `listAvailableFolders`, `estimateS3Download`) e nel campione d'integrità (`sampleS3Pair`). Sommare le dimensioni di quel dizionario costa microsecondi. **Ogni elenco completo aggiorna quindi lo spazio usato gratis**, e un conteggio dedicato serve solo per il bottone manuale.

**Opzioni valutate:**

| | pro | contro |
| :--- | :--- | :--- |
| **A. Gancio dentro `listAll`** (scelta) | un punto solo, tutti e sei i chiamanti aggiornano il numero; nessun chiamante può dimenticarsene | un effetto collaterale dentro una funzione di rete generica |
| B. Callback esplicita solo su `sync`/`previewUpload` | più esplicito | il numero si aggiorna solo con il backup su Cubbit; ogni nuovo chiamante deve ricordarsi di cablarlo |
| C. Conteggio dedicato periodico/all'avvio | numero sempre fresco | 70-121 richieste di rete a ogni avvio, lettura del Keychain all'avvio (la storia di BUG-2), e la lezione del 2026-09-03 sull'avvio lento |

L'effetto collaterale di A resta piccolo e controllato: `S3Syncer` riceve nell'`init` un `usageSink` iniettabile, con default che pubblica su `CloudUsageStore.shared` passando dal main. I test ne passano uno che registra le chiamate.

#### La regola che non si può sbagliare: solo un elenco *completo*

`listAll` oggi esce dal ciclo in silenzio se `cancelled || Task.isCancelled`, e **restituisce un dizionario troncato senza errore**. Se il gancio sommasse quel dizionario, un'interruzione a metà registrerebbe «300 GB usati» al posto di 812, e un'interruzione prima della prima pagina registrerebbe **«0 byte usati»**.

E non è un caso raro: dopo uno stop di un job, `runner.s3Syncer` resta con `cancelled = true`. `sync()` lo azzera, ma `previewUpload()` no. Quindi **un'anteprima SSD→Cubbit fatta dopo aver interrotto un backup ottiene un elenco vuoto** (vedi «Scoperte collaterali»). Con un gancio ingenuo, quell'anteprima scriverebbe «0 byte usati» nella sidebar.

Perciò il ciclo di paginazione si estrae in una funzione statica testabile senza rete:

```swift
struct S3Listing { let objects: [String: Int64]; let isComplete: Bool }
static func collectPages(fetch: (String?) async throws -> ([String: Int64], String?),
                         shouldStop: () -> Bool) async throws -> S3Listing
```

`isComplete` vale `true` **solo** se il ciclo è uscito perché il token di continuazione è `nil`. Un'uscita per `shouldStop` dà `false`, anche con zero pagine lette. `listAll` diventa un involucro che chiama `collectPages` con `listPage` e il flag `cancelled`, notifica il sink **solo se `isComplete`**, e restituisce `objects` come oggi. **I sei chiamanti non cambiano**: la firma di `listAll` resta identica, e con lei il comportamento, troncamento silenzioso compreso (correggerlo è fuori scope, vedi sotto).

#### Il numero dopo un backup su Cubbit: si corregge, non si ricalcola

`sync()` elenca il bucket **all'inizio**. Se il numero registrato fosse solo quello, dopo un backup che carica 20 GB la sidebar mostrerebbe il valore di prima proprio nel momento in cui Enrico la guarda. La correzione è però esatta e non costa niente: per la regola zero-overwrite `sync` carica **solo chiavi assenti** (`shouldUpload`), quindi lo spazio usato dopo il job è `elencato + uploadedBytes`, e gli oggetti sono `elencati + uploaded`.

Regola, in una funzione pura `CloudUsageTotals.afterSync(listed:uploadedBytes:uploadedCount:wasCancelled:)`:
- si applica solo se l'elenco iniziale era completo **e** il job non è stato interrotto. Dopo uno stop il ciclo degli esiti scarta con `continue` anche i caricamenti finiti, quindi `uploadedBytes` sarebbe **per difetto**;
- con errori su alcuni file la correzione resta esatta, perché `uploadedBytes` conta solo gli esiti `ok`;
- in tutti gli altri casi non si corregge e resta il valore registrato all'inizio, con la sua data. È più vecchio, ma non è sbagliato.

Lo registra `sync()` stessa, alla fine, tramite lo stesso sink: un meccanismo solo, dentro `S3Syncer`.

#### Persistenza: `CloudUsageSnapshot` + `CloudUsageStore`

```swift
struct CloudUsageSnapshot: Codable, Equatable {
    let usedBytes: Int64; let objectCount: Int; let measuredAt: Date; let bucket: String
}
```

- Si salva in `UserDefaults` (chiave `cloudUsageSnapshot`, JSON), con i `defaults` iniettabili per i test come `JobHistoryStore`. Così il numero **si vede anche ad app appena aperta**, con la sua data.
- **`init(from:)` esplicita con `decodeIfPresent` fin dal primo giorno** (regola nata dal fatto misurato n. 5): un campo aggiunto domani non deve far sparire in silenzio il valore salvato. Un record illeggibile vale «mai misurato» e non fa crashare niente.
- `CloudUsageStore` è un `ObservableObject` singleton `@MainActor`, osservato **solo** dalla riga di Cubbit. Espone `snapshot`, `isRefreshing` e `lastRefreshFailed`. La lettura di `UserDefaults` all'avvio è in memoria e non tocca né la rete né il Keychain.
- `objectCount` si salva e non si mostra: serve per diagnosticare, e a misurare il costo del conteggio.

#### Il testo

Logica pura in `CloudUsageText`, con `now`, `Calendar` e `Locale` iniettati:
- riga principale: **«812 GB usati»** (stessa formattazione dei dischi);
- riga della data: **«aggiornato oggi alle 14:32»**, «aggiornato ieri alle 09:10», «aggiornato il 3 settembre», «aggiornato il 3 settembre 2025» se l'anno è diverso;
- mai misurato: **«Spazio usato non ancora calcolato»**, con il suggerimento «si aggiorna al prossimo backup su Cubbit»;
- mentre il conteggio è in corso: «Sto calcolando lo spazio usato…», con una piccola rotella;
- conteggio fallito: resta il valore precedente, e sotto compare «Cubbit non raggiungibile, riprova più tardi» in `.secondary`. Nessun alert modale per un'informazione accessoria.

Nessuna di queste frasi contiene «bucket», «oggetti», «S3», «elenco» o «byte».

#### Aggiornamento manuale: raccomandato, piccolo e con un freno

**Costo:** vedi le misure. Da 20 secondi a 3 minuti di attesa in background, nessun costo economico, nessun effetto sui dati (una `GET` di elenco non scrive niente).

**Raccomandazione: sì**, perché senza un backup su Cubbit recente il numero può restare vecchio di settimane, e a Enrico non resterebbe modo di aggiornarlo. Com'è fatto:
- un bottone ↻ piccolo, senza bordo, sulla riga della data di Cubbit, con `.help("Ricalcola lo spazio usato su Cubbit. Può richiedere un paio di minuti.")`;
- **disattivato con il motivo scritto** (logica pura `CloudUsageRefreshGate.disabledReason`) mentre gira un job («Disponibile a backup finito: un backup su Cubbit lo aggiorna già da solo») o mentre un conteggio è già in corso. Non si possono avviare due conteggi insieme;
- **un'istanza di `S3Syncer` dedicata**, non `runner.s3Syncer`: quella condivide il flag `cancelled` con i job, e dopo uno stop darebbe un elenco vuoto (vedi sopra);
- la configurazione passa da `runner.loadS3ConfigIfNeeded()`, cioè al massimo una lettura del Keychain per avvio (fix di BUG-2). Il bottone sta nella finestra principale, dove quella lettura avviene già;
- nessun annullamento: il conteggio non ha effetti e non compete con niente. Alla chiusura dell'app si perde, e il numero registrato resta quello precedente.

**Scartato:** l'aggiornamento automatico all'avvio o periodico (opzione C della tabella sopra). Se Enrico lo volesse, per esempio «all'avvio se il dato ha più di 7 giorni», è un'aggiunta di poche righe su questo stesso design, ma paga rete e Keychain all'avvio: va deciso esplicitamente (domanda 2).

#### Cosa il numero di Cubbit non conta, detto qui una volta

- **Le parti di upload multipart orfani**: occupano spazio sul bucket, ma `ListObjectsV2` non le elenca. Si vedono e si puliscono in Tools → Revisione (BUG-6). Il numero mostrato può quindi essere un po' più basso di quello che Cubbit fattura.
- **Oggetti caricati da altri strumenti dopo l'ultimo conteggio.** È un'app per un solo utente, quindi il caso è teorico.
- Il bucket non ha il versioning attivo (BUG-3), quindi non ci sono versioni nascoste da contare.

### Localizzazione e `Localizable.xcstrings`

L'app è solo in italiano per decisione esplicita (roadmap #14). Le frasi costruite dalla logica pura (`VolumeSpaceState`, `CloudUsageText`, `CloudUsageRefreshGate`) arrivano alla view come `String` e finiscono in `Text(verbatim:)`/`Text(String)`, **fuori dal catalogo**: è lo stesso schema di `LibraryIndexStatus`, `DuplicatesStatus` e `IntegritySummary`, ed è ciò che permette di testarle. I pochi letterali scritti direttamente in `Text("…")` dentro le view (per esempio l'`help` del bottone) vengono aggiunti al catalogo **dal compilatore al momento del build** (`SWIFT_EMIT_LOC_STRINGS`). **Il catalogo non si modifica a mano.** Se il build lo aggiorna, il diff di `Localizable.xcstrings` va nel commit del task che l'ha prodotto.

### Cosa NON cambia

- `ssdMounted`/`hddMounted`: stessa semantica, stessi percorsi, e i bottoni della sidebar si abilitano come oggi. La guardia sul punto di montaggio vale **solo** per lo spazio (vedi «Scoperte collaterali»).
- `hasSufficientSpace` e il controllo di spazio prima dei job: non si toccano.
- La firma di `listAll` e il comportamento dei suoi sei chiamanti.
- Nessuna scrittura su SSD, HDD o Cubbit. Tutto quello che questa feature fa è leggere: `statfs` tramite Foundation e `GET` di elenco su S3.

---

## Test

Logica pura e file veri su directory temporanee, niente mock, come il resto della suite.

| file | cosa fissa |
| :--- | :--- |
| `VolumeSpaceDisplayTests.swift` | soglie ai confini (85 normale, 86 arancione, 95 arancione, 96 rosso); arrotondamento per difetto (99,9% → 99, mai 100 con spazio libero); disponibile > totale limitato; totale 0 → `.unreadable`; `mounted == false` → `.disconnected` anche con una lettura valida; **due letture che differiscono di 30 MB producono stati `==`** (il test che protegge dai ridisegni); una differenza di 2 GB produce stati `!=`; il cambio di livello a parità di testo produce `!=`; composizione del testo «X liberi su Y»; parole vietate assenti |
| `VolumeCapacityReaderTests.swift` | `/` → `.measured` con totale > 0 e disponibile ≤ totale; **una cartella normale in una directory temporanea → `.notAMountPoint`**, non la capacità del disco che la contiene; percorso inesistente → `.unreadable`; confronto per componenti (slash finale, `/private` sulla directory temporanea) |
| `S3ListingTests.swift` | `collectPages` con un fetcher finto: tutte le pagine → completo, con le chiavi unite; **stop prima della prima pagina → incompleto e vuoto**; stop a metà → incompleto; un fetch che lancia → lancia; `CloudUsageTotals` somma byte e conteggio; `afterSync` corregge solo se completo e non interrotto |
| `CloudUsageStoreTests.swift` | salva e rilegge; defaults vuoti → nil; JSON corrotto → nil senza crash; record con un campo mancante → decodificato (`decodeIfPresent`); `record` aggiorna `snapshot` |
| `CloudUsageTextTests.swift` | «usati»; oggi, ieri, stessa annata, anno diverso (con `Calendar` e `Locale` `it_IT` e fuso fissati); mai misurato; parole vietate assenti; `CloudUsageRefreshGate`: job in corso → motivo, conteggio in corso → motivo, altrimenti nil |

**Non coperto, e dichiarato** (stessa disciplina di #31): `VolumeSpaceLine`, `SpaceBar`, la riga di Cubbit, il bottone ↻, il cablaggio in `VolumeMonitor.check()` (timer, `probeInFlight`, salto sul main), `CloudUsageStore.refresh` sulla rete vera e il sink di default. Sono SwiftUI, timer e rete: non si raggiungono senza una corsa vera. **È testato tutto ciò che sta ai due capi del cablaggio.** Il resto va nella verifica manuale.

---

## Rischi

1. **Ridisegni durante una copia.** La mitigazione è strutturale (oggetto separato), non solo numerica. Il rischio residuo è che qualcuno un giorno «semplifichi» spostando lo spazio in una `@Published` di `VolumeMonitor`: il doc-comment di `VolumeSpaceModel` deve dire perché è separato, e citare il bug del 2026-09-03.
2. **HDD che non va più a dormire.** Leggere la capacità ogni 3 secondi può impedire lo spegnimento del disco? Probabilmente no: `fileExists` fa già una `stat()` ogni 3 secondi sullo stesso volume, e `statfs` su APFS legge dati tenuti in memoria. **Non l'ho verificato**, ed è nella verifica manuale.
3. **Capacità di ExFAT/FSKit che cambia comportamento con un aggiornamento di macOS.** Oggi `volumeAvailableCapacityKey` funziona e `…ForImportantUsage` no. Se un domani anche la prima rispondesse 0, la guardia `total > 0` non basterebbe: si vedrebbe «0 byte liberi», in rosso. Il test su `/` non lo coglierebbe, perché gira sull'APFS interno. La contromisura è nella verifica manuale e nel fatto misurato da aggiungere ad `architecture.md`, così chi aggiorna macOS sa cosa ricontrollare.
4. **Il numero di Cubbit può essere vecchio.** È il prezzo di non contare all'avvio. Lo si dichiara mostrando sempre la data, mai un numero senza «aggiornato il…».
5. **Durata del conteggio manuale non misurata.** La stima va da 20 secondi a 3 minuti. Se nella verifica risultasse molto più lunga, il testo di `.help` va corretto con il numero vero (è la stessa lezione di «dai 5 ai 15 minuti» di #31).

## Fuori scope

- La capacità del Mac (`Macintosh HD`): non è stata chiesta.
- Una barra per Cubbit o un campo per la dimensione del piano: escluso da Enrico.
- Avvisi o notifiche quando un disco supera una soglia: qui c'è solo il colore.
- Correggere il troncamento silenzioso di `listAll` per gli altri cinque chiamanti (vedi sotto).

## Scoperte collaterali (non corrette qui, da decidere)

1. **Probabile bug esistente: l'anteprima SSD→Cubbit dopo uno stop mostra numeri sbagliati.** `BackupRunner.stop()` chiama `s3Syncer.cancel()`, e il flag `cancelled` resta `true` finché un `sync()` o un `downloadMany()` non lo azzera. `previewUpload()` non lo azzera, e `listAll` esce prima della prima pagina: l'anteprima dice che **tutti** i file locali sono «da caricare» e che nessuno è già presente. L'ho trovato leggendo il codice e **non l'ho verificato empiricamente**. Non fa danni ai dati: il `sync()` successivo azzera il flag ed elenca davvero. Ma mostra un numero falso. Si corregge con una riga (`cancelled = false` in testa a `previewUpload`), che però tocca un percorso fuori da questa feature: la propongo come ticket separato. Questa spec se ne difende comunque con la regola di completezza.
2. **`hasSufficientSpace` legge la capacità dal main thread** (gira dentro un `Task { @MainActor }`). È la stessa classe di problema di `VolumeMonitor`, ma avviene una volta per job e non ogni 3 secondi: di solito costa 10-18 ms, e qualche secondo se l'HDD dorme. Potrebbe riusare `VolumeCapacityReader` fuori dal main in un intervento separato.
3. **`ssdMounted` è vero anche per una cartella normale al posto del volume** (vedi la guardia sul punto di montaggio). Oggi abiliterebbe i bottoni dei job su una cartella del disco interno. `isLikelyVolumeRoot` e i bookmark lo mitigano in parte. Estendere la guardia a `ssdMounted` cambierebbe l'abilitazione dei bottoni, quindi è una decisione a parte.

---

## Domande aperte per Enrico

1. **Il bottone ↻ per Cubbit: lo vuoi?** Raccomando di sì, così com'è descritto sopra: sempre visibile, piccolo, disattivato durante i backup. L'alternativa è niente bottone, e il numero si aggiorna solo con backup, anteprime, ripristini e controlli d'integrità.
2. **Aggiornamento automatico di Cubbit all'avvio, se il dato è vecchio?** Raccomando di no, per il costo all'avvio e la lettura del Keychain. Se lo vuoi, dimmi dopo quanti giorni il dato è da considerare vecchio.
3. **La percentuale da sola («55%») o con una parola («55% occupato»)?** Raccomando da sola, perché accanto alla barra si capisce e la sidebar è stretta (220-260 pt). L'etichetta di accessibilità dice comunque «occupato al 55%».
4. **Colore «normale» della barra:** il colore di sistema (quello scelto in Impostazioni di Sistema, come le altre barre dell'app) o il colore di ogni destinazione (blu per l'SSD, verde acqua per l'HDD)? Raccomando il colore di sistema: i colori delle destinazioni oggi indicano le operazioni, non i dischi.
5. **I confini delle soglie:** «sopra l'85%» l'ho letto come 86% e oltre (e 96% e oltre per il rosso). Va bene così?

## Fonti

- [Cubbit — Pricing & Billing FAQs](https://help.cubbit.io/pricing-faqs): nessun costo per chiamate API o traffico in uscita.
- [Apple Developer Forums — NSURL: i valori in cache vengono davvero rimossi a ogni giro del run loop?](https://developer.apple.com/forums/thread/813641): l'invalidazione è legata al run loop del main thread.
- [Apple Developer Forums — Force Refresh Volume to Get Current Amount of Free Bytes](https://developer.apple.com/forums/thread/736115): valori di spazio libero vecchi dopo una scrittura.
