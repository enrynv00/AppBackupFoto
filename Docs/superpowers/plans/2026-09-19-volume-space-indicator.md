# Indicatore di spazio per SSD, HDD e Cubbit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Stato: BOZZA, non approvato.** Spec di riferimento: `Docs/superpowers/specs/2026-09-19-volume-space-indicator-design.md`. **Non partire prima che Enrico abbia approvato la spec e risposto alle sue domande aperte.** La risposta 1 (bottone ↻) decide se il Task 7, Step 3, si fa; la 2 (aggiornamento all'avvio) aggiungerebbe uno step che qui non c'è. Le risposte 3-5 cambiano solo stringhe e un token, ma i test dei Task 1 e 6 le fissano, quindi vanno lette prima.

**Goal:** Sotto SSD e HDD nella sidebar, una barra e «X liberi su Y · N%», colorata a soglie. Sotto Cubbit, «X usati · aggiornato …», persistito fra un avvio e l'altro. Tutto senza I/O sul main thread e senza far ridisegnare ogni 3 secondi le view che osservano `VolumeMonitor`.

**Architecture:** Le letture di capacità girano sulla `probeQueue` già esistente di `VolumeMonitor`, con un URL nuovo a ogni giro e una guardia sul punto di montaggio. Lo stato mostrato (percentuale intera e testo già formattato) si pubblica in un `ObservableObject` **separato** (`VolumeSpaceModel`) e solo se cambia. Per Cubbit il numero si somma dagli elenchi **completi** che `S3Syncer.listAll` fa già, tramite un sink iniettabile. Si corregge in modo esatto a fine sync, si salva in `UserDefaults`, e si può ricalcolare a mano con un'istanza dedicata di `S3Syncer`.

**Tech Stack:** Swift 5.x, SwiftUI, XCTest. Nessuna dipendenza nuova, nessuno schema SQLite toccato, nessuna scrittura su volumi o bucket.

**Baseline:** `Docs/CLAUDE.md` dice 568 test, ma altre fonti del progetto riportano 564. **Misura il conteggio reale su `main` prima di iniziare** e usalo come `B`. Ogni task dichiara l'incremento. Il target di test **non è file-system-synchronized**: ogni file nuovo va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`). Verifica sempre il **totale nel log**, mai il solo `** TEST SUCCEEDED **`.

**Prerequisito d'ambiente:** oggi `git` e `xcodebuild` non partono perché la licenza di Xcode non è accettata (`sudo xcodebuild -license`). Deve farlo Enrico prima del Task 1.

| Componente | Responsabilità | Test |
| :---- | :---- | :---- |
| `SpaceLevel`, `VolumeSpaceDisplay`, `VolumeSpaceState` | percentuale, soglie, testo, uguaglianza su «ciò che si vede» | `VolumeSpaceDisplayTests.swift` |
| `VolumeCapacityReader` | lettura fuori dal main thread, URL nuovo a ogni lettura, guardia sul punto di montaggio | `VolumeCapacityReaderTests.swift` |
| `VolumeSpaceModel` + `VolumeMonitor.check()` | pubblicare solo se cambia, oggetto separato, niente accumulo di sondaggi | non coperto, dichiarato |
| `S3Syncer.collectPages`, `S3Listing`, `CloudUsageTotals`, sink | completezza dell'elenco, somma, correzione a fine sync | `S3ListingTests.swift` |
| `CloudUsageSnapshot`, `CloudUsageStore`, `CloudUsageText`, `CloudUsageRefreshGate` | persistenza, testo, motivo di disattivazione | `CloudUsageStoreTests.swift`, `CloudUsageTextTests.swift` |
| `VolumeSpaceLine`, `SpaceBar`, riga di Cubbit, bottone ↻ | UI | non coperto, dichiarato |

## Comandi di build e test

```bash
# build
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
# suite completa
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
# singola classe
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/<Classe> 2>&1 | tail -30
```

## Regole valide per tutti i task

1. **Trova il codice con `grep -n`, mai con il numero di riga.** `ContentView.swift` supera le 11.300 righe.
2. **Ogni task dichiara «il mutante che deve morire»**: la modifica plausibile che un ottimizzatore futuro farebbe, e il test che deve diventare rosso. Un mutante che sopravvive va dichiarato **equivalente e spiegato**, mai nascosto.
3. **Nessun percorso di questo piano scrive, copia, sposta o cancella un file, e nessuno fa PUT/DELETE su S3.** Se un diff contiene `copyItem`, `removeItem`, `trashItem`, `createDirectory` (fuori dai test) o una richiesta S3 diversa da `GET` di elenco, è un errore.
4. **Niente I/O sul main thread.** Né `resourceValues`, né `fileExists`, né rete. `UserDefaults` è ammesso, perché è in memoria.
5. **Mai `volumeAvailableCapacityForImportantUsageKey`.** Sull'SSD ExFAT/FSKit restituisce 0 (misurato il 2026-09-19, vedi la spec).
6. **Mai un `URL` riusato per leggere la capacità.** Va costruito dentro la funzione a ogni chiamata (vedi la spec: la cache di `resourceValues` fuori dal main thread può non scadere mai).
7. **Stringhe mostrate all'utente:** nessuna parola fra «byte» (eccetto «0 byte»), «capacità», «volume», «montato», «bucket», «oggetti», «S3», «elenco». I test di parole vietate la fanno rispettare.

---

### Task 0: ADR-0006, dopo l'approvazione e prima del codice

`Docs/CLAUDE.md` chiede un ADR per ogni decisione architetturale approvata, scritto **prima** che l'Implementer parta.

- [ ] **Step 1:** Scrivi `Docs/adr/0006-spazio-dei-volumi-letto-fuori-dal-main-e-pubblicato-a-parte.md` (Contesto / Opzioni valutate / Decisione e motivo, sul modello di 0001-0005). Contenuto minimo: la chiave `volumeAvailableCapacityKey` contro `…ForImportantUsage`, con la misura dello 0 su ExFAT; l'oggetto osservabile separato come difesa dai ridisegni; il numero di Cubbit ricavato dagli elenchi **completi** (opzioni A/B/C della spec) e cosa si accetta di perdere, cioè un numero con data e non sempre fresco.
- [ ] **Step 2:** Commit solo documentazione.

---

### Task 1: `VolumeSpaceState`, logica pura

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo blocco `// MARK: - Spazio dei volumi`, subito prima di `// MARK: - VolumeMonitor`, che trovi con `grep -n "MARK: - VolumeMonitor"`)
- Create: `AppBackupFotoTests/VolumeSpaceDisplayTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces prodotte** (consumate dai Task 3 e 4):
- `enum SpaceLevel: Equatable { case normal, warning, critical }` con `static func forPercentUsed(_ p: Int) -> SpaceLevel` (`> 95` critical, `> 85` warning)
- `struct VolumeSpaceDisplay: Equatable { let percentUsed: Int; let level: SpaceLevel; let freeLine: String; let accessibilityLabel: String }`
- `enum VolumeSpaceState: Equatable { case disconnected, unreadable, measured(VolumeSpaceDisplay) }` con `static func from(mounted: Bool, reading: VolumeCapacityReading?, volumeName: String) -> VolumeSpaceState`
- `enum VolumeCapacityReading: Equatable { case notAMountPoint, unreadable, measured(total: Int64, available: Int64) }`. Il tipo si dichiara qui perché `from` lo consuma; il lettore arriva nel Task 2.
- `enum SpaceFormat { static func bytes(_ n: Int64) -> String }`: `ByteCountFormatter` con `countStyle = .file`, `isAdaptive = false`, `allowsNonnumericFormatting = false`. È la **fonte unica** della formattazione per i dischi e per Cubbit.
- `VolumeSpaceState.statusText`: «Non collegato» / «Spazio libero non disponibile» / `freeLine`

- [ ] **Step 1: Scrivi i test** (14):
  - soglie: 85 → `.normal`, 86 → `.warning`, 95 → `.warning`, 96 → `.critical`, 100 → `.critical`, 0 → `.normal`
  - percentuale per difetto: totale 1.000, disponibile 1 → 99 (mai 100 con spazio libero); disponibile 0 → 100
  - disponibile > totale → percentuale 0, nessun crash; disponibile negativo → trattato come 0
  - `.measured(total: 0, …)` → `.unreadable`
  - `mounted: false` con una lettura `.measured` valida → `.disconnected`
  - `.notAMountPoint` e `.unreadable` → entrambi `.unreadable`
  - **il test contro i ridisegni:** totale 1.000.170.717.184, disponibile 448.056.262.656 contro 448.026.262.656 (30 MB in meno) → stati `==`
  - totale uguale, disponibile con 2 GB di differenza → stati `!=`
  - cambio di livello (85 → 86) → stati `!=`
  - `freeLine == "\(SpaceFormat.bytes(avail)) liberi su \(SpaceFormat.bytes(total))"`. Confronta con `SpaceFormat` per non dipendere dal separatore decimale del locale; in più un'asserzione senza decimali, `contains("448 GB")`
  - nessuna parola vietata (regola 7) in `statusText` e `accessibilityLabel` di tutti e tre i casi
- [ ] **Step 2:** Registra il file in `project.pbxproj` (4 punti; copia il formato con `grep -n "IntegritySummaryTests" AppBackupFoto.xcodeproj/project.pbxproj`).
- [ ] **Step 3:** Verifica che fallisca per il motivo atteso (`cannot find 'VolumeSpaceState' in scope`). Se la classe non viene trovata affatto, la registrazione non ha funzionato: **fermati e segnalalo**.
- [ ] **Step 4:** Implementa. Doc-comment su `VolumeSpaceState` che dica **perché contiene testo già formattato e non byte**: l'uguaglianza su ciò che si vede è il meccanismo che evita di ripubblicare durante una copia.
- [ ] **Step 5:** Test verdi, build, suite completa, commit. **Attesi B + 14.**

**Il mutante che deve morire:**

| Mutante | Test che diventa rosso |
| :---- | :---- |
| `>= 85` al posto di `> 85` | 85 → `.normal` |
| percentuale arrotondata al più vicino invece che per difetto | disponibile 1 su 1.000 → 99 |
| `VolumeSpaceDisplay` che conserva i byte grezzi per l'uguaglianza | il test dei 30 MB (stati `==`) |
| `from` che ignora `mounted` quando la lettura è valida | `mounted: false` → `.disconnected` |
| `SpaceFormat` con `isAdaptive = true` | `contains("448 GB")` (verrebbe «448,06 GB») |

---

### Task 2: `VolumeCapacityReader`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (stesso blocco del Task 1)
- Create: `AppBackupFotoTests/VolumeCapacityReaderTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interface:** `enum VolumeCapacityReader { nonisolated static func read(path: String) -> VolumeCapacityReading }`

- [ ] **Step 1: Scrivi i test** (4), su file veri:
  - `read(path: "/")` → `.measured` con `total > 0` e `0 <= available <= total`
  - **una directory creata in `FileManager.default.temporaryDirectory` → `.notAMountPoint`**, non la capacità del disco che la contiene. È il caso «cartella normale al posto dell'SSD»
  - un percorso inesistente → `.unreadable`
  - `"/"` e un percorso con lo slash finale danno lo stesso esito. Il confronto con `volumeURL` avviene per componenti canoniche (`canonicalPathComponents`/`realResolvedPath`, **la fonte unica esistente**: non scriverne una nuova). Questo copre anche la trappola `/var` ↔ `/private/var` della directory temporanea (fatto misurato n. 4)
- [ ] **Step 2:** Registra in `project.pbxproj`. **Step 3:** Verifica il fallimento atteso.
- [ ] **Step 4:** Implementa. `URL(fileURLWithPath: path)` **dentro** la funzione; chiavi `[.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeURLKey]`; `try?` → `.unreadable`; `volumeURL` diverso dal percorso → `.notAMountPoint`; `total <= 0` → `.unreadable`. Doc-comment con i due motivi: la cache fuori dal main thread (link al thread DTS citato nella spec) e la cartella al posto del volume. Scrivi anche perché **non** si usa `…ForImportantUsage`: vale 0 su ExFAT/FSKit.
- [ ] **Step 5:** Verdi, suite, commit. **Attesi B + 18.**

**Il mutante che deve morire:**

| Mutante | Test rosso |
| :---- | :---- |
| guardia sul punto di montaggio rimossa | directory temporanea → `.notAMountPoint` |
| confronto con `hasPrefix` o per stringa | slash finale / `/private` |
| URL tenuto in una proprietà `static` e riusato | **equivalente per i test**: la cache non si può provocare in modo deterministico. Va dichiarato nel commit e coperto dalla regola 6 e dalla verifica manuale (la barra deve muoversi durante una copia) |
| chiave `…ForImportantUsage` | **equivalente su `/`** (APFS). Lo copre solo la verifica manuale sull'SSD: dichiaralo |

---

### Task 3: `VolumeSpaceModel` e cablaggio in `VolumeMonitor`

**Files:** Modify `AppBackupFoto/ContentView.swift` (`grep -n "final class VolumeMonitor"`).

- [ ] **Step 1:** Aggiungi `final class VolumeSpaceModel: ObservableObject { @Published var ssd: VolumeSpaceState = .disconnected; @Published var hdd: VolumeSpaceState = .disconnected }`. Il doc-comment deve spiegare **perché è separato**: chi osserva `VolumeMonitor` (cinque view) non deve ridisegnarsi quando cambia lo spazio. Cita il difetto n. 3 del 2026-09-03 già scritto sopra `VolumeMonitor`.
- [ ] **Step 2:** In `VolumeMonitor`: `let space = VolumeSpaceModel()`. In `check()`, sulla `probeQueue`: dopo i due `fileExists`, `VolumeCapacityReader.read` **solo** per i volumi presenti; poi `VolumeSpaceState.from(...)` per entrambi; un solo `DispatchQueue.main.async` che pubblica i due booleani (invariati) e i due stati, **ognuno solo se `!=`**.
- [ ] **Step 3:** `private var probeInFlight = false`, **letto e scritto solo sul main**: `check()` esce subito se è `true`, lo mette a `true` prima di `probeQueue.async`, e il blocco sul main lo rimette a `false`. Il timer scatta già sul main, quindi non serve un lock. Aggiorna il doc-comment di `VolumeMonitor` con una riga che spieghi perché esiste.
- [ ] **Step 4:** Build, suite completa (**B + 18, invariato**), commit.

**Controllo per il Reviewer** (non automatizzabile): nessuna delle cinque view che osservano `VolumeMonitor` legge `space`. `grep -n "\.space\." AppBackupFoto/ContentView.swift` deve trovare solo `VolumeSpaceLine` (Task 4).

---

### Task 4: la UI di SSD e HDD

**Files:** Modify `AppBackupFoto/ContentView.swift` (`grep -n "struct VolumeRow"`, `grep -n "enum AppColor"`).

- [ ] **Step 1:** Nuovo token `AppColor.spaceNormal = Color.accentColor` (o il colore deciso da Enrico alla domanda 4), con un commento di una riga.
- [ ] **Step 2:** `SpaceBar(fraction: Double, color: Color)`: due `Capsule` sovrapposte, alte 4 pt, con la traccia `Color.secondary.opacity(0.2)`. Non una `ProgressView`, perché su macOS il `.tint` non è garantito.
- [ ] **Step 3:** `VolumeSpaceLine(kind: VolumeKind)`, con `@ObservedObject private var space = VolumeMonitor.shared.space`: per `.measured` la barra e poi un `HStack` con `freeLine` a sinistra e «\(percentUsed)%» a destra (`monospacedDigit`); per gli altri due stati solo `statusText`. Font `AppFont.caption`, rientro iniziale 44 pt (16 + 20 + 8, allineato al nome). `.accessibilityElement(children: .combine)` con `accessibilityLabel`.
- [ ] **Step 4:** In `SidebarView`, sotto le `VolumeRow` di SSD e HDD, metti `VolumeSpaceLine(kind: .ssd/.hdd)`. **Nessun parametro nuovo** su `SidebarView` o `VolumeRow`.
- [ ] **Step 5:** Build, suite (**B + 18**), commit. Se il build aggiorna `Localizable.xcstrings`, il diff entra in questo commit.

---

### Task 5: completezza dell'elenco S3, somma e sink

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dentro `S3Syncer`: `grep -n "func listAll(config"`, `grep -n "^final class S3Syncer"`, `grep -n "func sync(from localURL: URL, config: S3Config"`)
- Create: `AppBackupFotoTests/S3ListingTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces prodotte:**
- `struct S3Listing { let objects: [String: Int64]; let isComplete: Bool }`
- `static func collectPages(fetch: (String?) async throws -> ([String: Int64], String?), shouldStop: () -> Bool) async throws -> S3Listing`
- `struct CloudUsageTotals: Equatable { let bytes: Int64; let count: Int }` con `static func of(_ objects: [String: Int64]) -> CloudUsageTotals` e `static func afterSync(listed: CloudUsageTotals?, uploadedBytes: Int64, uploadedCount: Int, wasCancelled: Bool) -> CloudUsageTotals?`
- `typealias CloudUsageSink = (CloudUsageTotals, _ bucket: String) -> Void`, e `S3Syncer.init(usageSink: @escaping CloudUsageSink = S3Syncer.defaultUsageSink)`. Il default fa `Task { @MainActor in CloudUsageStore.shared.record(...) }`: finché non esiste il Task 6, lascialo un no-op con un `// TODO Task 6`, che il Task 6 **deve** rimuovere
- `S3Syncer.SyncResult.cloudUsageAfter: CloudUsageTotals?`

- [ ] **Step 1: Scrivi i test** (9), con un fetcher finto (closure con un contatore e pagine precotte):
  - 3 pagine, l'ultima con token `nil` → `isComplete == true`, chiavi unite
  - **`shouldStop` vero da subito → `isComplete == false`, `objects` vuoto, fetch mai chiamato**
  - stop dopo la pagina 1 di 3 → `isComplete == false`
  - un fetch che lancia alla pagina 2 → `collectPages` lancia
  - `CloudUsageTotals.of`: somma e conteggio; dizionario vuoto → (0, 0)
  - `afterSync` con listed (100, 10), 50 byte, 2 file, non interrotto → (150, 12)
  - `afterSync` con `wasCancelled: true` → nil
  - `afterSync` con `listed: nil` (elenco incompleto) → nil
  - `afterSync` con 0 caricati → uguale a listed. Un sync senza novità **conferma** il valore con una data nuova, e questo è voluto
- [ ] **Step 2:** Registra. **Step 3:** Fallimento atteso.
- [ ] **Step 4:** Implementa.
  - `listAll` diventa `let listing = try await Self.collectPages(fetch: { try await self.listPage(config: config, token: $0) }, shouldStop: { self.cancelled || Task.isCancelled })`; `if listing.isComplete { usageSink(.of(listing.objects), config.bucket) }`; `return listing.objects`. **La firma di `listAll` non cambia.**
  - `sync()` deve sapere se il **proprio** elenco era completo. Aggiungi `func listAllDetailed(config:) async throws -> S3Listing` (non `private`: lo usa anche `CloudUsageStore.refresh` nel Task 6), che **non** chiama il sink. Lo usano `listAll` (che poi chiama il sink se l'elenco è completo) e `sync`. **Non** chiamare due volte la rete. `sync` salva `listed = listing.isComplete ? .of(listing.objects) : nil`; alla fine `result.cloudUsageAfter = CloudUsageTotals.afterSync(listed:, uploadedBytes: result.uploadedBytes, uploadedCount: result.uploaded, wasCancelled: cancelled || Task.isCancelled)`, e se non è nil lo passa a `usageSink`.
  - Doc-comment su `S3Listing.isComplete`: completo significa «uscito perché il token è `nil`», e la ragione è che un'anteprima dopo uno stop elenca zero pagine (spec, «Scoperte collaterali» 1).
- [ ] **Step 5:** Verdi. Anche `S3SyncerRetryTests`, `S3SyncerShouldUploadTests` e `S3SyncerChangedKeyTests` devono restare verdi **senza modifiche**: se ne serve una, la firma dell'`init` non è davvero additiva. Suite, commit. **Attesi B + 27.**

**Il mutante che deve morire:**

| Mutante | Test rosso |
| :---- | :---- |
| `isComplete = !objects.isEmpty` | stop dopo la pagina 1 (non vuoto ma incompleto) |
| `isComplete = true` sempre / sink chiamato senza guardia | stop da subito → incompleto |
| `afterSync` che ignora `wasCancelled` | `wasCancelled: true` → nil |
| `afterSync` che usa un vecchio snapshot quando `listed == nil` | `listed: nil` → nil |

---

### Task 6: `CloudUsageSnapshot`, `CloudUsageStore`, `CloudUsageText`, `CloudUsageRefreshGate`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo blocco `// MARK: - Spazio usato su Cubbit`, subito dopo `S3Syncer`)
- Create: `AppBackupFotoTests/CloudUsageStoreTests.swift`, `AppBackupFotoTests/CloudUsageTextTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (due file, 8 punti)

**Interfaces prodotte:**
- `struct CloudUsageSnapshot: Codable, Equatable { let usedBytes: Int64; let objectCount: Int; let measuredAt: Date; let bucket: String }` con **`init(from:)` esplicita e `decodeIfPresent`**
- `@MainActor final class CloudUsageStore: ObservableObject` con `static let shared`, `init(defaults: UserDefaults = .standard)`, `@Published private(set) var snapshot: CloudUsageSnapshot?`, `@Published private(set) var isRefreshing = false`, `@Published private(set) var lastRefreshFailed = false`, `func record(_ totals: CloudUsageTotals, bucket: String, at: Date = Date())`, `func refresh(config: S3Syncer.S3Config) async`
- `enum CloudUsageText { static func usedLine(_ s: CloudUsageSnapshot?) -> String; static func updatedLine(_ s: CloudUsageSnapshot?, now: Date, calendar: Calendar, locale: Locale) -> String }`
- `enum CloudUsageRefreshGate { static func disabledReason(jobIsRunning: Bool, isRefreshing: Bool) -> String? }`

- [ ] **Step 1: Scrivi `CloudUsageStoreTests`** (6), con `UserDefaults(suiteName:)` dedicati e ripuliti in `tearDown`, come `JobHistoryStoreTests`: `record` e poi un nuovo store sugli stessi defaults → stesso snapshot; defaults vuoti → nil; dati non JSON sotto la chiave → nil e nessun crash; JSON senza `objectCount` → decodificato, con `objectCount` a 0; `record` aggiorna `snapshot`; `record` con un bucket diverso lo sovrascrive.
- [ ] **Step 2: Scrivi `CloudUsageTextTests`** (10), con `Calendar(identifier: .gregorian)`, fuso `Europe/Rome` e locale `it_IT` fissati: `usedLine` contiene «usati» e `SpaceFormat.bytes`; `nil` → «Spazio usato non ancora calcolato»; oggi → «aggiornato oggi alle HH:mm»; ieri → «aggiornato ieri alle …»; stesso anno → «aggiornato il 3 settembre»; anno diverso → contiene l'anno; nessuna parola vietata in tutte le frasi; gate: job in corso → motivo non nil; conteggio in corso → motivo non nil; nessuno dei due → nil.
- [ ] **Step 3:** Registra i due file. **Step 4:** Fallimento atteso.
- [ ] **Step 5:** Implementa. `refresh(config:)`: `guard !isRefreshing`; `isRefreshing = true`; **un'istanza nuova** `S3Syncer()`, poi `listAllDetailed` (che non chiama il sink: a registrare è `refresh` stesso, una volta sola); se completo `record`; se lancia `lastRefreshFailed = true` e lo snapshot resta quello di prima; `isRefreshing = false` in un `defer`. Il doc-comment dice perché l'istanza è dedicata: `runner.s3Syncer` condivide `cancelled` con i job. Sostituisci il `TODO Task 6` del sink di default.
- [ ] **Step 6:** Verdi, suite, commit. **Attesi B + 43.**

**Il mutante che deve morire:**

| Mutante | Test rosso |
| :---- | :---- |
| `init(from:)` sintetizzata invece che esplicita | JSON senza `objectCount` → decodificato |
| `refresh` che usa `runner.s3Syncer` | **non testabile senza rete**: dichiararlo, lo copre la verifica manuale «↻ dopo uno stop» |
| data formattata senza calendario e locale iniettati | i test su oggi/ieri falliscono a cavallo della mezzanotte o su un Mac in inglese |

---

### Task 7: cablaggio di Cubbit e UI

**Files:** Modify `AppBackupFoto/ContentView.swift` (`grep -n "VolumeRow(name: \"Cubbit S3\""`).

- [ ] **Step 1:** Sotto la `VolumeRow` di Cubbit metti `CloudUsageLine`, che osserva `CloudUsageStore.shared`: `usedLine` in `caption`; sotto, `updatedLine` in `caption` `.secondary`. Durante `isRefreshing`, «Sto calcolando lo spazio usato…» con `ProgressView().controlSize(.mini)`. Con `lastRefreshFailed`, la riga «Cubbit non raggiungibile, riprova più tardi» in `.secondary`. Nessun alert.
- [ ] **Step 2:** Verifica che il sink di default arrivi davvero allo store da tutti e sei i chiamanti di `listAll`. Tutti costruiscono `S3Syncer()` con l'`init` di default: `grep -n "S3Syncer()"` deve mostrare solo quelli, e **nessuno** deve passare un sink no-op.
- [ ] **Step 3 (solo se Enrico ha risposto sì alla domanda 1):** il bottone ↻ (`arrow.clockwise`, `.borderless`, `AppIconSize` piccolo) sulla riga della data. `.disabled(reason != nil)` con `.help(reason ?? "Ricalcola lo spazio usato su Cubbit. Può richiedere un paio di minuti.")`, dove `reason = CloudUsageRefreshGate.disabledReason(jobIsRunning: runner.isRunning, isRefreshing: store.isRefreshing)`. Azione: `Task { await runner.loadS3ConfigIfNeeded(); if let c = runner.s3Config { await CloudUsageStore.shared.refresh(config: c) } else { /* lastRefreshFailed */ } }`. `CloudUsageLine` riceve `runner` come parametro: **non** aggiungere `@ObservedObject runner` altrove.
- [ ] **Step 4:** Build, suite (**B + 43**), commit, con il diff di `Localizable.xcstrings` se il build l'ha prodotto.

---

### Task 8: documentazione e verifica manuale

- [ ] **Step 1:** Aggiorna `.claude/rules/architecture.md`:
  - sezione `VolumeMonitor`: spazio, `VolumeSpaceModel` separato e perché, `probeInFlight`
  - sezione `S3Syncer`: `collectPages`/`isComplete`, sink, `afterSync`
  - fra i **fatti misurati**: «`volumeAvailableCapacityForImportantUsageKey` = 0 su ExFAT/FSKit (SSD reale, 2026-09-19); `volumeAvailableCapacityKey` corretto», con la tabella della spec
- [ ] **Step 2:** `Docs/CLAUDE.md`: una riga nella tabella di stato e il nuovo conteggio dei test. `Docs/ROADMAP.md`: un punto nuovo in coda.
- [ ] **Step 3:** Se Enrico lo vuole, apri i ticket per le tre «Scoperte collaterali» della spec in `Docs/superpowers/tickets/`.
- [ ] **Step 4: Verifica manuale con Enrico e i volumi veri.** Nessun punto va spuntato senza averlo visto:
  1. SSD e HDD collegati: i numeri della sidebar coincidono con `df -H` e con il Finder (Ottieni informazioni), a meno dello spazio purgeable sull'HDD.
  2. **L'SSD non è rosso e non dice «0 byte liberi»** (è il caso `…ForImportantUsage`).
  3. Durante un Mac→SSD o SSD→HDD reale, la barra della destinazione si muove, a scatti di circa 1 GB (è il caso dell'URL in cache). Nello stesso momento il pannello Doppioni aperto **non** sfarfalla e non rallenta: l'oggetto separato funziona.
  4. Espelli l'SSD dal Finder: in massimo 3 secondi la riga diventa «Non collegato» senza barra, e il pallino si spegne insieme.
  5. HDD collegato e inattivo per 15 minuti: il disco va a dormire (lo si sente, oppure `pmset -g log | grep -i sleep`). Rischio 2 della spec.
  6. Primo avvio dopo l'aggiornamento: Cubbit dice «Spazio usato non ancora calcolato». Dopo un'anteprima SSD→Cubbit compare «X usati · aggiornato oggi alle …». Chiudi e riapri l'app: il valore c'è ancora.
  7. Interrompi un SSD→Cubbit, poi fai un'anteprima: la riga di Cubbit **non** diventa «0 byte usati».
  8. ↻ (se c'è): **cronometra il conteggio** e scrivi il tempo nella spec e nell'`help` del bottone al posto della stima «un paio di minuti». Annota anche il numero di oggetti (`objectCount`) per chiudere la discrepanza 70.000 / 120.842.
  9. Dopo un SSD→Cubbit completo, il numero è cresciuto esattamente dei byte caricati. Confrontalo con un ↻ subito dopo: devono coincidere.
- [ ] **Step 5:** Commit della documentazione.

---

## Riepilogo dei conteggi

| Task | nuovi test | cumulativo |
| :--- | ---: | ---: |
| 1 | 14 | B + 14 |
| 2 | 4 | B + 18 |
| 3, 4 | 0 | B + 18 |
| 5 | 9 | B + 27 |
| 6 | 16 | B + 43 |
| 7, 8 | 0 | B + 43 |

Cinque file di test nuovi, da registrare tutti e cinque in `project.pbxproj`.
