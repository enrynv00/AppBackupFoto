# Roadmap #15: Badge percentuale sul Dock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mostrare un badge percentuale ("42%") sull'icona dell'app nel Dock mentre un job di backup (Mac→SSD, SSD→HDD o SSD→S3) è in corso, così l'utente vede l'avanzamento senza portare la finestra in primo piano.

**Architecture:** `MenuBarIcon` (`ContentView.swift:45-51`) — la view già montata in modo persistente per tutta la durata dell'app come label del `MenuBarExtra` — guadagna due `.onChange` che osservano `runner.stats.percent` e `runner.isRunning` (entrambi già pubblicati da `BackupRunner`, aggiornati uniformemente dai tre job) e chiamano un helper `updateDockBadge()` che imposta `NSApp.dockTile.badgeLabel`. Nessun nuovo stato, nessuna modifica a `BackupRunner`.

**Tech Stack:** SwiftUI (`.onChange`), AppKit (`NSApp.dockTile.badgeLabel`).

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift`.
- Nessuna modifica a `BackupRunner` o ai metodi `run*()` — `stats.percent`/`isRunning` esistono già e bastano.
- Il badge sparisce subito a fine job (successo, errore o stop) — nessuno stato residuo.
- Nessun testo percentuale in menu bar — solo badge Dock (deciso in brainstorming, fuori scope).
- Build (`xcodebuild ... build`) verde prima del commit. Nessun XCTest per questo task (chiamata AppKit imperativa legata al Dock, non logica pura) — verifica manuale richiesta, descritta nel task.
- Baseline nota: 75 test XCTest verdi (invariati da questo task, che non tocca logica testabile).
- Comando build: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

---

### Task 1: Badge Dock in `MenuBarIcon`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:45-51`

**Interfaces:**
- Consumes: `BackupRunner.stats.percent: Int` (0-100) e `BackupRunner.isRunning: Bool`, entrambi già esistenti e pubblicati — nessuna modifica alla loro definizione.
- Produces: nessuna nuova interfaccia per altri task — modifica isolata, unico task del piano che tocca codice.

- [ ] **Step 1: Leggere il blocco attuale**

Contenuto attuale di `ContentView.swift:45-51`:

```swift
private struct MenuBarIcon: View {
    @EnvironmentObject private var runner: BackupRunner
    var body: some View {
        Image(systemName: "photo.stack")
            .symbolEffect(.pulse, isActive: runner.isRunning)
    }
}
```

- [ ] **Step 2: Sostituire il blocco con la versione che aggiorna il badge Dock**

```swift
private struct MenuBarIcon: View {
    @EnvironmentObject private var runner: BackupRunner
    var body: some View {
        Image(systemName: "photo.stack")
            .symbolEffect(.pulse, isActive: runner.isRunning)
            .onChange(of: runner.stats.percent) { _, _ in updateDockBadge() }
            .onChange(of: runner.isRunning) { _, _ in updateDockBadge() }
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = runner.isRunning ? "\(runner.stats.percent)%" : nil
    }
}
```

- [ ] **Step 3: Build per verificare che compili senza errori**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Eseguire la suite di test per confermare nessuna regressione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: `Executed 75 tests, with 0 failures` e `** TEST SUCCEEDED **` (nessuna logica applicativa toccata da questo task, stessa baseline di prima)

- [ ] **Step 5: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift
git commit -m "Add Dock progress badge during backup jobs (roadmap #15)"
```

- [ ] **Step 6: Annotare la verifica manuale ancora da fare**

Questo passo non è automatizzabile in ambiente headless (serve l'app in esecuzione con un volume reale collegato). Aggiungerla come nota per l'utente nel report finale del task, non come step eseguibile: avviare un job reale (uno qualsiasi dei tre) con l'app in background/Dock e verificare che il badge compaia sull'icona, si aggiorni con la percentuale reale, e sparisca a fine job.

---

### Task 2: Aggiornamento documentazione (`Docs/CLAUDE.md`, `Docs/ROADMAP.md`)

**Files:**
- Modify: `Docs/CLAUDE.md:166` (voce `MenuBarExtra` nella sezione UI)
- Modify: `Docs/ROADMAP.md` (voce #15 nella sezione "Valore aggiunto", e la riga riassuntiva "Fatti:"/punti rimanenti)

**Interfaces:**
- Consumes: risultato di Task 1 (badge implementato, build/test verdi)
- Produces: nessuna interfaccia di codice — solo documentazione, letta dalle sessioni future su questo progetto

- [ ] **Step 1: Aggiornare la voce `MenuBarExtra` in `Docs/CLAUDE.md`**

Trova la riga (contenuto esatto attuale, `Docs/CLAUDE.md:166`):

```
- **MenuBarExtra (2026-08-09)** — icona nella menu bar (SF Symbol `photo.stack`, pulsa con `.symbolEffect(.pulse)` mentre un job è in corso) con menu a discesa: riga di stato (job in corso / data ultimo backup / nessun backup) + bottone "Apri AppBackupFoto" (`openWindow(id: "main")` + `NSApp.activate`). Solo scorciatoia — l'app resta un'app normale con Dock icon e finestra, nessun `LSUIElement`, nessuna estensione dello scheduling automatico ad app chiusa (deliberatamente fuori scope, vedi `Docs/superpowers/specs/2026-08-09-menu-bar-shortcut-design.md`).
```

Sostituiscila con:

```
- **MenuBarExtra (2026-08-09)** — icona nella menu bar (SF Symbol `photo.stack`, pulsa con `.symbolEffect(.pulse)` mentre un job è in corso) con menu a discesa: riga di stato (job in corso / data ultimo backup / nessun backup) + bottone "Apri AppBackupFoto" (`openWindow(id: "main")` + `NSApp.activate`). Solo scorciatoia — l'app resta un'app normale con Dock icon e finestra, nessun `LSUIElement`, nessuna estensione dello scheduling automatico ad app chiusa (deliberatamente fuori scope, vedi `Docs/superpowers/specs/2026-08-09-menu-bar-shortcut-design.md`).
- **Badge percentuale sul Dock (roadmap #15, 2026-08-09)** — `MenuBarIcon` osserva `runner.stats.percent`/`runner.isRunning` (`.onChange`) e imposta `NSApp.dockTile.badgeLabel = "\(percent)%"` mentre un job è in corso, `nil` altrimenti — stessa fonte dati (`BackupRunner.stats.percent`) già usata dalla progress bar della finestra principale, nessuna nuova proprietà pubblicata. Vedi `Docs/superpowers/specs/2026-08-09-dock-badge-design.md`.
```

- [ ] **Step 2: Aggiornare la voce #15 in `Docs/ROADMAP.md`**

Trova la riga:

```
15. **Nessun indicatore di progresso in dock/menu bar** — nessun modo di vedere la percentuale senza portare la finestra in primo piano.
```

Sostituiscila con:

```
15. ✅ **Fatto (2026-08-09) — Nessun indicatore di progresso in dock/menu bar.** Badge percentuale sull'icona Dock (`NSApp.dockTile.badgeLabel`) durante un job, aggiornato da `runner.stats.percent` già esistente, sparisce subito a fine job. Solo Dock, non menu bar (deciso in brainstorming per tenere l'intervento piccolo). Vedi `Docs/superpowers/specs/2026-08-09-dock-badge-design.md`.
```

- [ ] **Step 3: Aggiornare la riga riassuntiva "Fatti:" in fondo alla sezione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "Fatti: #1 restore" Docs/ROADMAP.md`

Nella riga trovata, dopo `, #14 String Catalog.` aggiungi `, #15 badge Dock.` (mantenendo il punto finale della frase originale spostato in fondo, stesso stile della lista esistente). Aggiornare anche la clausola successiva che elenca i punti "valore aggiunto" rimanenti (attualmente `15-20`) togliendo `15`: deve diventare `16-20`.

- [ ] **Step 4: Verificare che non ci siano altre righe riassuntive disallineate**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "valore aggiunto\|15-20\|16-20" Docs/ROADMAP.md`

Controllare ogni riga risultante: se menziona ancora #15 come punto aperto (non fatto), correggerla con lo stesso criterio del passo 3. Non lasciare nessuna riga che contraddica la voce ✅ del passo 2 — questa verifica incrociata ha già trovato due incoerenze residue nella sessione precedente (#14), da non ripetere qui.

- [ ] **Step 5: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: Dock progress badge (#15) shipped"
```
