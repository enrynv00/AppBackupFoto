# Touch ID all'avvio — Implementation Plan (roadmap #30)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) o superpowers:executing-plans per implementare questo piano task-per-task. Gli step usano checkbox (`- [ ]`) per il tracking.

**Goal:** Aggiungere un gate Touch ID all'avvio di AppBackupFoto (spec: `Docs/superpowers/specs/2026-08-17-touchid-auth-design.md`) — prompt automatico su `LockScreenView` prima di `ContentView`/`SetupView`, fallback nativo a password Mac, toggle disattivabile in Impostazioni (default attivo).

**Architecture:** Nuovo singleton `AuthGateManager` (`ObservableObject`, stesso stile di `AppearanceManager`) con `unlocked`/`isAuthenticating` pubblicati e `authenticate()` che chiama `LAContext().evaluatePolicy(.deviceOwnerAuthentication, ...)`. `RootView` guadagna un terzo ramo (`LockScreenView`) prima dei due esistenti (`ContentView`/`SetupView`). Toggle persistito in `UserDefaults` (chiave `"touchIDEnabled"`, default `true`), letto/scritto sia da `AuthGateManager` sia dal nuovo `Toggle` in `SettingsSheet`.

**Tech Stack:** `LocalAuthentication` (nuovo import), SwiftUI (`ContentView.swift`, unico file — convenzione esplicita del progetto), Xcode/`xcodebuild` per la verifica.

## Global Constraints

- Tutto il codice va in `AppBackupFoto/ContentView.swift` — nessun file nuovo (convenzione esplicita del progetto, vedi `Docs/CLAUDE.md`).
- Nessuna modifica a `FileSyncer`/`S3Syncer`/`BackupRunner`/regole zero-delete-zero-overwrite — questa feature tocca solo l'accesso all'interfaccia, mai i dati.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) devono restare verdi dopo ogni task.
- Nessun unit test per `authenticate()`/`evaluatePolicy` stesso — richiede hardware/interazione reale, stesso precedente di altre chiamate AppKit/system imperative già nel progetto (es. badge Dock #15). Verifica di questa parte solo manuale, a fine piano.
- `MenuBarExtra` resta intenzionalmente fuori scope (vedi spec, sezione "Fuori scope") — non aggiungere gating lì.

---

## Task 1: `AuthGateManager` + `LockScreenView` + wiring in `RootView`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (aggiunta import, nuova classe `AuthGateManager`, nuova view `LockScreenView`, modifica `RootView`)

**Interfaces:**
- Consumes: nessuno (primo task).
- Produces: `AuthGateManager.shared` (`unlocked: Bool`, `touchIDEnabled: Bool`, `authenticate()`) — consumato dal Task 2 (toggle in Impostazioni) e già cablato in `RootView` in questo stesso task.

- [ ] **Step 1: Aggiungere l'import `LocalAuthentication`** in cima a `ContentView.swift`, insieme agli import esistenti (`import SwiftUI`, ecc., riga 1-9).

- [ ] **Step 2: Aggiungere `AuthGateManager`**, subito dopo `AppearanceManager` (stesso file, stesso stile: singleton, lettura/scrittura manuale `UserDefaults`, non `@AppStorage` perché non è una `View`):

```swift
// MARK: - AuthGateManager
final class AuthGateManager: ObservableObject {
    static let shared = AuthGateManager()
    @Published var unlocked: Bool = false
    @Published var isAuthenticating: Bool = false
    @Published var lastError: String?

    var touchIDEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "touchIDEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "touchIDEnabled") }
    }

    private init() {}

    func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "Sblocca AppBackupFoto") { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unlocked = true
                } else {
                    self.lastError = error?.localizedDescription ?? "Autenticazione non riuscita"
                }
            }
        }
    }
}
```

- [ ] **Step 3: Aggiungere `LockScreenView`**, subito dopo `AuthGateManager`:

```swift
// MARK: - LockScreenView
struct LockScreenView: View {
    @ObservedObject private var gate = AuthGateManager.shared
    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Image(systemName: "touchid")
                .font(.system(size: AppIconSize.heroLarge))
                .foregroundStyle(AppColor.utility)
            Text("AppBackupFoto è bloccata").font(AppFont.title)
            if let err = gate.lastError {
                Text(err).font(.caption).foregroundStyle(AppColor.error).multilineTextAlignment(.center)
            }
            Button {
                gate.authenticate()
            } label: {
                Text(gate.isAuthenticating ? "Autenticazione…" : "Sblocca con Touch ID")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .disabled(gate.isAuthenticating)
        }
        .padding(AppSpacing.xxl)
        .frame(minWidth: 480, minHeight: 320)
        .onAppear { gate.authenticate() }
    }
}
```

Nota: `AppColor.utility`/`AppIconSize.heroLarge` sono token già esistenti e verificati nel codice attuale (`AppColor.utility = Color(NSColor.systemGray)`, `AppIconSize.heroLarge = 48`, vedi inizio file, roadmap #21).

- [ ] **Step 4: Modificare `RootView.body`** per anteporre il nuovo ramo:

```swift
struct RootView: View {
    @ObservedObject private var bm = BookmarkManager.shared
    @ObservedObject private var gate = AuthGateManager.shared
    var body: some View {
        Group {
            if gate.touchIDEnabled && !gate.unlocked { LockScreenView() }
            else if bm.canEnterApp { ContentView() }
            else { SetupView() }
        }
        .onAppear {
            Notifier.requestAuthorization()
            AppearanceManager.shared.apply()
        }
        // ... resto invariato (alert bm.pendingAlert)
    }
}
```

Solo l'aggiunta della proprietà `@ObservedObject private var gate` e della prima condizione nel `Group` — il resto di `RootView` (l'`.alert` su `bm.pendingAlert`) resta identico.

- [ ] **Step 5: Build**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: stessa suite verde di prima (nessun nuovo test in questo task — `authenticate()` non è testabile automaticamente, vedi Global Constraints), nessuna regressione.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add Touch ID auth gate (AuthGateManager, LockScreenView, roadmap #30)"
```

---

## Task 2: Toggle in Impostazioni

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (`SettingsSheet`)

**Interfaces:**
- Consumes: `AuthGateManager.shared.touchIDEnabled` dal Task 1.
- Produces: nessuna nuova interfaccia — task terminale lato UI.

- [ ] **Step 1: Aggiungere il toggle in `SettingsSheet.body`**, subito dopo il blocco esistente del toggle "Backup automatico" (righe ~3030-3034):

```swift
VStack(alignment: .leading, spacing: AppSpacing.xs) {
    Toggle("Richiedi Touch ID all'avvio", isOn: Binding(
        get: { AuthGateManager.shared.touchIDEnabled },
        set: { AuthGateManager.shared.touchIDEnabled = $0 }
    ))
    Text("Se disattivato, l'app si apre senza chiedere l'autenticazione.")
        .font(.caption).foregroundStyle(.secondary)
}.padding(.horizontal, AppSpacing.xl)
```

`AuthGateManager` non è `@Published`-friendly da `SettingsSheet` per il binding diretto (la proprietà è un computed su `UserDefaults`, non un `@Published` — a differenza di `autoBackupEnabled` che usa `@AppStorage`); il `Binding` esplicito sopra è la scelta più semplice senza duplicare stato. Se in pratica risultasse più pulito, un `@Published var touchIDEnabled` con `didSet` che scrive `UserDefaults` (stesso pattern di `AppearanceManager.mode`) è un'alternativa equivalente — usare quella se il binding manuale risultasse scomodo da collegare a `@ObservedObject`.

- [ ] **Step 2: Build**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add Touch ID toggle to Settings (roadmap #30)"
```

---

## Task 3: Doc update + verifica finale

**Files:**
- Modify: `.claude/rules/architecture.md` (nuova voce per `AuthGateManager`/`LockScreenView`, stesso stile delle altre voci di `RootView`/`BackupRunner`)
- Modify: `Docs/ROADMAP.md` (marcare #30 come fatto, **controllo incrociato obbligatorio**: non fermarsi alla prima riga trovata da un grep su "#30" o "Touch ID" — verificare tutte le occorrenze riassuntive nel file, stessa lezione già applicata per #14/#15/#16)

**Interfaces:**
- Consumes: output dei Task 1 e 2 (feature completa e buildabile).
- Produces: nessuno (task terminale del piano).

- [ ] **Step 1: Aggiungere una voce in `.claude/rules/architecture.md`**, sezione `### App entry & Root` o subito dopo, che descriva `AuthGateManager`/`LockScreenView` con lo stesso livello di dettaglio delle voci esistenti (vedi es. la voce "Badge di Revisione all'avvio" per lo stile) — cosa fa, dove si aggancia in `RootView`, che la policy `.deviceOwnerAuthentication` include il fallback a password nativo.

- [ ] **Step 2: Aggiornare `Docs/ROADMAP.md`**

Cambiare la riga del punto 30 da `30. 🔲 **Impronta digitale...` a `30. ✅ **Fatto (2026-08-17) — Impronta digitale...`, con una frase di riepilogo simile alle altre voci "Fatto". Poi cercare **tutte** le altre occorrenze di riferimenti al capitolo #27-30 nel file (es. righe di riepilogo tipo "Nessuno dei 4 punti ha ancora una spec") e aggiornarle per riflettere che #30 è ora fatto, gli altri 3 no:

```bash
grep -n "#30\|27-30\|4 punti" /Users/enriconannivicenzi/Desktop/AppBackupFoto/Docs/ROADMAP.md
```

Aggiornare ogni riga trovata che presuppone ancora "nessuno dei 4 fatto" — non fermarsi alla prima occorrenza.

- [ ] **Step 3: Build + test finali**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -5
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: entrambi verdi (`** BUILD SUCCEEDED **`, tutti i test passano, nessuna regressione sul conteggio totale rispetto a prima di questo piano).

- [ ] **Step 4: Commit**

```bash
git add .claude/rules/architecture.md Docs/ROADMAP.md
git commit -m "Update docs: Touch ID auth gate shipped (roadmap #30)"
```

- [ ] **Step 5: Nota per la verifica manuale (non automatizzabile da qui, da riportare a Enrico a fine piano)**

Non eseguibile via tool — richiede interazione reale con Touch ID/password:
1. Compilare e lanciare l'app (`Cmd+R` da Xcode, o installarla come da `Docs/CLAUDE.md` → "Build e distribuzione").
2. All'avvio deve comparire subito il prompt di sistema Touch ID (o password se il Mac non ha il sensore).
3. Annullare il prompt → verificare che compaia `LockScreenView` con il messaggio d'errore e il bottone "Sblocca con Touch ID" cliccabile per ritentare.
4. Autenticarsi con successo → verificare che si arrivi a `ContentView` (o `SetupView` se il setup non è completo).
5. Aprire Impostazioni, disattivare "Richiedi Touch ID all'avvio", chiudere e riaprire l'app → verificare che si entri direttamente senza prompt.
6. Riattivare il toggle, richiudere e riaprire → verificare che il prompt torni.
