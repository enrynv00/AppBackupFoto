# Fase 5 — Migrazione dialoghi (roadmap #25) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sostituire i 14 `NSAlert` AppKit con `.alert` SwiftUI, usando un tipo condiviso `SimpleAlert` e stato pubblicato dove necessario, senza cambiare testo/comportamento di nessun alert.

**Architecture:** Un tipo condiviso `SimpleAlert` (definito una volta, vicino agli altri design token). `BackupRunner`/`BookmarkManager` (classi non-View) guadagnano `@Published var pendingAlert: SimpleAlert?`, consumato da `.alert(item:)` nella View giusta. `ToolsSheet`/`ContentView` (già View) usano `@State` locale.

**Tech Stack:** SwiftUI. Nessuna nuova dipendenza.

## Global Constraints

- Nessun nuovo file `.swift` — tutto dentro `AppBackupFoto/ContentView.swift`.
- Nessun cambio a design token/componenti/micro-interazioni delle fasi precedenti.
- Nessun cambio al testo/wording di nessun alert — stesso `messageText`/`informativeText`/titoli bottone di oggi in ogni migrazione.
- Nessun `.confirmationDialog` — nessuno dei 14 alert ha più di 2 bottoni, `.alert` basta ovunque.
- Ogni task termina con build (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`, atteso `** BUILD SUCCEEDED **`) e test (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test`, attesi tutti verdi — se un test fallisce con un timeout ambientale tipo "test runner hung before establishing connection", è un flake noto, riprova una volta) prima del commit. Nessun nuovo XCTest sensato in questa fase (solo presentazione UI, stesso ragionamento delle fasi precedenti).
- I numeri di riga sotto sono verificati al momento della scrittura di questo piano (2026-08-12, dopo la chiusura di Fase 1-4) — possono slittare da un task al successivo. Localizza sempre il contenuto reale con grep/ricerca testuale prima di ogni edit; se il contenuto reale differisce sostanzialmente da quanto mostrato, fermati e segnala invece di procedere alla cieca.

---

### Task 1: Tipo `SimpleAlert` + `BackupRunner.pendingAlert` + helper condiviso + `.alert()` su `ContentView`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo tipo vicino agli altri design token, oggi dopo `enum AppIconSize` a riga ~57-60; struct `BackupRunner` riga ~1575, helper `alert(_:_:)` riga ~2063; struct `ContentView` riga ~2898, fine del `body` dopo `.sheet(isPresented: $showSettings)` riga ~2985)

**Interfaces:**
- Consumes: nessuna.
- Produces: `struct SimpleAlert: Identifiable { let id: UUID; var title: String; var message: String; var isDestructive: Bool; var confirmTitle: String; var cancelTitle: String?; var onConfirm: (() -> Void)? }`, `BackupRunner.pendingAlert: SimpleAlert?` — usati dai Task 2, 3, 7.

- [ ] **Step 1: Verifica i punti di inserimento**

```bash
grep -n "^enum AppIconSize" -A 5 AppBackupFoto/ContentView.swift
grep -n "private func alert(_ title: String, _ msg: String)" -A 4 AppBackupFoto/ContentView.swift
grep -n "struct ContentView: View" AppBackupFoto/ContentView.swift
grep -n "\.sheet(isPresented: \$showSettings)" AppBackupFoto/ContentView.swift
```

- [ ] **Step 2: Aggiungi `SimpleAlert` subito dopo `enum AppIconSize`**

```swift
/// Alert semplice riusato ovunque: cancelTitle nil = solo un bottone (informativo),
/// cancelTitle impostato = conferma a 2 bottoni con onConfirm eseguito sulla scelta primaria.
struct SimpleAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String = ""
    var isDestructive: Bool = false
    var confirmTitle: String = "OK"
    var cancelTitle: String? = nil
    var onConfirm: (() -> Void)? = nil
}

```

- [ ] **Step 3: Aggiungi `@Published var pendingAlert` a `BackupRunner`**

Subito dopo `@Published var s3ConfigError: Error? = nil` (le altre `@Published` già esistenti in cima a `BackupRunner`):
```swift
    @Published var pendingAlert: SimpleAlert? = nil
```

- [ ] **Step 4: Migra l'helper condiviso `alert(_:_:)`**

```swift
// Prima:
    private func alert(_ title: String, _ msg: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = msg
        a.alertStyle = .warning; a.runModal()
    }
// Dopo:
    private func alert(_ title: String, _ msg: String) {
        pendingAlert = SimpleAlert(title: title, message: msg)
    }
```

(le ~20 chiamate esistenti `alert("...", "...")`/`self.alert("...", "...")` sparse in `runMacToSSD`/`runSSDToHDD`/`runSyncS3` e le loro anteprime restano invariate come sintassi — cambia solo l'implementazione dell'helper)

- [ ] **Step 5: Aggiungi `.alert(item:)` a `ContentView.body`**

Trova la fine del `body` (dopo `.sheet(isPresented: $showSettings) { SettingsSheet() }`, subito prima della chiusura `}` del `body`):
```swift
// Prima:
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }
// Dopo:
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .alert(item: $runner.pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 8: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add SimpleAlert type, migrate BackupRunner's shared alert() helper (roadmap #25)

Nuovo tipo SimpleAlert (Identifiable, title/message/azione opzionale
di conferma) riusato da tutte le migrazioni di questa fase.
BackupRunner.pendingAlert (@Published) sostituisce le chiamate NSAlert
dell'helper condiviso alert(_:_:) — usato da ~20 guardie di
validazione in runMacToSSD/runSSDToHDD/runSyncS3 e anteprime, nessun
call site toccato. ContentView presenta tutto con un solo
.alert(item: $runner.pendingAlert).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Migra le 5 chiamate `NSAlert` dirette in `BackupRunner`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `BackupRunner`, 5 blocchi `NSAlert()` oggi a righe ~1660, ~1713, ~1815, ~1858, ~1886)

**Interfaces:**
- Consumes: `BackupRunner.pendingAlert`, `SimpleAlert` (Task 1).
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica le 5 occorrenze**

```bash
grep -n "let a = NSAlert()" AppBackupFoto/ContentView.swift
```

Nel range di `BackupRunner` (righe ~1575-2065) dovrebbero comparire 5 occorrenze. Se il conteggio o il contenuto differisce sostanzialmente da quanto mostrato sotto, fermati e segnala.

- [ ] **Step 2: Migra "Spazio insufficiente sull'SSD"**

```swift
// Prima:
                let a = NSAlert()
                a.messageText = "Spazio insufficiente sull'SSD"
                a.informativeText = "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                    + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(ssdURL.path)."
                a.alertStyle = .warning
                a.addButton(withTitle: "OK")
                a.runModal()
                return
// Dopo:
                pendingAlert = SimpleAlert(
                    title: "Spazio insufficiente sull'SSD",
                    message: "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                        + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(ssdURL.path).")
                return
```

- [ ] **Step 3: Migra "Spazio insufficiente sull'HDD"**

```swift
// Prima:
                let a = NSAlert()
                a.messageText = "Spazio insufficiente sull'HDD"
                a.informativeText = "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                    + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(hddURL.path)."
                a.alertStyle = .warning
                a.addButton(withTitle: "OK")
                a.runModal()
                return
// Dopo:
                pendingAlert = SimpleAlert(
                    title: "Spazio insufficiente sull'HDD",
                    message: "Servono circa \(ByteCountFormatter.string(fromByteCount: preview.toAddBytes, countStyle: .file)), "
                        + "liberi \(ByteCountFormatter.string(fromByteCount: space.availableBytes, countStyle: .file)) su \(hddURL.path).")
                return
```

- [ ] **Step 4: Migra "Anteprima MAC -> SSD"**

```swift
// Prima:
            let a = NSAlert()
            a.messageText = "Anteprima MAC -> SSD"
            a.informativeText = "File da copiare: \(result.toAdd)\nFile gia presenti (skip): \(result.toSkip)\nTempo stimato: \(eta)\n\n(stima basata su 50 file/s - il tempo reale puo variare)"
            a.alertStyle = .informational
            a.addButton(withTitle: "OK")
            a.runModal()
// Dopo:
            pendingAlert = SimpleAlert(
                title: "Anteprima MAC -> SSD",
                message: "File da copiare: \(result.toAdd)\nFile gia presenti (skip): \(result.toSkip)\nTempo stimato: \(eta)\n\n(stima basata su 50 file/s - il tempo reale puo variare)")
```

- [ ] **Step 5: Migra "Anteprima SSD -> HDD"**

```swift
// Prima:
            let a = NSAlert()
            a.messageText = "Anteprima SSD -> HDD"
            a.informativeText = "Modalita: \(modeLabel)\nFile da copiare: \(result.toAdd)\nFile gia presenti (skip): \(result.toSkip)\nTempo stimato: \(eta)\n\n(stima basata su 50 file/s - il tempo reale puo variare)"
            a.alertStyle = .informational
            a.addButton(withTitle: "OK")
            a.runModal()
// Dopo:
            pendingAlert = SimpleAlert(
                title: "Anteprima SSD -> HDD",
                message: "Modalita: \(modeLabel)\nFile da copiare: \(result.toAdd)\nFile gia presenti (skip): \(result.toSkip)\nTempo stimato: \(eta)\n\n(stima basata su 50 file/s - il tempo reale puo variare)")
```

- [ ] **Step 6: Migra "Anteprima SSD -> Cubbit S3"**

```swift
// Prima:
                    let a = NSAlert()
                    a.messageText = "Anteprima SSD -> Cubbit S3"
                    a.informativeText = "File da caricare: \(result.toUpload) (~\(String(format: "%.1f", gb)) GB)\nFile già presenti (skip): \(result.toSkip)\n\n(il tempo dipende dalla velocità della tua connessione, non stimato qui)"
                    a.alertStyle = .informational
                    a.addButton(withTitle: "OK")
                    a.runModal()
// Dopo:
                    pendingAlert = SimpleAlert(
                        title: "Anteprima SSD -> Cubbit S3",
                        message: "File da caricare: \(result.toUpload) (~\(String(format: "%.1f", gb)) GB)\nFile già presenti (skip): \(result.toSkip)\n\n(il tempo dipende dalla velocità della tua connessione, non stimato qui)")
```

- [ ] **Step 7: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Se `pendingAlert = SimpleAlert(...)` non è raggiungibile da un contesto async (`Task`/`await`) senza `await MainActor.run { }`, il compilatore lo segnalerà — `BackupRunner` è già annotato `@MainActor`/`ObservableObject` osservato da SwiftUI, quindi l'assegnazione diretta dovrebbe essere già sul thread giusto in tutti e 5 i casi (stesso ragionamento già documentato in `.claude/rules/architecture.md` per gli altri `@Published` di `BackupRunner`); se il compilatore chiede diversamente, avvolgi con `await MainActor.run { pendingAlert = ... }` solo dove richiesto.

- [ ] **Step 8: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 9: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Migrate 5 direct NSAlert calls in BackupRunner (roadmap #25)

Spazio insufficiente SSD/HDD, anteprime Mac→SSD/SSD→HDD/SSD→S3 —
stesso testo di oggi, ora passano da pendingAlert invece di NSAlert.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `BookmarkManager.pendingAlert`, osservato in `RootView` e `ToolsSheet`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `BookmarkManager` riga ~433, il suo unico `NSAlert()` riga ~515; struct `RootView` riga ~298; struct `ToolsSheet` riga ~3687)

**Interfaces:**
- Consumes: `SimpleAlert` (Task 1).
- Produces: `BookmarkManager.pendingAlert: SimpleAlert?`.

- [ ] **Step 1: Verifica i 3 punti**

```bash
grep -n "final class BookmarkManager" AppBackupFoto/ContentView.swift
grep -n "let a = NSAlert()" AppBackupFoto/ContentView.swift
grep -n "struct RootView: View" -A 10 AppBackupFoto/ContentView.swift
grep -n "struct ToolsSheet: View" AppBackupFoto/ContentView.swift
```

- [ ] **Step 2: Aggiungi `@Published var pendingAlert` a `BookmarkManager`**

Subito dopo `static let shared = BookmarkManager()`:
```swift
    @Published var pendingAlert: SimpleAlert? = nil
```

- [ ] **Step 3: Migra l'unico `NSAlert` di `BookmarkManager`**

```swift
// Prima:
                let a = NSAlert()
                a.messageText = "Impossibile salvare '\(loc.displayName)'"
                a.informativeText = "Percorso: \(url.path)\n\nErrore: \(nsError.localizedDescription)\n(dominio \(nsError.domain), codice \(nsError.code))"
                a.alertStyle = .critical
                a.runModal()
// Dopo:
                pendingAlert = SimpleAlert(
                    title: "Impossibile salvare '\(loc.displayName)'",
                    message: "Percorso: \(url.path)\n\nErrore: \(nsError.localizedDescription)\n(dominio \(nsError.domain), codice \(nsError.code))")
```

- [ ] **Step 4: Aggiungi `.alert(item:)` a `RootView`**

```swift
// Prima:
struct RootView: View {
    @ObservedObject private var bm = BookmarkManager.shared
    var body: some View {
        Group {
            if bm.canEnterApp { ContentView() }
            else { SetupView() }
        }
        .onAppear {
            Notifier.requestAuthorization()
            AppearanceManager.shared.apply()
        }
    }
}
// Dopo:
struct RootView: View {
    @ObservedObject private var bm = BookmarkManager.shared
    var body: some View {
        Group {
            if bm.canEnterApp { ContentView() }
            else { SetupView() }
        }
        .onAppear {
            Notifier.requestAuthorization()
            AppearanceManager.shared.apply()
        }
        .alert(item: $bm.pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }
}
```

- [ ] **Step 5: Aggiungi lo stesso `.alert(item:)` a `ToolsSheet`**

Trova la fine del `body` di `ToolsSheet` (dopo `.groupBoxStyle(CardGroupBoxStyle())`, subito prima della chiusura `}` del `body`):
```swift
// Prima:
        .padding(AppSpacing.xxl).frame(minWidth: 560, minHeight: 480)
        .groupBoxStyle(CardGroupBoxStyle())
    }
}
// Dopo:
        .padding(AppSpacing.xxl).frame(minWidth: 560, minHeight: 480)
        .groupBoxStyle(CardGroupBoxStyle())
        .alert(item: $bm.pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }
}
```

(sì, lo stesso identico blocco `.alert(item: $bm.pendingAlert) { ... }` in due posti — è la stessa fonte di stato osservata da due finestre indipendenti, come spiegato nella spec)

- [ ] **Step 6: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 8: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Migrate BookmarkManager's NSAlert, observed from 2 windows (roadmap #25)

selectAndSave() può fallire sia da SetupView (RootView) sia dalla
finestra Diagnostica separata (ToolsSheet, "Cartelle Configurate")
— entrambe osservano lo stesso BookmarkManager.pendingAlert con lo
stesso blocco .alert(item:), non un singolo punto di presentazione.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `ToolsSheet` — `@State pendingAlert` + migra `confirmReveal`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `ToolsSheet` riga ~3687, funzione `confirmReveal` riga ~3717)

**Interfaces:**
- Consumes: `SimpleAlert` (Task 1).
- Produces: `ToolsSheet.pendingAlert: SimpleAlert?` (locale, `@State`) — usato dai Task 5 e 6.

**Nota**: `ToolsSheet` ha già `.alert(item: $bm.pendingAlert)` dal Task 3 — questo task aggiunge un **secondo** `.alert(item:)`, per uno stato diverso (`pendingAlert` locale della sheet, non `bm.pendingAlert`). SwiftUI supporta più modificatori `.alert()` sulla stessa view: non sono mai presentati insieme nella pratica, dato che uno stato diventa non-nil alla volta.

- [ ] **Step 1: Verifica `confirmReveal` e aggiungi lo `@State`**

```bash
grep -n "private func confirmReveal" -A 10 AppBackupFoto/ContentView.swift
```

Subito dopo `@State private var integrityStatus = ""` (le altre `@State` esistenti di `ToolsSheet`):
```swift
    @State private var pendingAlert: SimpleAlert? = nil
```

- [ ] **Step 2: Migra `confirmReveal`**

```swift
// Prima:
    private func confirmReveal(_ action: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "Rivelare le credenziali S3?"
        a.informativeText = "Chiunque veda o registri lo schermo in questo momento potrà usarle per scrivere o cancellare file sul bucket. Continua solo se sei sicuro che nessuno stia guardando."
        a.alertStyle = .warning
        a.addButton(withTitle: "Continua")
        a.addButton(withTitle: "Annulla")
        if a.runModal() == .alertFirstButtonReturn { action() }
    }
// Dopo:
    private func confirmReveal(_ action: @escaping () -> Void) {
        pendingAlert = SimpleAlert(
            title: "Rivelare le credenziali S3?",
            message: "Chiunque veda o registri lo schermo in questo momento potrà usarle per scrivere o cancellare file sul bucket. Continua solo se sei sicuro che nessuno stia guardando.",
            confirmTitle: "Continua",
            cancelTitle: "Annulla",
            onConfirm: action)
    }
```

- [ ] **Step 3: Aggiungi il secondo `.alert(item:)` per `pendingAlert` locale**

Subito dopo il blocco `.alert(item: $bm.pendingAlert) { ... }` aggiunto nel Task 3 (fine del `body` di `ToolsSheet`):
```swift
// Prima (fine del body, dopo il Task 3):
        } message: { a in
            Text(a.message)
        }
    }
}
// Dopo:
        } message: { a in
            Text(a.message)
        }
        .alert(item: $pendingAlert) { a in
            Button(a.confirmTitle, role: a.isDestructive ? .destructive : nil) { a.onConfirm?() }
            if let cancelTitle = a.cancelTitle {
                Button(cancelTitle, role: .cancel) {}
            }
        } message: { a in
            Text(a.message)
        }
    }
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add ToolsSheet local pendingAlert, migrate confirmReveal (roadmap #25)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `ToolsSheet` — migra il flusso "Aggiorna da rclone.conf"

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (bottone "Aggiorna da rclone.conf" dentro `ToolsSheet`, oggi riga ~3789-3806)

**Interfaces:**
- Consumes: `ToolsSheet.pendingAlert` (Task 4).
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica il blocco attuale**

```bash
grep -n 'Button("Aggiorna da rclone.conf")' -A 18 AppBackupFoto/ContentView.swift
```

Contenuto atteso:
```swift
                        Button("Aggiorna da rclone.conf") {
                            let a = NSAlert()
                            a.messageText = "Sovrascrivere le credenziali salvate?"
                            a.informativeText = "Le credenziali attualmente nel Keychain verranno sostituite con quelle lette ora da rclone.conf."
                            a.alertStyle = .warning
                            a.addButton(withTitle: "Continua")
                            a.addButton(withTitle: "Annulla")
                            guard a.runModal() == .alertFirstButtonReturn else { return }
                            do {
                                let config = try S3Syncer.readConfigFromFile(remoteName: "Cubbit", bucket: "backupfoto")
                                try S3Syncer.writeToKeychain(config: config, remoteName: "Cubbit")
                                let ok = NSAlert()
                                ok.messageText = "Credenziali aggiornate nel Keychain."
                                ok.runModal()
                            } catch {
                                let err = NSAlert()
                                err.messageText = "Errore"
                                err.informativeText = error.localizedDescription
                                err.alertStyle = .critical
                                err.runModal()
                            }
                        }.buttonStyle(.bordered).controlSize(.small).padding(.top, AppSpacing.xs)
```

Se differisce sostanzialmente, fermati e segnala.

- [ ] **Step 2: Sostituisci con la versione basata su `pendingAlert`**

```swift
                        Button("Aggiorna da rclone.conf") {
                            pendingAlert = SimpleAlert(
                                title: "Sovrascrivere le credenziali salvate?",
                                message: "Le credenziali attualmente nel Keychain verranno sostituite con quelle lette ora da rclone.conf.",
                                confirmTitle: "Continua",
                                cancelTitle: "Annulla",
                                onConfirm: {
                                    do {
                                        let config = try S3Syncer.readConfigFromFile(remoteName: "Cubbit", bucket: "backupfoto")
                                        try S3Syncer.writeToKeychain(config: config, remoteName: "Cubbit")
                                        pendingAlert = SimpleAlert(title: "Credenziali aggiornate nel Keychain.")
                                    } catch {
                                        pendingAlert = SimpleAlert(title: "Errore", message: error.localizedDescription)
                                    }
                                })
                        }.buttonStyle(.bordered).controlSize(.small).padding(.top, AppSpacing.xs)
```

(3 `NSAlert` — conferma, successo, errore — diventano una sequenza di 1-2 assegnazioni a `pendingAlert` dentro `onConfirm`, stesso testo di oggi in tutti e 3 i casi)

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Migrate "Aggiorna da rclone.conf" confirm/result flow (roadmap #25)

Conferma → successo/errore: 3 NSAlert diventano una sequenza di
assegnazioni a pendingAlert dentro onConfirm, stesso testo di oggi.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `ToolsSheet` — migra il flusso "Elimina" upload orfano

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (bottone "Elimina" dentro `ToolsSheet`, oggi riga ~3909-3936)

**Interfaces:**
- Consumes: `ToolsSheet.pendingAlert` (Task 4).
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica il blocco attuale**

```bash
grep -n 'Button("Elimina")' -A 27 AppBackupFoto/ContentView.swift
```

Contenuto atteso:
```swift
                                Button("Elimina") {
                                    let a = NSAlert()
                                    a.messageText = "Eliminare questo upload incompleto?"
                                    a.informativeText = "Rimuove definitivamente le parti già caricate su Cubbit per '\((upload.key as NSString).lastPathComponent)'. Non tocca file già completati né la sorgente."
                                    a.alertStyle = .warning
                                    a.addButton(withTitle: "Elimina")
                                    a.addButton(withTitle: "Annulla")
                                    guard a.runModal() == .alertFirstButtonReturn else { return }
                                    Task {
                                        do {
                                            guard let config = runner.s3Config else {
                                                throw NSError(domain: "S3", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                                    "Configurazione S3 non disponibile — chiudi e riapri Tools."])
                                            }
                                            try await S3Syncer().abortMultipartUpload(
                                                key: upload.key, uploadId: upload.uploadId, config: config)
                                            await MainActor.run {
                                                runner.toolsOrphanedUploads.removeAll { $0.id == upload.id }
                                            }
                                        } catch {
                                            await MainActor.run {
                                                let errA = NSAlert()
                                                errA.messageText = "Impossibile eliminare l'upload"
                                                errA.informativeText = error.localizedDescription
                                                errA.alertStyle = .critical
                                                errA.runModal()
                                            }
                                        }
                                    }
                                }.buttonStyle(.bordered).controlSize(.small)
```

Se differisce sostanzialmente, fermati e segnala.

- [ ] **Step 2: Sostituisci con la versione basata su `pendingAlert`**

```swift
                                Button("Elimina") {
                                    pendingAlert = SimpleAlert(
                                        title: "Eliminare questo upload incompleto?",
                                        message: "Rimuove definitivamente le parti già caricate su Cubbit per '\((upload.key as NSString).lastPathComponent)'. Non tocca file già completati né la sorgente.",
                                        isDestructive: true,
                                        confirmTitle: "Elimina",
                                        cancelTitle: "Annulla",
                                        onConfirm: {
                                            Task {
                                                do {
                                                    guard let config = runner.s3Config else {
                                                        throw NSError(domain: "S3", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                                            "Configurazione S3 non disponibile — chiudi e riapri Tools."])
                                                    }
                                                    try await S3Syncer().abortMultipartUpload(
                                                        key: upload.key, uploadId: upload.uploadId, config: config)
                                                    await MainActor.run {
                                                        runner.toolsOrphanedUploads.removeAll { $0.id == upload.id }
                                                    }
                                                } catch {
                                                    await MainActor.run {
                                                        pendingAlert = SimpleAlert(title: "Impossibile eliminare l'upload", message: error.localizedDescription)
                                                    }
                                                }
                                            }
                                        })
                                }.buttonStyle(.bordered).controlSize(.small)
```

(`isDestructive: true` sul primo alert — il bottone "Elimina" ora usa `role: .destructive`, coerente con l'azione irreversibile, un piccolo miglioramento nativo SwiftUI che `NSAlert` non aveva; il resto del testo/comportamento è identico a oggi)

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Migrate orphaned upload delete confirm/error flow (roadmap #25)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `ContentView.confirmQuit` — alert booleano dedicato

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `ContentView`, funzione `confirmQuit` oggi riga ~2988; fine del `body`)

**Interfaces:**
- Consumes: nessuna (non usa `SimpleAlert`, per scelta della spec — caso unico non riusato).
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica `confirmQuit`**

```bash
grep -n "private func confirmQuit" -A 8 AppBackupFoto/ContentView.swift
```

Contenuto atteso:
```swift
    private func confirmQuit() {
        let a = NSAlert(); a.messageText = "Chiudere l'app?"
        a.informativeText = "I processi in corso verranno interrotti."
        a.alertStyle = .warning; a.addButton(withTitle: "Esci"); a.addButton(withTitle: "Annulla")
        if a.runModal() == .alertFirstButtonReturn {
            if runner.isRunning { runner.stop() }
            NSApp.terminate(nil)
        }
    }
```

- [ ] **Step 2: Aggiungi lo `@State` e semplifica `confirmQuit`**

Subito dopo `@AppStorage("autoBackupOnSSDConnect") private var autoBackupEnabled: Bool = true`:
```swift
    @State private var showQuitConfirm = false
```

```swift
// Prima:
    private func confirmQuit() {
        let a = NSAlert(); a.messageText = "Chiudere l'app?"
        a.informativeText = "I processi in corso verranno interrotti."
        a.alertStyle = .warning; a.addButton(withTitle: "Esci"); a.addButton(withTitle: "Annulla")
        if a.runModal() == .alertFirstButtonReturn {
            if runner.isRunning { runner.stop() }
            NSApp.terminate(nil)
        }
    }
// Dopo:
    private func confirmQuit() {
        showQuitConfirm = true
    }
```

- [ ] **Step 3: Aggiungi l'alert al `body`**

Subito dopo il blocco `.alert(item: $runner.pendingAlert) { ... } message: { ... }` aggiunto nel Task 1 (fine del `body` di `ContentView`):
```swift
// Dopo il blocco del Task 1:
        .alert("Chiudere l'app?", isPresented: $showQuitConfirm) {
            Button("Esci", role: .destructive) {
                if runner.isRunning { runner.stop() }
                NSApp.terminate(nil)
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("I processi in corso verranno interrotti.")
        }
    }
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 6: Verifica manuale visiva**

Avvia l'app (bundle in `~/Library/Developer/Xcode/DerivedData`, trova con `find ~/Library/Developer/Xcode/DerivedData -iname "AppBackupFoto.app" -maxdepth 6`), clicca "Esci" nella finestra principale, controlla che compaia l'alert SwiftUI nativo (non più una finestra `NSAlert` separata) con "Chiudere l'app?"/"I processi in corso verranno interrotti."/bottoni "Esci"/"Annulla". Clicca "Annulla" per verificare che l'app resti aperta, poi chiudila normalmente.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Migrate confirmQuit to dedicated boolean alert (roadmap #25)

Caso unico non riusato altrove — alert booleano dedicato invece di
SimpleAlert, per scelta della spec approvata.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Aggiornare la documentazione e chiudere roadmap #25

**Files:**
- Modify: `Docs/ROADMAP.md`
- Modify: `.claude/rules/architecture.md`

**Interfaces:** nessuna — task di documentazione, chiude la Fase 5 e l'intero piano di 5 fasi.

- [ ] **Step 1: Verifica che non resti nessun `NSAlert`**

```bash
grep -n "NSAlert()" AppBackupFoto/ContentView.swift
```

Expected: nessun risultato. Se ne resta qualcuno, torna indietro e completa la migrazione mancante prima di procedere con la documentazione.

- [ ] **Step 2: In `.claude/rules/architecture.md`, aggiungi una nota sulla migrazione**

Trova il paragrafo "**Micro-interazioni (2026-08-12, roadmap #24, Fase 4)**" e aggiungi subito dopo:

```markdown

**Migrazione dialoghi (2026-08-12, roadmap #25, Fase 5)**: i 14 `NSAlert` AppKit sono stati sostituiti da `.alert` SwiftUI, tramite un tipo condiviso `SimpleAlert` (title/message/azione di conferma opzionale). `BackupRunner`/`BookmarkManager` (classi non-View) pubblicano `@Published var pendingAlert: SimpleAlert?`, consumato da `.alert(item:)` nella View giusta — `BackupRunner.pendingAlert` da `ContentView` (un solo punto, tutte le sue chiamate partono dalla finestra principale), `BookmarkManager.pendingAlert` da **due** punti (`RootView` e `ToolsSheet`, dato che `selectAndSave` può scatenare da entrambe le finestre indipendenti). `ToolsSheet`/`ContentView` (già View) usano `@State` locale invece di stato pubblicato. `ContentView.confirmQuit` resta un alert booleano dedicato, non forzato nel tipo condiviso. Chiude il piano di restyling in 5 fasi (roadmap #21-25) — nessun punto aperto.
```

- [ ] **Step 3: In `Docs/ROADMAP.md`, marca il punto 25 come fatto**

Cerca la riga:
```
25. 🔲 **Fase 5 — Dialoghi**: migrazione dei 14 `NSAlert` AppKit a `.alert`/`.confirmationDialog` SwiftUI, per un linguaggio visivo coerente.
```

Sostituisci con:
```
25. ✅ **Fatto (2026-08-12) — Fase 5, migrazione dialoghi.** I 14 `NSAlert` AppKit sostituiti da `.alert` SwiftUI (tipo condiviso `SimpleAlert`, stato pubblicato dove necessario). Chiude il piano di restyling in 5 fasi — nessun punto rimasto aperto nei punti 21-25. Vedi `Docs/superpowers/specs/2026-08-12-dialog-migration-design.md` e `Docs/superpowers/plans/2026-08-12-dialog-migration.md`.
```

- [ ] **Step 4: Controllo incrociato sulle righe riassuntive di `ROADMAP.md`**

```bash
grep -n "Roadmap completa\|nessun punto\|Stato aggiornato" Docs/ROADMAP.md
```

Per ogni riga trovata che riassume lo stato complessivo della roadmap, verifica se menziona ancora punti aperti nel capitolo "Design polish" (21-25) — se sì, aggiornala per riflettere che sono tutti fatti. Non inventare una nuova sezione di chiusura se lo stile del documento non ne ha già una simile altrove.

- [ ] **Step 5: Commit**

```bash
git add Docs/ROADMAP.md .claude/rules/architecture.md
git commit -m "$(cat <<'EOF'
Update docs: dialog migration (roadmap #25) shipped, design polish complete

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
