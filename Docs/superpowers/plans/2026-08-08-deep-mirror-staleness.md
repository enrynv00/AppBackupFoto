# Alert deep mirror stantio (SSD → HDD) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere un `ReviewFinding` nel pannello Revisione (Tools) che segnala quando il deep mirror SSD→HDD non gira da più di 45 giorni.

**Architecture:** Nuovo metodo `ReviewEngine.checkDeepMirrorFreshness(hddConfigured:defaults:now:)` che legge `UserDefaults["lastDeepMirrorDate"]` (stessa chiave già scritta da `BackupRunner.runSSDToHDD()`) e produce un `ReviewFinding?` opzionale. `runConfigChecks()` lo include nell'array restituito, passando `bm.urls[.hdd] != nil` come `hddConfigured`. Nessuna nuova UI: `ReviewFinding` è già renderizzato dal codice esistente in `ToolsSheet`.

**Tech Stack:** Swift 5.x, SwiftUI, XCTest, `UserDefaults(suiteName:)` per isolamento test (pattern già usato in `JobHistoryStoreTests`).

## Global Constraints

- Zero delete, zero overwrite, read-only sulla sorgente — questa feature è di sola lettura su UserDefaults, non tocca `FileSyncer`/`S3Syncer`/`RestoreEngine`, quindi non introduce rischio su questa regola, ma va rispettata se emergono modifiche collaterali.
- File principale unico: tutto il codice app va in `AppBackupFoto/ContentView.swift` (convenzione esplicita del progetto).
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Soglia: > 45 giorni da `lastDeepMirrorDate` → `ok: false`. Chiave mai presente in UserDefaults → `ok: false` con dettaglio "Mai eseguito" (non un conteggio giorni enorme).
- Se HDD non configurato (`hddConfigured == false`) → nessun finding (`nil`), coerente con `checkBookmarkRoots()`.
- Deviazione dallo pseudocodice dello spec (`Docs/superpowers/specs/2026-08-08-deep-mirror-staleness-design.md`): il metodo prende `hddConfigured: Bool` come parametro invece di leggere direttamente `bm.urls[.hdd]` al proprio interno, e non è dichiarato `private` — necessario per renderlo chiamabile e testabile in isolamento dai test XCTest senza dipendere dallo stato reale del singleton `BookmarkManager.shared` (che nel processo di test non ha bookmark HDD configurati). Comportamento a runtime identico a quanto descritto nello spec.

---

### Task 1: `checkDeepMirrorFreshness` in ReviewEngine, cablato in `runConfigChecks()`, con test

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (metodo `checkS3Endpoint` termina a riga 1795; `runConfigChecks()` alle righe 1747-1749 — i numeri di riga sono indicativi, il contenuto esatto da cercare è mostrato sotto)
- Create: `AppBackupFotoTests/ReviewEngineDeepMirrorFreshnessTests.swift`

**Interfaces:**
- Consumes: `ReviewFinding` (struct esistente, `ContentView.swift:1596-1601`: `let id: UUID`, `let title: String`, `let ok: Bool`, `let detail: String`)
- Produces: `ReviewEngine.checkDeepMirrorFreshness(hddConfigured: Bool, defaults: UserDefaults = .standard, now: Date = Date()) -> ReviewFinding?` — usato da `runConfigChecks()` nello stesso task, nessun altro consumer previsto

- [ ] **Step 1: Scrivere il test file con i 4 casi (fallirà: il metodo non esiste ancora)**

Crea `AppBackupFotoTests/ReviewEngineDeepMirrorFreshnessTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class ReviewEngineDeepMirrorFreshnessTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ReviewEngineDeepMirrorFreshnessTests"
    private let now = Date(timeIntervalSince1970: 1_754_000_000) // fisso, riproducibile

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    func testHDDNotConfigured_returnsNilRegardlessOfDate() {
        let finding = ReviewEngine().checkDeepMirrorFreshness(
            hddConfigured: false, defaults: defaults, now: now)
        XCTAssertNil(finding)
    }

    func testNeverRun_isNotOkWithMaiEseguitoDetail() {
        let finding = ReviewEngine().checkDeepMirrorFreshness(
            hddConfigured: true, defaults: defaults, now: now)
        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.ok, false)
        XCTAssertTrue(finding!.detail.contains("Mai eseguito"))
    }

    func testTenDaysAgo_isOk() {
        let tenDaysAgo = now.addingTimeInterval(-10 * 86400)
        defaults.set(tenDaysAgo, forKey: "lastDeepMirrorDate")

        let finding = ReviewEngine().checkDeepMirrorFreshness(
            hddConfigured: true, defaults: defaults, now: now)

        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.ok, true)
        XCTAssertTrue(finding!.detail.contains("10 giorni fa"))
    }

    func testFiftyDaysAgo_isNotOkWithDayCountInDetail() {
        let fiftyDaysAgo = now.addingTimeInterval(-50 * 86400)
        defaults.set(fiftyDaysAgo, forKey: "lastDeepMirrorDate")

        let finding = ReviewEngine().checkDeepMirrorFreshness(
            hddConfigured: true, defaults: defaults, now: now)

        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.ok, false)
        XCTAssertTrue(finding!.detail.contains("50 giorni fa"))
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano in compilazione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: errore di compilazione tipo `value of type 'ReviewEngine' has no member 'checkDeepMirrorFreshness'`.

- [ ] **Step 3: Implementare `checkDeepMirrorFreshness` in `ReviewEngine`**

In `AppBackupFoto/ContentView.swift`, trova il metodo `checkS3Endpoint()`:

```swift
    private func checkS3Endpoint() -> ReviewFinding {
        do {
            let cfg = try S3Syncer.readConfig()
            return ReviewFinding(title: "Endpoint S3", ok: true, detail: "\(cfg.endpoint) · bucket \(cfg.bucket)")
        } catch {
            return ReviewFinding(title: "Endpoint S3", ok: false, detail: error.localizedDescription)
        }
    }
}
```

Sostituiscilo con (nuovo metodo aggiunto subito dopo, prima della graffa di chiusura della classe):

```swift
    private func checkS3Endpoint() -> ReviewFinding {
        do {
            let cfg = try S3Syncer.readConfig()
            return ReviewFinding(title: "Endpoint S3", ok: true, detail: "\(cfg.endpoint) · bucket \(cfg.bucket)")
        } catch {
            return ReviewFinding(title: "Endpoint S3", ok: false, detail: error.localizedDescription)
        }
    }

    func checkDeepMirrorFreshness(hddConfigured: Bool,
                                   defaults: UserDefaults = .standard,
                                   now: Date = Date()) -> ReviewFinding? {
        guard hddConfigured else { return nil }
        guard let lastDeep = defaults.object(forKey: "lastDeepMirrorDate") as? Date else {
            return ReviewFinding(title: "Deep mirror SSD → HDD", ok: false,
                detail: "Mai eseguito — collega l'HDD ed esegui SSD → HDD per avviarlo")
        }
        let days = Int(now.timeIntervalSince(lastDeep) / 86400)
        if days > 45 {
            return ReviewFinding(title: "Deep mirror SSD → HDD", ok: false,
                detail: "Ultimo deep mirror \(days) giorni fa — collega l'HDD per farlo ripartire")
        }
        return ReviewFinding(title: "Deep mirror SSD → HDD", ok: true,
            detail: "Ultimo deep mirror \(days) giorni fa")
    }
}
```

- [ ] **Step 4: Cablare il nuovo finding in `runConfigChecks()`**

Trova:

```swift
    func runConfigChecks() -> [ReviewFinding] {
        checkBookmarkRoots() + [checkRcloneConfPermissions(), checkS3Endpoint()]
    }
```

Sostituisci con:

```swift
    func runConfigChecks() -> [ReviewFinding] {
        let deepMirrorFinding = checkDeepMirrorFreshness(hddConfigured: bm.urls[.hdd] != nil)
        return checkBookmarkRoots() + [checkRcloneConfPermissions(), checkS3Endpoint()]
            + [deepMirrorFinding].compactMap { $0 }
    }
```

- [ ] **Step 5: Eseguire i test e verificare che passino tutti**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: `TEST SUCCEEDED`, tutti i test passano inclusi i 4 nuovi (totale 49: i 45 esistenti + i 4 nuovi di questo task).

- [ ] **Step 6: Build completa per sicurezza**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ReviewEngineDeepMirrorFreshnessTests.swift
git commit -m "$(cat <<'EOF'
Add deep mirror staleness check to Revisione panel

ReviewEngine.checkDeepMirrorFreshness flags when SSD->HDD deep mirror
hasn't run in >45 days, or never ran. Skipped when HDD isn't configured.
EOF
)"
```

---

### Task 2: Aggiornare la documentazione del progetto

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

**Interfaces:**
- Consumes: nessuna (solo modifiche testuali)
- Produces: nessuna

- [ ] **Step 1: Aggiornare `Docs/CLAUDE.md`**

Nella sezione `### ReviewEngine (pannello "Revisione", in `ToolsSheet`)`, dopo la riga che descrive `runConfigChecks()`, aggiungi:

```
- `checkDeepMirrorFreshness(hddConfigured:defaults:now:)` — nuovo finding (2026-08-08) che segnala se il deep mirror SSD→HDD non gira da più di 45 giorni, o non è mai girato (`lastDeepMirrorDate` assente). Nessun finding se l'HDD non è configurato. Solo passivo: visibile aprendo Tools → Revisione, nessuna notifica di sistema.
```

Nella sezione `## Obiettivi futuri (non ancora iniziati)`, rimuovi il punto 1 esistente ("Valutare se serve un meccanismo di notifica/alert se il deep mirror SSD→HDD non gira da troppo tempo...") dato che è stato implementato. Se la sezione resta senza altri punti, sostituiscila con: `Nessun obiettivo futuro aperto al momento.`

- [ ] **Step 2: Aggiornare `Docs/ROADMAP.md`**

Nella sezione `## Stato aggiornato (2026-08-02)`, sostituisci la riga:

```
**Ancora aperto, con bozza di ricerca pronta in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`**: #7 scheduling.
```

con:

```
**Ancora aperto, con bozza di ricerca pronta in `Docs/superpowers/specs/2026-07-30-next-steps-briefing.md`**: #7 scheduling (nota: già parzialmente fatto per Mac→SSD, vedi sotto).

**Fatto (2026-08-08)**: alert deep mirror stantio (obiettivo futuro #1 di `Docs/CLAUDE.md`) — nuovo finding in Revisione se il deep mirror SSD→HDD non gira da più di 45 giorni. Vedi `Docs/superpowers/specs/2026-08-08-deep-mirror-staleness-design.md`.
```

(Nota: la riga su `#7 scheduling` era già obsoleta prima di questo task — lo scheduling Mac→SSD risulta "Fatto" più sotto nello stesso file. Correggerla qui è collaterale a questo task ma va fatta per non lasciare il documento contraddittorio; se preferisci lasciarla invariata, salta questa correzione e modifica solo aggiungendo la riga "Fatto (2026-08-08)".)

- [ ] **Step 3: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: deep mirror staleness alert shipped"
```
