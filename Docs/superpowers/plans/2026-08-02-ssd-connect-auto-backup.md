# Backup automatico Mac→SSD al collegamento dell'SSD — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Nota per questo progetto: `subagent-driven-development` e `executing-plans` non sono disponibili in questo ambiente. Esegui i task in sequenza in questa stessa sessione, con build+test verificati e un commit dopo ogni task, come fatto per tutti gli interventi precedenti in questa sessione.

**Goal:** Far partire da sola una sincronizzazione Mac→SSD quando l'utente collega l'SSD, se l'app è aperta.

**Architecture:** Un `@AppStorage` toggle condiviso tra `ContentView` (legge, per decidere se scattare) e `SettingsSheet` (mostra/modifica), più un `.onChange(of: volumes.ssdMounted)` in `ContentView` che richiama `runner.runMacToSSD()` già esistente — nessuna nuova astrazione, nessuna modifica a `VolumeMonitor`/`BackupRunner`.

**Tech Stack:** Swift 5.x, SwiftUI (`@AppStorage`, `.onChange`), macOS 13+. Tutto il codice in `AppBackupFoto/ContentView.swift` (convenzione consolidata del progetto).

## Global Constraints

- Nessun LaunchAgent/`SMAppService`, nessun avvio ad app chiusa — fuori scope esplicitamente per questa iterazione.
- Nessuno scheduling a orario fisso — solo trigger sul collegamento SSD.
- Solo il job Mac→SSD si automatizza, non SSD→HDD né SSD→S3.
- Riuso di `runMacToSSD()` e `run(label:work:)` esistenti così come sono — nessuna nuova validazione/gestione errori.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.

---

### Task 1: Toggle + trigger automatico

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:2298-2304` (dichiarazioni `@State`/`@StateObject` di `ContentView`)
- Modify: `AppBackupFoto/ContentView.swift:2359-2362` (catena di modifier di `ContentView.body`)
- Modify: `AppBackupFoto/ContentView.swift:2383-2398` (`SettingsSheet`)

**Interfaces:**
- Consumes: `VolumeMonitor.ssdMounted` (esistente, `@Published var ssdMounted: Bool`), `BackupRunner.runMacToSSD()` (esistente), `BackupRunner.isRunning` (esistente).
- Produces: nessuna nuova interfaccia pubblica — solo UI e un modifier in più.

Nessun test automatico (logica UI a tre condizioni booleane, non estraibile in modo significativo). Verifica: build + suite esistente invariata (45 test).

- [ ] **Step 1: Aggiungi il toggle persistito a `ContentView`**

In `AppBackupFoto/ContentView.swift`, `struct ContentView: View` (riga 2298) inizia oggi con:

```swift
struct ContentView: View {
    @StateObject private var runner = BackupRunner()
    @StateObject private var volumes = VolumeMonitor()
    @State private var showCompletion = false
    @State private var showSettings = false
    @State private var showHamburger = false
    @State private var activeSpeedTab: SpeedLogTab = .speed
```

Aggiungi la riga del toggle subito dopo `activeSpeedTab`:

```swift
struct ContentView: View {
    @StateObject private var runner = BackupRunner()
    @StateObject private var volumes = VolumeMonitor()
    @State private var showCompletion = false
    @State private var showSettings = false
    @State private var showHamburger = false
    @State private var activeSpeedTab: SpeedLogTab = .speed
    @AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true
```

- [ ] **Step 2: Aggiungi il trigger `.onChange` in `ContentView.body`**

Nella stessa struct, la catena di modifier (riga 2359) contiene oggi:

```swift
        .onAppear { Notifier.requestAuthorization() }
        .onChange(of: runner.completionSnapshot?.phase) { _, p in
            if let p, p.isTerminal { showCompletion = true }
        }
```

Aggiungi il nuovo `.onChange` subito dopo quello esistente:

```swift
        .onAppear { Notifier.requestAuthorization() }
        .onChange(of: runner.completionSnapshot?.phase) { _, p in
            if let p, p.isTerminal { showCompletion = true }
        }
        .onChange(of: volumes.ssdMounted) { _, mounted in
            if mounted && autoBackupEnabled && !runner.isRunning {
                runner.runMacToSSD()
            }
        }
```

- [ ] **Step 3: Aggiungi il toggle a `SettingsSheet`**

Nello stesso file, `struct SettingsSheet: View` (riga 2383) è oggi:

```swift
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bm = BookmarkManager.shared
    var body: some View {
        VStack(spacing: 20) {
            Text("Impostazioni").font(.title2).fontWeight(.semibold)
            Text("Modifica le cartelle selezionate").font(.subheadline).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(BookmarkManager.Location.allCases) { loc in
                    LocationRow(location: loc) { bm.selectAndSave(loc) { _ in } }
                }
            }.padding(.horizontal, 20)
            Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(36).frame(minWidth: 480)
    }
}
```

Sostituiscila con:

```swift
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bm = BookmarkManager.shared
    @AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true
    var body: some View {
        VStack(spacing: 20) {
            Text("Impostazioni").font(.title2).fontWeight(.semibold)
            Text("Modifica le cartelle selezionate").font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Backup automatico Mac → SSD quando colleghi l'SSD", isOn: $autoBackupEnabled)
                Text("Appena colleghi l'SSD, se l'app è aperta, parte da sola l'aggiornamento da Foto a SSD.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20)
            VStack(spacing: 10) {
                ForEach(BookmarkManager.Location.allCases) { loc in
                    LocationRow(location: loc) { bm.selectAndSave(loc) { _ in } }
                }
            }.padding(.horizontal, 20)
            Button("Chiudi") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(36).frame(minWidth: 480)
    }
}
```

- [ ] **Step 4: Build**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Suite di test esistente (nessun nuovo test, verifica nessuna regressione)**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15`

Expected: tutti i 45 test esistenti passano.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Auto-trigger Mac->SSD backup when SSD connects (app open, toggle in Settings)"
```

**Nota per l'utente**: verifica manuale in app — scollegare/ricollegare l'SSD col toggle acceso in Impostazioni, controllare che il backup Mac→SSD parta da solo una volta per collegamento; disattivare il toggle e controllare che non parta più.

---

### Task 2: Aggiorna la documentazione

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

- [ ] **Step 1: Aggiorna la sezione `BackupRunner` in `Docs/CLAUDE.md`**

Trova la riga:

```
- Alla fine di ogni job (successo, errore o stop manuale) salva un `JobSummary` in `JobHistoryStore`
```

Aggiungi subito dopo (nuovo bullet, stesso livello):

```
- **Backup automatico Mac→SSD al collegamento SSD**: `ContentView` osserva `volumes.ssdMounted` (`.onChange`) e chiama `runMacToSSD()` da sola quando passa da scollegato a collegato, se l'app è aperta e il toggle "Backup automatico" in Impostazioni è attivo (`@AppStorage("autoBackupOnSSDConnect")`, default acceso). Solo Mac→SSD si automatizza — SSD→HDD e SSD→S3 restano manuali. Nessun LaunchAgent: non funziona ad app chiusa (richiederebbe prima una modalità menu bar/background, non ancora fatta).
```

- [ ] **Step 2: Aggiorna la tabella "Stato attuale"**

Trova:

```
| Test automatici | ✅ 45 test XCTest passano (`AppBackupFotoTests`: zero-overwrite, volume-root, persistenza job, campionamento locale, parsing cartelle S3 per il restore, correttezza sha256, classificazione retry S3, lettura file a blocchi, concorrenza limitata, validazione endpoint S3) |
```

Aggiungi una nuova riga subito sopra (nella stessa tabella, prima della riga "Test automatici"):

```
| Backup automatico Mac→SSD | ✅ Implementato — trigger su collegamento SSD, toggle on/off in Impostazioni, solo ad app aperta |
```

- [ ] **Step 3: Aggiorna `Docs/ROADMAP.md`**

Trova:

```
7. **Zero automazione** — ogni backup parte solo a bottone premuto. CCC, ChronoSync e Arq offrono tutti scheduling nativo ("ogni notte se l'SSD è collegato").
   *Fonte: confronto funzionalità CCC / ChronoSync / Arq*
```

Sostituisci con:

```
7. ✅ **Fatto (2026-08-02) — Zero automazione.** Backup Mac→SSD automatico al collegamento dell'SSD, solo ad app aperta (toggle on/off in Impostazioni). Scope ridotto rispetto all'idea originale dopo discussione con l'utente: niente LaunchAgent/avvio ad app chiusa (dipende dalla modalità menu bar, punto #11, non fatta), niente orario fisso, solo Mac→SSD (non SSD→HDD/S3). Vedi `Docs/superpowers/specs/2026-08-02-ssd-connect-auto-backup-design.md`.
   *Fonte: confronto funzionalità CCC / ChronoSync / Arq*
```

Trova la sezione "Da dove partire":

```
## Da dove partire (aggiornato 2026-08-02)

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #4 cleanup multipart, #6 upload paralleli, #9 anteprima S3, #10 Keychain. #5 (cifratura lato client) valutato e deciso esplicitamente contro, per ora — non riproporre senza un motivo nuovo, vedi sopra. Resta un solo intervento critico/alto con bozza di ricerca pronta in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`: **#7 scheduling** (automazione backup, ricerca non ancora approfondita). Il resto della lista (punti 8, 11-20) è ordinabile in base al tempo che si vuole investirci.
```

Sostituisci con:

```
## Da dove partire (aggiornato 2026-08-02)

Fatti: #1 restore, #2 race stop/successo, #3 retry S3, #4 cleanup multipart, #6 upload paralleli, #7 scheduling (Mac→SSD su collegamento SSD), #9 anteprima S3, #10 Keychain. #5 (cifratura lato client) valutato e deciso esplicitamente contro, per ora — non riproporre senza un motivo nuovo, vedi sopra. Nessun punto critico/alto resta aperto nella lista originale: quello che rimane sono i punti "valore aggiunto" (8, 11-20), ordinabili in base al tempo che si vuole investirci — punto #11 (modalità menu bar/background) è il prerequisito naturale se in futuro si vorrà estendere lo scheduling anche ad app chiusa.
```

- [ ] **Step 4: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: Mac->SSD auto-backup on SSD connect shipped"
```

---

## Riepilogo finale per l'utente

Dopo entrambi i task: build verde, 45 test passano (invariati, nessun nuovo test per questa feature), 2 commit. Verifica manuale suggerita: scollegare/ricollegare l'SSD con l'app aperta e il toggle attivo, controllare che Mac→SSD parta da solo una volta; disattivare il toggle e confermare che non parta più.
