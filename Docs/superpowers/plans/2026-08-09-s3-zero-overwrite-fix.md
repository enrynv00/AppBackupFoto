# BUG-3 Fix: S3Syncer non deve sovrascrivere file cambiati Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `S3Syncer.sync()` non deve più ricaricare (sovrascrivendo) su Cubbit una key già presente la cui dimensione locale è cambiata — deve skippare sempre, come già fa `FileSyncer` per Mac→SSD/SSD→HDD.

**Architecture:** Estrarre la decisione "questa key va caricata?" in una funzione pura e testabile `S3Syncer.shouldUpload(key:existingKeys:)`, usata da `sync()` al posto del confronto per dimensione attuale.

**Tech Stack:** Swift 5.x, XCTest.

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift`.
- Zero delete, zero overwrite, read-only sulla sorgente — questo è precisamente il bug da correggere: nessuna regressione ammessa su questa regola.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Nessuna modifica a `previewUpload` (già corretto, mostra solo stime informative, non scrive nulla).
- `result.skipped = files.count - toUpload.count` resta invariato — conta correttamente sia le key identiche sia quelle cambiate, ora entrambe skippate.

---

### Task 1: `S3Syncer.shouldUpload` e fix di `sync()`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo metodo statico in `final class S3Syncer`, e fix della riga 920 dentro `func sync(from localURL:config:...)` — righe indicative, verificare nel file reale col contenuto esatto mostrato sotto)
- Create: `AppBackupFotoTests/S3SyncerShouldUploadTests.swift`

**Interfaces:**
- Consumes: nessuna dipendenza da altri task
- Produces: `S3Syncer.shouldUpload(key: String, existingKeys: Set<String>) -> Bool` — usato da `sync()` nello stesso task, nessun altro consumer previsto in questo piano

- [ ] **Step 1: Scrivere il test file che dimostra il bug attuale (fallirà: il metodo non esiste ancora)**

Crea `AppBackupFotoTests/S3SyncerShouldUploadTests.swift`:

```swift
//
//  S3SyncerShouldUploadTests.swift
//  AppBackupFotoTests
//
//  Regressione per BUG-3: S3Syncer.sync() ricaricava (sovrascrivendo) le key già
//  presenti su S3 con dimensione locale diversa, violando zero-overwrite sulla
//  copia offsite Cubbit. shouldUpload deve rispondere "no" per qualunque key già
//  presente, indipendentemente dalla dimensione.
//

import XCTest
@testable import AppBackupFoto

final class S3SyncerShouldUploadTests: XCTestCase {

    func testNewKey_notInExisting_shouldUpload() {
        let existingKeys: Set<String> = ["Foto iPhone/2024/a.jpg"]
        XCTAssertTrue(S3Syncer.shouldUpload(key: "Foto iPhone/2024/new.jpg", existingKeys: existingKeys))
    }

    func testExistingKey_evenWithDifferentLocalSize_shouldNotUpload() {
        // Il punto centrale del fix: la dimensione locale NON deve più influenzare
        // questa decisione. Una key già presente su S3 va sempre skippata, anche se
        // il file locale è cambiato — mai sovrascrivere.
        let existingKeys: Set<String> = ["Foto iPhone/2024/a.jpg"]
        XCTAssertFalse(S3Syncer.shouldUpload(key: "Foto iPhone/2024/a.jpg", existingKeys: existingKeys))
    }

    func testEmptyExistingKeys_anyKeyShouldUpload() {
        XCTAssertTrue(S3Syncer.shouldUpload(key: "any.jpg", existingKeys: []))
    }
}
```

- [ ] **Step 2: Eseguire i test e verificare che falliscano in compilazione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: errore di compilazione tipo `type 'S3Syncer' has no member 'shouldUpload'`. Se il file di test non compare nei risultati (il target `AppBackupFotoTests` a volte non raccoglie automaticamente i nuovi file — problema già incontrato e risolto in sessioni precedenti su questo stesso progetto), aggiungilo manualmente a `project.pbxproj` (entry `PBXFileReference`/`PBXBuildFile`, riferimento nel gruppo, entry nella Sources build phase del target test).

- [ ] **Step 3: Implementare `shouldUpload` e correggere `sync()`**

Trova (in `final class S3Syncer`, dentro `func sync(from localURL: URL, config: S3Config, ...)`):

```swift
        let toUpload = files.filter { existing[$0.key] != $0.size }
        result.total = files.count
        result.toUploadCount = toUpload.count
        result.skipped = files.count - toUpload.count
```

Sostituisci con:

```swift
        let existingKeys = Set(existing.keys)
        let toUpload = files.filter { S3Syncer.shouldUpload(key: $0.key, existingKeys: existingKeys) }
        result.total = files.count
        result.toUploadCount = toUpload.count
        result.skipped = files.count - toUpload.count
```

Poi aggiungi il nuovo metodo statico da qualche parte dentro `final class S3Syncer` (per esempio subito dopo la dichiarazione della classe o vicino ad altri metodi statici come `readConfig`/`validateEndpoint` — nessun vincolo di posizione esatta, deve solo essere dentro `S3Syncer`):

```swift
    // BUG-3: una key già presente su S3 non va mai ricaricata, indipendentemente
    // dalla dimensione locale — ricaricare sovrascriverebbe l'oggetto esistente via
    // PUT, violando zero-overwrite. Solo le key davvero assenti vengono caricate.
    static func shouldUpload(key: String, existingKeys: Set<String>) -> Bool {
        !existingKeys.contains(key)
    }
```

- [ ] **Step 4: Eseguire i test e verificare che passino tutti**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -30`

Expected: `TEST SUCCEEDED`, tutti i test passano inclusi i 3 nuovi di questo task (totale 69: i 66 esistenti + 3 nuovi).

- [ ] **Step 5: Build completa per sicurezza**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/S3SyncerShouldUploadTests.swift
git commit -m "$(cat <<'EOF'
Fix BUG-3: S3Syncer no longer overwrites S3 keys that already exist

sync() picked files to upload with `existing[key] != size`, which
included keys already present on S3 with a different local size —
those got re-uploaded via a plain PUT with no existence check,
silently overwriting the object. Extracted the decision into
S3Syncer.shouldUpload(key:existingKeys:), which now only uploads keys
absent from S3, matching FileSyncer's already-correct zero-overwrite
behavior for Mac->SSD/SSD->HDD (skip always if the destination exists,
regardless of whether the content differs).
EOF
)"
```

---

### Task 2: Documentare BUG-3 in `Docs/CLAUDE.md`

**Files:**
- Modify: `Docs/CLAUDE.md`

**Interfaces:**
- Consumes: nessuna (solo modifiche testuali)
- Produces: nessuna

- [ ] **Step 1: Aggiungere BUG-3 alla sezione "Bug aperti", trovato e risolto nella stessa sessione**

Trova (sezione `## Bug aperti`):

```
## Bug aperti

**BUG-2 (2026-08-08, risolto 2026-08-09) — Aprire Diagnostica poteva bloccare/uccidere l'app; poi, dopo il primo fix, il Keychain veniva richiesto ripetutamente.**
```

Sostituisci con:

```
## Bug aperti

**BUG-3 (2026-08-09, trovato e risolto nella stessa sessione) — S3Syncer sovrascriveva silenziosamente su Cubbit i file cambiati.**

Trovato leggendo il codice durante il brainstorming di roadmap #13 (versioning), non durante un incidente reale segnalato dall'utente. `S3Syncer.sync()` decideva cosa caricare con `existing[key] != size` — includeva sia le key nuove sia le key già presenti su S3 con dimensione locale diversa, e queste ultime venivano ricaricate via `PUT` senza nessun controllo di esistenza, sovrascrivendo l'oggetto già presente. Contraddiceva sia la regola assoluta del progetto sia quanto documentato per `S3Syncer` ("mai DELETE/overwrite remoto") — e si comportava diversamente da `FileSyncer` (Mac→SSD, SSD→HDD), che per lo stesso scenario salta sempre. Fix: nuova `S3Syncer.shouldUpload(key:existingKeys:)`, la dimensione locale non influenza più quali key vengono caricate — solo le key assenti da S3 vengono caricate, esattamente come il comportamento già corretto di `FileSyncer`. Vedi `Docs/superpowers/specs/2026-08-09-s3-zero-overwrite-fix-design.md`. Nessuna verifica retroattiva possibile su oggetti eventualmente già sovrascritti in passato (bucket senza versioning S3 nativo).

**BUG-2 (2026-08-08, risolto 2026-08-09) — Aprire Diagnostica poteva bloccare/uccidere l'app; poi, dopo il primo fix, il Keychain veniva richiesto ripetutamente.**
```

- [ ] **Step 2: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/CLAUDE.md
git commit -m "Document BUG-3: S3Syncer overwrite fix in Bug aperti"
```

---

## Self-Review (già eseguita in fase di scrittura del piano)

**Copertura spec:** il fix (estrazione `shouldUpload`, sostituzione del filtro in `sync()`) e i test (key nuova → true, key esistente indipendentemente dalla dimensione → false, set vuoto → true) sono coperti da Task 1, codice identico allo spec. Nessuna modifica a `previewUpload` — rispettato. Documentazione del bug in `Docs/CLAUDE.md` → Task 2, come richiesto esplicitamente dato che è un bug critico di sicurezza dati.

**Scan placeholder:** nessuno — ogni step di codice ha contenuto completo, comandi e output attesi.

**Coerenza dei tipi:** `S3Syncer.shouldUpload(key: String, existingKeys: Set<String>) -> Bool` definito e usato identicamente nel test (Step 1) e nell'implementazione (Step 3) dello stesso Task 1.
