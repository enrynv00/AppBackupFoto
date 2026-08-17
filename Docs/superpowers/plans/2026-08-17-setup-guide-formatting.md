# Setup Guide + Disk Formatting — Implementation Plan (roadmap #28)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) o superpowers:executing-plans per implementare questo piano task-per-task. Gli step usano checkbox (`- [ ]`) per il tracking.

**Goal:** Aggiungere (1) formattazione di dischi nuovi direttamente dall'app e (2) un bottone "Correggi" sulle segnalazioni di bookmark-non-sulla-root già esistenti in Tools → Revisione. Spec: `Docs/superpowers/specs/2026-08-17-setup-guide-formatting-design.md`. Gli altri due scenari di guida (aggiungere/sostituire un dispositivo) sono già coperti dal codice esistente (`SettingsSheet`/`LocationRow`) — nessun lavoro necessario lì, vedi spec.

**Architecture:** Nuovo helper `DiskFormatter` (non `ObservableObject`, solo funzioni + un piccolo modello dati — non serve stato pubblicato a lungo termine) che shella `diskutil` via `Process` per elencare dischi esterni fisici e formattarli. Nuova view `DiskPrepView` raggiungibile da `SettingsSheet`. `ReviewFinding` guadagna un campo opzionale `fixLocation` per collegare un finding specifico a un bottone di correzione che riusa `BookmarkManager.selectAndSave(loc)`.

**Tech Stack:** `Process` + `diskutil` (CLI di sistema, nessuna API pubblica Swift per formattare dischi), `PropertyListSerialization` per il parsing di `diskutil list -plist`, SwiftUI, `ContentView.swift` (unico file).

## Global Constraints

- **Nessun task esegue realmente `diskutil eraseDisk` su un disco reale** — è un'operazione distruttiva irreversibile su hardware vero. Il codice va scritto e buildato; il primo test reale della formattazione è un passo manuale a fine piano, con Enrico presente e un disco che è ok perdere.
- `diskutil eraseDisk` va invocato **solo** su un identificativo disco che ha superato il filtro "non corrisponde a nessun bookmark SSD/HDD attualmente salvato" — questo controllo non va mai bypassato o reso opzionale.
- Tutto il codice va in `AppBackupFoto/ContentView.swift` (convenzione single-file del progetto).
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) devono restare verdi dopo ogni task.
- Nessuna modifica a `FileSyncer`/`S3Syncer`/`BackupRunner`/regole zero-delete-zero-overwrite.

---

## Task 1: `DiskFormatter` — elenco dischi candidabili

**Files:**
- Modify: `AppBackupFoto/ContentView.swift`

**Interfaces:**
- Consumes: `BookmarkManager.shared.urls` (path bookmark SSD/HDD già risolti).
- Produces: `DiskFormatter.listEligibleDisks() throws -> [CandidateDisk]` (`CandidateDisk`: `identifier`, `name`, `sizeBytes`, `currentFilesystem`) — consumato dal Task 2.

- [ ] **Step 1: Aggiungere il modello `CandidateDisk`** e l'enum `DiskFormatter`:

```swift
struct CandidateDisk: Identifiable {
    var id: String { identifier }
    let identifier: String        // es. "disk4"
    let name: String
    let sizeBytes: Int64
    let currentFilesystem: String
}

enum DiskFormatter {
    static func listEligibleDisks() throws -> [CandidateDisk] {
        // 1. `diskutil list -plist external physical` via Process, parse con PropertyListSerialization
        // 2. per ogni disco, escludere quelli il cui path montato corrisponde (o è genitore/figlio)
        //    del path risolto di BookmarkManager.shared.urls[.ssd] o [.hdd]
        // 3. ritornare gli altri come CandidateDisk
    }
}
```

Nota per l'Implementer: la struttura esatta del plist di `diskutil list -plist` va verificata empiricamente durante l'esecuzione (`diskutil list -plist external physical | plutil -p -` da terminale per ispezionarla) — non assumere la struttura senza averla vista almeno una volta contro un disco reale collegato.

- [ ] **Step 2: Test unitario sulla logica di esclusione** (funzione pura separata, es. `DiskFormatter.isEligible(diskPath:configuredPaths:) -> Bool`, testabile senza eseguire realmente `diskutil` — inietta path finti). Nuovo file di test, ricordarsi di aggiungerlo a mano a `project.pbxproj` (il target test non è file-system-synchronized).

- [ ] **Step 3: Build + test**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```

Expected: build verde, nuovo test verde, conteggio totale aumentato del previsto (verificare il numero esatto).

- [ ] **Step 4: Commit**

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/ AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add DiskFormatter: list eligible external disks, exclude configured ones (roadmap #28)"
```

---

## Task 2: UI di formattazione — `DiskPrepView`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift`

**Interfaces:**
- Consumes: `DiskFormatter.listEligibleDisks()` dal Task 1.
- Produces: nessuna nuova interfaccia — task terminale lato formattazione.

- [ ] **Step 1: Aggiungere `DiskFormatter.erase(identifier:filesystem:newName:) throws`**:

```swift
enum DiskFilesystem: String, CaseIterable, Identifiable {
    case apfs = "APFS", exfat = "ExFAT"
    var id: String { rawValue }
}

extension DiskFormatter {
    static func erase(identifier: String, filesystem: DiskFilesystem, newName: String) throws {
        // Process: /usr/sbin/diskutil eraseDisk <filesystem.rawValue> <newName> <identifier>
        // Propaga stdout/stderr in caso di errore invece di fallire in silenzio.
    }
}
```

- [ ] **Step 2: Aggiungere `DiskPrepView`** — flusso in 3 passi dentro la stessa view (`@State private var step`): (1) elenco `CandidateDisk` da `listEligibleDisks()` con bottone "Aggiorna" (i dischi possono essere collegati dopo l'apertura), (2) scelta filesystem (`Picker` su `DiskFilesystem.allCases`, `.apfs` preselezionato) + campo di testo dove l'utente deve digitare esattamente il nome del disco mostrato per abilitare il bottone "Formatta" (confronto stringa esatta, case-sensitive), (3) esito (successo/errore) con messaggio "Ora vai in Impostazioni e seleziona questo disco come SSD o HDD" in caso di successo — nessun collegamento automatico alla selezione, rimanda al meccanismo esistente (`LocationRow`).

- [ ] **Step 3: Aggiungere voce "Prepara un disco nuovo…"** in `SettingsSheet`, sotto le `LocationRow` esistenti, che apre `DiskPrepView` in uno `.sheet`.

- [ ] **Step 4: Build**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add DiskPrepView: guided disk formatting from Settings (roadmap #28)"
```

---

## Task 3: Bottone "Correggi" sulle segnalazioni Revisione

**Files:**
- Modify: `AppBackupFoto/ContentView.swift`

**Interfaces:**
- Consumes: `ReviewFinding` esistente, `BookmarkManager.selectAndSave(loc)` esistente.
- Produces: nessuna nuova interfaccia — task terminale lato UI Revisione.

- [ ] **Step 1: Aggiungere un campo opzionale a `ReviewFinding`** (`ContentView.swift:2326`):

```swift
struct ReviewFinding: Identifiable {
    let id = UUID()
    let title: String
    let ok: Bool
    let detail: String
    var fixLocation: BookmarkManager.Location? = nil   // nuovo, default nil per non toccare gli altri call site
}
```

- [ ] **Step 2: Popolare `fixLocation`** in `checkBookmarkRoots()` (`ContentView.swift:2520` circa) — passare `.ssd`/`.hdd` rispettivamente per ciascun finding generato lì, lasciando `nil` (default) per tutti gli altri check (`checkRcloneConfPermissions`, `checkS3Endpoint`, `checkDeepMirrorFreshness`) — nessuna correzione automatica sicura per quelli, restano solo informativi come oggi.

- [ ] **Step 3: Aggiungere il bottone nella riga di `ForEach(runner.toolsReviewFindings)`** in `ToolsSheet` (`ContentView.swift:4082` circa):

```swift
ForEach(runner.toolsReviewFindings) { finding in
    HStack(alignment: .top, spacing: AppSpacing.sm) {
        Image(systemName: finding.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(finding.ok ? AppColor.success : AppColor.warning)
            .font(.system(size: 12))
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(finding.title).font(.caption).fontWeight(.medium)
            Text(finding.detail).font(AppFont.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if !finding.ok, let loc = finding.fixLocation {
            Button("Correggi") { BookmarkManager.shared.selectAndSave(loc) { _ in } }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
```

- [ ] **Step 4: Build + test**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```

Expected: entrambi verdi, nessuna regressione (l'aggiunta di un campo opzionale con default non deve rompere niente che già costruisce `ReviewFinding`).

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add 'Correggi' button to bookmark-root review findings (roadmap #28)"
```

---

## Task 4: Doc update + verifica finale

**Files:**
- Modify: `.claude/rules/architecture.md`
- Modify: `Docs/ROADMAP.md` (controllo incrociato su tutte le righe riassuntive del capitolo #27-30, stessa lezione applicata per #14/#15/#16/#30)

**Interfaces:**
- Consumes: output dei Task 1-3.
- Produces: nessuno (task terminale).

- [ ] **Step 1: Aggiungere una voce in `.claude/rules/architecture.md`** per `DiskFormatter`/`DiskPrepView` e per il campo `fixLocation` di `ReviewFinding`, stesso stile delle voci esistenti.

- [ ] **Step 2: Build + test finali**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -5
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: entrambi verdi.

- [ ] **Step 3: Aggiornare `Docs/ROADMAP.md`** — marcare #28 fatto **solo dopo** la verifica manuale sotto, non prima. Grep di controllo incrociato:

```bash
grep -n "#28\|27-30\|4 punti" /Users/enriconannivicenzi/Desktop/AppBackupFoto/Docs/ROADMAP.md
```

- [ ] **Step 4: Commit**

```bash
git add .claude/rules/architecture.md
git commit -m "Document disk formatting + actionable review findings (roadmap #28, code complete)"
```

- [ ] **Step 5: NON eseguire questo step via agente in background — richiede Enrico presente con un disco reale che è ok perdere.**

1. Collegare un disco esterno di prova (non l'SSD/HDD di backup reali — un disco a parte, es. una chiavetta vecchia).
2. Impostazioni → "Prepara un disco nuovo" → verificare che compaia nell'elenco.
3. Scegliere APFS, digitare il nome esatto richiesto, formattare → verificare l'esito.
4. Verificare che l'SSD/HDD reali configurati **non compaiano mai** nell'elenco dei dischi candidabili (test negativo, importante quanto quello positivo).
5. In Tools → Revisione, scollegare temporaneamente il bookmark SSD puntandolo a una sottocartella (per generare artificialmente il finding "non sulla root"), verificare che compaia il bottone "Correggi" e che cliccarlo apra davvero il selettore cartella.

**Solo dopo che questi 5 punti sono stati verificati con successo**, marcare #28 come fatto in `Docs/ROADMAP.md`.
