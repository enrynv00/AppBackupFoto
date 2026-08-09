# Roadmap #16: Notifica di errore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inviare una notifica di sistema quando un job di backup (Mac→SSD, SSD→HDD o SSD→S3) fallisce per un errore reale, così l'utente lo scopre senza dover riaprire l'app — oggi nessuna notifica viene inviata in caso di errore, solo in caso di successo.

**Architecture:** Un'unica chiamata `Notifier.send(...)` aggiunta nel ramo `catch` di `BackupRunner.run(label:work:)` (`ContentView.swift`), condiviso da tutti e tre i job. La guard esistente `guard !self.wasStopped else { return }` esclude già lo stop manuale — nessuna modifica a `stop()` necessaria.

**Tech Stack:** `UserNotifications` (`UNUserNotificationCenter`, già in uso per la notifica di successo esistente).

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift`.
- Nessuna modifica a `Notifier` (`requestAuthorization()`/`send()` invariati), a `stop()`, o ai tre metodi `runMacToSSD()`/`runSSDToHDD()`/`runSyncS3()`.
- Nessun bottone "Riprova", nessuna `UNNotificationCategory`, nessun `UNUserNotificationCenterDelegate` — fuori scope, deciso esplicitamente in brainstorming.
- La notifica NON deve scattare su stop manuale — già garantito dalla guard `!self.wasStopped` esistente riga 1862, da non toccare.
- Build (`xcodebuild ... build`) verde prima del commit. Nessun XCTest per questo task (chiamata a `UNUserNotificationCenter`, non logica pura) — verifica manuale richiesta, descritta nel task.
- Baseline nota: 75 test XCTest verdi (invariati da questo task).
- Comando build: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
- Comando test: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`

---

### Task 1: Notifica di errore nel ramo `catch` di `run()`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1858-1871` (verificare nel file reale che il contenuto corrisponda esattamente a quello mostrato sotto prima di modificare — se non corrisponde, fermarsi e segnalarlo invece di procedere alla cieca)

**Interfaces:**
- Consumes: `Notifier.send(_ title: String, _ body: String)` (già esistente, `ContentView.swift:238-242`), `self.phase.label: String` (già esistente, `JobPhase.label`, `ContentView.swift:287-292`)
- Produces: nessuna nuova interfaccia per altri task — modifica isolata, unico task di codice del piano

- [ ] **Step 1: Leggere il blocco attuale**

Contenuto attuale di `ContentView.swift:1858-1871`:

```swift
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    guard !self.wasStopped else { return }
                    self.stats.elapsed = self.makeElapsed()
                    self.phase = .failed("Errore: \(error.localizedDescription)")
                    self.completionSnapshot = (self.phase, self.stats)
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: false,
                        changedSkipped: self.stats.changedSkipped))
                }
            }
```

- [ ] **Step 2: Aggiungere la chiamata a `Notifier.send` subito dopo `self.phase = .failed(...)`**

Sostituire il blocco con:

```swift
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.elapsedTimer?.cancel(); self.elapsedTimer = nil
                    guard !self.wasStopped else { return }
                    self.stats.elapsed = self.makeElapsed()
                    self.phase = .failed("Errore: \(error.localizedDescription)")
                    Notifier.send(self.phase.label,
                        "Copiati \(self.stats.copied) · Skippati \(self.stats.skipped) · Errori \(self.stats.errors)")
                    self.completionSnapshot = (self.phase, self.stats)
                    JobHistoryStore.save(JobSummary(date: Date(), label: label, copied: self.stats.copied,
                        skipped: self.stats.skipped, errors: self.stats.errors,
                        hashErrors: self.stats.hashErrors, succeeded: false,
                        changedSkipped: self.stats.changedSkipped))
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
git commit -m "Send notification on job failure (roadmap #16)"
```

- [ ] **Step 6: Annotare la verifica manuale ancora da fare**

Non automatizzabile in ambiente headless (serve un fallimento reale, es. scollegare l'SSD a metà copia). Aggiungerla come nota nel report finale del task: avviare un job reale e farlo fallire, controllare che arrivi la notifica con titolo "Errore: ..." e corpo con i contatori parziali; separatamente, avviare un job e interromperlo manualmente (bottone Interrompi) e controllare che **non** arrivi nessuna notifica.

---

### Task 2: Aggiornamento documentazione (`Docs/CLAUDE.md`, `Docs/ROADMAP.md`)

**Files:**
- Modify: `Docs/CLAUDE.md` (sezione `BackupRunner` in "Architettura Swift" — verificare col grep sotto il punto esatto dove aggiungere la frase)
- Modify: `Docs/ROADMAP.md` (voce #16 nella sezione "Valore aggiunto", e le righe riassuntive)

**Interfaces:**
- Consumes: risultato di Task 1 (notifica implementata, build/test verdi)
- Produces: nessuna interfaccia di codice — solo documentazione, letta dalle sessioni future su questo progetto

- [ ] **Step 1: Trovare il punto esatto in `Docs/CLAUDE.md` da estendere**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "^### BackupRunner" Docs/CLAUDE.md`

Nella sezione `### BackupRunner` (elenco puntato di comportamenti, stile "**Titolo**: descrizione"), aggiungere un nuovo punto elenco con questo contenuto, mantenendo lo stesso stile delle voci esistenti (es. la voce "Controllo spazio libero (2026-08-09)" già presente):

```
- **Notifica di errore (2026-08-09, roadmap #16)**: il ramo `catch` di `run()` ora invia una notifica di sistema (`Notifier.send`) quando un job fallisce per un errore reale (rete, I/O) — prima nessuna notifica veniva inviata in caso di errore, solo in caso di successo. Non scatta su stop manuale (`wasStopped` già escluso dalla guard esistente). Nessun bottone "Riprova": deciso esplicitamente contro in brainstorming, complessità (categoria + delegate + routing per job) sproporzionata per un'app single-user. Vedi `Docs/superpowers/specs/2026-08-09-error-notification-design.md`.
```

- [ ] **Step 2: Aggiornare la voce #16 in `Docs/ROADMAP.md`**

Trova la riga:

```
16. **Notifiche non azionabili** — un bottone "Riprova" direttamente nella notifica di errore risparmierebbe il giro app→hamburger→rilancio.
```

Sostituiscila con:

```
16. ✅ **Fatto in parte (2026-08-09) — Notifiche non azionabili.** Scoperto durante il brainstorming che non esisteva nessuna notifica di errore (solo di successo) — aggiunta quella, senza bottone "Riprova": deciso esplicitamente contro, complessità (categoria + delegate + routing per job) sproporzionata per un'app single-user usata quasi sempre con la finestra a portata di mano. Vedi `Docs/superpowers/specs/2026-08-09-error-notification-design.md`.
```

- [ ] **Step 3: Aggiornare la riga riassuntiva "Fatti:" in fondo alla sezione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "Fatti: #1 restore" Docs/ROADMAP.md`

Nella riga trovata, dopo `, #15 badge Dock.` aggiungi `, #16 notifica errore.` (stesso stile della lista esistente). Nella clausola successiva che elenca i punti "valore aggiunto" rimanenti (attualmente `16-20`), togliere `16`: deve diventare `17-20`.

- [ ] **Step 4: Controllo incrociato — verificare che nessun'altra riga di `Docs/ROADMAP.md` contraddica la voce ✅ appena scritta**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "16-20\|17-20\|#16\|valore aggiunto" Docs/ROADMAP.md`

Leggere OGNI riga risultante (non solo la prima che sembra rilevante): se una riga elenca ancora #16 come punto "che resta da fare" o cita l'intervallo `16-20` come tutto aperto, correggerla con lo stesso criterio del passo 3. Nelle due sessioni precedenti (#14, #15) questo controllo ha sempre trovato almeno una riga riassuntiva rimasta disallineata da un aggiornamento precedente — ripeterlo con attenzione reale, non come formalità, e non fermarsi alla prima riga trovata se il grep ne restituisce altre.

- [ ] **Step 5: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: error notification (#16) shipped"
```
