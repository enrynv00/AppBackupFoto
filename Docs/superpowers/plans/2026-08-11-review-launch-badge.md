# Badge di Revisione all'avvio (roadmap #20) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eseguire i controlli economici di `ReviewEngine` (bookmark/permessi/endpoint S3 + freschezza deep mirror) una volta all'avvio dell'app, mostrando un pallino rosso discreto sulla voce "Tools" del menu hamburger se trovano qualcosa.

**Architecture:** `ContentView` guadagna un `.task` che chiama `reviewEngine.runConfigChecks(...)` una volta al primo apparire (stesso pattern async già usato dalla voce "Tools" esistente, ma senza aprire la finestra Tools e senza il controllo upload orfani, escluso per costo). Il risultato va nello stesso `@Published var toolsReviewFindings` già letto da `ToolsSheet`. `HamburgerRow` guadagna un parametro `alert: Bool` puramente presentazionale.

**Tech Stack:** SwiftUI (`.task`, `@Published`), nessuna nuova dipendenza.

## Global Constraints

- Solo i controlli economici e sincroni: `ReviewEngine.runConfigChecks(s3Config:s3ConfigFromKeychain:s3ConfigError:)` (che già internamente include `checkDeepMirrorFreshness`) — MAI `runIntegritySample` né `findOrphanedMultipartUploads` nel trigger automatico.
- Il check gira una volta sola all'avvio (`.task`, non un timer periodico).
- Il badge compare SOLO sulla voce "Tools" nel menu hamburger — mai su Dock o menu bar (già riservati allo stato job, roadmap #11/#15).
- Nessuna azione correttiva automatica — solo segnalazione passiva, come il resto di `ReviewEngine`.
- Nessun nuovo file `.swift` — tutto il codice del target app vive in `AppBackupFoto/ContentView.swift` per convenzione esplicita del progetto.
- Nota tecnica per manutenzione futura di questo piano: il target `AppBackupFotoTests` non ha un gruppo file-system-synchronized — un nuovo file di test aggiunto senza registrarlo a mano in `project.pbxproj` (PBXBuildFile/PBXFileReference/gruppo/Sources build phase) resta silenziosamente escluso dalla suite. Questo piano non prevede nuovi file di test (nessuna logica pura nuova: solo wiring UI/lifecycle, stesso ragionamento già applicato a #11/#15/#16), ma la suite esistente (79 test) va rieseguita dopo ogni task per assicurarsi che non ci siano regressioni.

---

### Task 1: `HamburgerRow` guadagna un pallino di alert opzionale

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `HamburgerRow`, oggi intorno alla riga 3238-3275 — verifica con `grep -n "struct HamburgerRow"` perché i task precedenti possono aver spostato le righe)

**Interfaces:**
- Consumes: nessuna.
- Produces: `HamburgerRow` con nuovo parametro `var alert: Bool = false` — consumato da Task 2 sul call site della voce "Tools".

- [ ] **Step 1: Localizza la struct esatta**

```bash
grep -n "struct HamburgerRow" AppBackupFoto/ContentView.swift
```

Leggi le ~40 righe che seguono per confermare il contenuto attuale coincide con quanto sotto (deve essere identico a questo, salvo il numero di riga):

```swift
struct HamburgerRow: View {
    let icon: String
    let label: String
    let iconColor: Color
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

Se il contenuto reale differisce da questo (per modifiche successive non ancora registrate in questo piano), fermati e segnala la differenza invece di procedere alla cieca.

- [ ] **Step 2: Sostituisci con la versione che aggiunge il pallino**

```swift
struct HamburgerRow: View {
    let icon: String
    let label: String
    let iconColor: Color
    var badge: String? = nil
    var alert: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)

                Spacer()

                if alert {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                }
                if let badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

L'unica differenza è: nuovo campo `var alert: Bool = false` e il nuovo blocco `if alert { Circle()... }` prima del blocco `if let badge`. Default `false` → nessun impatto su nessuna delle `HamburgerRow` esistenti (nessun call site attuale passa `alert:`).

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: 79 test verdi (nessuna modifica di logica, solo UI — nessuna regressione attesa).

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add optional alert dot to HamburgerRow (roadmap #20)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Check automatico all'avvio + badge sulla voce Tools

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `ContentView`, oggi intorno alla riga 2812-2900; struct `HamburgerPanel`, call site "Tools" oggi intorno alla riga 3160)

**Interfaces:**
- Consumes: `HamburgerRow.alert: Bool` (Task 1); `ReviewEngine.runConfigChecks(s3Config: S3Syncer.S3Config?, s3ConfigFromKeychain: Bool, s3ConfigError: Error?) -> [ReviewFinding]` (già esistente, `ContentView.swift:2240`); `BackupRunner.loadS3ConfigIfNeeded() async` e le sue proprietà pubblicate `s3Config`/`s3ConfigFromKeychain`/`s3ConfigError`/`toolsReviewFindings: [ReviewFinding]` (già esistenti, `ContentView.swift:1520-1538`).
- Produces: nessuna nuova interfaccia — foglia della catena, chiude la feature.

- [ ] **Step 1: Localizza `ContentView` e aggiungi `reviewEngine` + il `.task`**

```bash
grep -n "struct ContentView" AppBackupFoto/ContentView.swift
```

Il contenuto attuale (verifica che coincida, salvo numeri di riga):

```swift
struct ContentView: View {
    @EnvironmentObject private var runner: BackupRunner
    @StateObject private var volumes = VolumeMonitor()
    @State private var showCompletion = false
    @State private var showSettings = false
    @State private var showHamburger = false
    @State private var activeSpeedTab: SpeedLogTab = .speed
    @AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true
    var body: some View {
        ZStack(alignment: .leading) {
            HSplitView {
                // ... invariato
            }
            if showHamburger {
                // ... invariato
            }
        }
        .onAppear { Notifier.requestAuthorization() }
        .onChange(of: runner.completionSnapshot?.phase) { _, p in
            if let p, p.isTerminal { showCompletion = true }
        }
        .onChange(of: volumes.ssdMounted) { _, mounted in
            if mounted && autoBackupEnabled && !runner.isRunning {
                runner.runMacToSSD()
            }
        }
        .sheet(isPresented: $showCompletion) {
            if let snap = runner.completionSnapshot {
                CompletionSheet(phase: snap.phase, stats: snap.stats) { showCompletion = false }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }
    // ...
}
```

Se il contenuto reale differisce sostanzialmente da questo, fermati e segnala la differenza invece di procedere alla cieca. Se differisce solo per righe già toccate da altri task (improbabile, dato che questo è l'ultimo punto di roadmap), procedi comunque con l'edit sottostante applicato al contenuto reale.

- [ ] **Step 2: Aggiungi `reviewEngine` e il `.task`**

Modifica l'inizio della struct, aggiungendo `reviewEngine` accanto alle altre property:

```swift
struct ContentView: View {
    @EnvironmentObject private var runner: BackupRunner
    @StateObject private var volumes = VolumeMonitor()
    @State private var showCompletion = false
    @State private var showSettings = false
    @State private var showHamburger = false
    @State private var activeSpeedTab: SpeedLogTab = .speed
    @AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true
    private let reviewEngine = ReviewEngine()
```

(stesso pattern già usato in `HamburgerPanel`, che ha `private let reviewEngine = ReviewEngine()`.)

Poi aggiungi `.task { }` accanto a `.onAppear { Notifier.requestAuthorization() }`:

```swift
        .onAppear { Notifier.requestAuthorization() }
        .task {
            await runner.loadS3ConfigIfNeeded()
            runner.toolsReviewFindings = reviewEngine.runConfigChecks(
                s3Config: runner.s3Config,
                s3ConfigFromKeychain: runner.s3ConfigFromKeychain,
                s3ConfigError: runner.s3ConfigError)
        }
```

Non serve `Task { }` né `MainActor.run` qui (a differenza del call site "Tools" in `HamburgerPanel`, che è dentro un'action closure sincrona di un `Button`): `.task` è già asincrono, e il progetto ha `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` come build setting — `ContentView` e `BackupRunner` sono già MainActor per default, quindi l'assegnazione a `runner.toolsReviewFindings` dopo l'`await` avviene già sul thread giusto.

- [ ] **Step 3: Passa `alert:` al call site "Tools" in `HamburgerPanel`**

```bash
grep -n 'HamburgerRow(icon: "wrench.and.screwdriver.fill"' AppBackupFoto/ContentView.swift
```

Il contenuto attuale (verifica che coincida):

```swift
                        HamburgerRow(icon: "wrench.and.screwdriver.fill", label: "Tools", iconColor: .purple) {
                            guard !toolsLoading else { return }
```

Sostituisci con:

```swift
                        HamburgerRow(icon: "wrench.and.screwdriver.fill", label: "Tools", iconColor: .purple,
                                     alert: !runner.toolsReviewFindings.isEmpty) {
                            guard !toolsLoading else { return }
```

(Solo la riga della dichiarazione di `HamburgerRow` cambia, aggiungendo il parametro `alert:` — il corpo della action closure che segue resta invariato, incluso quello che già ricalcola `runner.toolsReviewFindings` quando l'utente apre Tools manualmente.)

- [ ] **Step 4: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: 79 test verdi.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Run ReviewEngine checks once at launch, badge Tools row (roadmap #20)

ContentView.task calls the same cheap, synchronous checks the
manual Tools flow already used (runConfigChecks, which internally
covers checkDeepMirrorFreshness) — no orphaned-upload scan, no
integrity sample, both excluded per the design go/no-go. Populates
the existing runner.toolsReviewFindings, read by both this launch
check and the manual Tools open. HamburgerRow's new alert dot
reflects it on the Tools row only.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Aggiornare `Docs/CLAUDE.md` e `Docs/ROADMAP.md`

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

**Interfaces:** nessuna — task di documentazione, chiude la roadmap.

- [ ] **Step 1: In `Docs/CLAUDE.md`, sezione `BackupRunner` o `ReviewEngine`, documenta la feature**

Aggiungi (dopo il paragrafo su "Auto-update", stesso stile delle voci esistenti):

```markdown
- **Badge di Revisione all'avvio (2026-08-11, roadmap #20)**: `ContentView.task` esegue una volta, al primo apparire, `ReviewEngine.runConfigChecks(...)` (bookmark/permessi rclone.conf/endpoint S3, include già `checkDeepMirrorFreshness`) e pubblica il risultato in `runner.toolsReviewFindings` — stesso campo già letto da `ToolsSheet` per l'apertura manuale. Esclusi deliberatamente dal check automatico: campione di integrità (`runIntegritySample`, tocca volumi/rete) e scoperta upload multipart orfani (rete S3) — restano solo su richiesta esplicita in Tools. Se `toolsReviewFindings` non è vuoto, `HamburgerRow` mostra un pallino rosso discreto (nuovo parametro `alert: Bool`) sulla sola voce "Tools" — non su Dock/menu bar, riservati allo stato job (#11/#15). Nessun timer periodico, nessuna azione correttiva automatica: solo segnalazione passiva, coerente col resto di `ReviewEngine`.
```

- [ ] **Step 2: In `Docs/CLAUDE.md`, sezione "Obiettivi futuri", aggiungi la verifica manuale**

Se la sezione contiene già un elenco puntato "Verifica manuale ancora da fare" (probabile, vedi le voci lasciate da roadmap #18), aggiungi un punto elenco senza toccare gli altri:

```markdown
- **Roadmap #20, badge di Revisione**: aprire l'app con un problema di configurazione noto (es. `rclone.conf` con permessi troppo aperti, o deep mirror SSD→HDD non eseguito da >45 giorni) e verificare che il pallino compaia sulla voce "Tools" aprendo il menu hamburger; verificare che sparisca al riavvio successivo se il problema è stato risolto nel frattempo.
```

Se invece la sezione non ha ancora quell'elenco, crealo con questo come unico punto, stesso stile delle altre sezioni "Verifica manuale ancora da fare" del documento.

- [ ] **Step 3: In `Docs/ROADMAP.md`, marca il punto 20 come fatto**

Cerca la riga:

```
20. **Il pannello Revisione resta solo su richiesta** — scelta esplicita in fase di design; renderlo periodico con badge discreto lo trasformerebbe da strumento diagnostico a guardiano silenzioso.
```

Sostituisci con:

```
20. ✅ **Fatto (2026-08-11) — Il pannello Revisione era solo su richiesta.** Ora i controlli economici (`runConfigChecks`, che include `checkDeepMirrorFreshness`) girano una volta all'avvio; un pallino discreto sulla voce "Tools" del menu hamburger segnala se trovano qualcosa. Campione di integrità e upload orfani restano manuali (troppo costosi per un check automatico). Vedi `Docs/superpowers/specs/2026-08-11-review-launch-badge-design.md`.
```

- [ ] **Step 4: Controllo incrociato sulle righe riassuntive di `ROADMAP.md` — NON fermarti al primo grep**

Questo passo ha trovato un disallineamento dimenticato in ogni sessione precedente in cui è stato eseguito con cura. Cerca **tutte** le righe che elencano lo stato complessivo, non solo il punto 20 stesso:

```bash
grep -n "resta solo #20\|punto \"valore aggiunto\" libero\|Nessun punto critico\|Da dove partire\|Stato aggiornato" Docs/ROADMAP.md
```

Per ogni riga trovata che menziona ancora #20 come aperto o come "l'unico punto rimasto", aggiornala per riflettere che è stato fatto — a questo punto **tutti** i 20 punti della revisione originale sono ✅ fatti o 🚫 valutati e decisi esplicitamente contro (nessuno resta aperto). Verifica anche se serve una nuova riga di chiusura tipo "Roadmap completa: nessun punto aperto" — solo se è coerente con lo stile del documento, non inventare una sezione nuova se non serve.

- [ ] **Step 5: Commit**

```bash
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "$(cat <<'EOF'
Update Docs/CLAUDE.md and ROADMAP.md: review launch badge (#20) shipped

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
