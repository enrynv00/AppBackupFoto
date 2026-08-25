# Indice di contenuto della libreria — nucleo (roadmap #31) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Costruire un indice SHA256 persistente dei file foto/video dell'SSD e usarlo per non ricopiare, durante un import, file il cui contenuto è già presente nella libreria.

**Architecture:** Quattro componenti separati per responsabilità, testabili in isolamento. `IndexableKind` classifica un file (immagine / video / non indicizzabile) per `UTType`. `LibraryIndexStore` incapsula SQLite (schema, versione, CRUD, commit a batch). `indexEntryVerdict` è logica **pura** che decide se una entry dell'indice è ancora attendibile (regola anti-racy, tolleranza DST). `LibraryIndexer` orchestra la scansione: attraversa, classifica, hasha, committa a batch, si ferma in modo pulito su interruzione o scollegamento. Il dedup in import entra in `FileSyncer.sync` come **predicato opzionale con default no-op**, stesso pattern già usato per `onCurrentFile` in #17 — nessuna modifica alla logica di copia esistente.

**Tech Stack:** Swift 5.x, SwiftUI, `SQLite3` di sistema (verificato: 3.51.0, `import SQLite3` senza dipendenze esterne), `UniformTypeIdentifiers` (già importato), XCTest.

**Ambito di questo piano.** Copre il **nucleo**: motore dell'indice più dedup durante l'import. Due cose previste dalla spec restano fuori di proposito, ciascuna con la propria sede:
- Il **pannello Doppioni** avrà un piano suo. Il nucleo è software funzionante e testabile senza di esso, e tenerli separati evita un piano unico troppo lungo per essere eseguito bene.
- Il **suffisso progressivo automatico** sull'etichetta di destinazione (`<etichetta> (2)`) appartiene a `ImportView`, cioè al Task 3 di `Docs/superpowers/plans/2026-08-25-device-source-import.md` (#27-A), che riprenderà dopo questo piano.

## Nota post-grilling (2026-08-25) — quattro correzioni prima di scrivere una riga

Sessione di grilling su questo piano **dopo** l'approvazione di spec e piano, prima dell'inizio del Task 1. Quattro problemi trovati leggendo il piano e il codice reale, non ipotizzati. Due erano già in codice di produzione e sono stati corretti subito; due erano nel Task 4 di questo piano e sono corretti qui sotto. **Non reintrodurli.**

**Corretti in produzione (commit `79a4c2d` e `037d028`, suite 162 → 173):**

1. **Etichetta di import con punto iniziale → cartella nascosta.** `importFolderSlug` ricadeva su `"Import"` solo per label vuote o di soli punti, quindi `.EOS_DIGITAL` creava `<SSD>/Import/.EOS_DIGITAL`. Poiché `.skipsHiddenFiles` è usato in 8 punti di `ContentView.swift` — fra cui `FileSyncer.syncDir` (la copia SSD→HDD), la sua anteprima e `listAvailableFolders` — quelle foto **non sarebbero mai state copiate su HDD né elencate**, senza un errore, e sarebbero rimaste fuori da questo indice. Era la decisione lasciata in sospeso su #27-A: chiusa rimuovendo i punti iniziali dentro la funzione pura.
2. **Lista di esclusioni in copie multiple.** Esisteva già in due copie identiche (`FileSyncer.excluded` e una locale in `ReviewEngine.scanLocalCatalog`); il Task 4 stava per aggiungere la terza, con un commento che prometteva di "non divergere". Estratta in `LibraryExclusions`, fonte unica. **Il Task 4 la usa, non la ridichiara.**

**Corretti in questo piano (Task 4):**

3. **`cancelled` non veniva mai rimesso a `false`.** Dopo una singola cancellazione — dell'utente o automatica per volume sparito — ogni `scan` successiva sulla stessa istanza sarebbe uscita subito senza fare nulla, e la rimozione dei file spariti non sarebbe più girata. Con `LibraryIndexer` come `@StateObject` della finestra (Task 6) il sintomo è "l'indice ha smesso di aggiornarsi finché non riavvio l'app". Ora `scan` riparte pulita, e `cancelled` (utente) è separato da `volumeVanished` (disco sparito) perché hanno conseguenze diverse a valle.
4. **Lo scollegamento a metà scansione poteva svuotare l'indice, proprio nel caso più frequente.** Il controllo di esistenza della root stava **dentro** il ramo `if batch.count >= batchSize`. In una scansione incrementale — quella automatica all'avvio — quasi tutti i file sono `.fresh` e fanno `continue` prima di `batch.append`: il batch non si riempie mai, quel controllo non gira mai, `cancelled` resta falso e `knownKeys - seenKeys` rimuove tutti i file non ancora visitati. Non si perdono foto (l'indice è una cache), ma si perde la ricostruzione da 5-15 minuti e **l'import successivo, senza dati di dedup, ricrea i doppioni che questa feature esiste per evitare.** Ora il controllo è una precondizione della rimozione, più una guardia di plausibilità (>50% sparito = sospetto) con la "Ricostruzione completa" come via d'uscita esplicita.

**Lezione trasversale, la stessa dei due bug precedenti del progetto** (`sha256(of:)` e BUG-5): i test possono codificare il bug invece di trovarlo. `testCancelStopsScan` sarebbe passato con `cancelled` rotto, e `testRootDisappearingMidScan_doesNotWipeIndex` testava la root assente **all'inizio**, non a metà — cioè il caso che la guardia esistente già copriva. Entrambi riscritti.

## Global Constraints

- **Zero delete, zero overwrite, read-only sulla sorgente.** Questa feature è interamente in sola lettura sul volume delle foto: non scrive, non sposta, non cancella nulla sull'SSD.
- Tutto il codice applicativo va in `AppBackupFoto/ContentView.swift` — convenzione di progetto, non creare nuovi file `.swift` per il target app.
- Build: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`
- Test: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test`
- **Il target `AppBackupFotoTests` non è file-system-synchronized**: ogni nuovo file di test va registrato a mano in `AppBackupFoto.xcodeproj/project.pbxproj` in 4 punti (`PBXBuildFile`, `PBXFileReference`, gruppo `AppBackupFotoTests`, `PBXSourcesBuildPhase`). Altrimenti compila ma non viene eseguito, e i test "passano" solo perché non girano. **Verificare sempre il conteggio totale atteso**, mai fidarsi del solo `** TEST SUCCEEDED **`.
- **Baseline all'inizio di questo piano: 173 test verdi**, ultimo commit `037d028`.
  (Era 162 su `c868cf4`. I due commit del 2026-08-25 nati dal grilling di questo piano
  hanno aggiunto 11 test: `79a4c2d` — nessuna etichetta di import puo' produrre una
  cartella nascosta, +6 — e `037d028` — `LibraryExclusions` come fonte unica, +5.)
- **L'hashing usa sempre `sha256(of:)` esistente** (`ContentView.swift:1454`), che fa I/O POSIX a basso livello. **Mai `FileHandle`**: è il bug di memoria da 41GB già pagato una volta su questo progetto.
- **L'indice è una cache, non una fonte di verità.** Nulla al suo interno è dato originale; deve essere sempre ricostruibile da zero. Nessun percorso di codice deve trattare l'assenza o la corruzione dell'indice come un errore fatale.
- L'indice vive in `~/Library/Application Support/AppBackupFoto/`, **mai sull'SSD**.
- Nessun test deve toccare SSD, HDD o dati reali: solo directory temporanee, con cleanup in `tearDown`.
- Riferimento spec: `Docs/superpowers/specs/2026-08-25-library-content-index-design.md`.

## Struttura dei file

Un solo file applicativo (`ContentView.swift`, convenzione di progetto) più quattro nuovi file di test, uno per componente:

| Componente | Responsabilità | Test |
| :---- | :---- | :---- |
| `IndexableKind` | classificare un URL: immagine / video / non indicizzabile | `IndexableKindTests.swift` |
| `LibraryIndexStore` | persistenza SQLite: schema, versione, lettura/scrittura, batch | `LibraryIndexStoreTests.swift` |
| `indexEntryVerdict` | logica pura di attendibilità di una entry | `IndexEntryVerdictTests.swift` |
| `LibraryIndexer` | orchestrazione della scansione | `LibraryIndexerTests.swift` |

---

### Task 1: `IndexableKind` — classificazione a tre vie

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (subito dopo `enum FileKind`, che oggi sta a riga ~1447 — **verifica con `grep -n "enum FileKind"` prima di editare**, i numeri di riga cambiano a ogni task)
- Create: `AppBackupFotoTests/IndexableKindTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consuma: `UTType` (da `UniformTypeIdentifiers`, già importato a riga 5).
- Produce: `enum IndexableKind { case image, video, notIndexable }` e `static func IndexableKind.of(url: URL) -> IndexableKind` — consumato dal Task 4 (`LibraryIndexer`).

- [ ] **Step 1: Scrivi il file di test**

Crea `AppBackupFotoTests/IndexableKindTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class IndexableKindTests: XCTestCase {
    private func kind(_ name: String) -> IndexableKind {
        IndexableKind.of(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testJpeg_isImage()  { XCTAssertEqual(kind("IMG_0001.jpg"), .image) }
    func testHeic_isImage()  { XCTAssertEqual(kind("IMG_0002.heic"), .image) }
    func testPng_isImage()   { XCTAssertEqual(kind("shot.png"), .image) }
    func testMov_isVideo()   { XCTAssertEqual(kind("clip.mov"), .video) }
    func testMp4_isVideo()   { XCTAssertEqual(kind("drone.mp4"), .video) }

    func testZip_isNotIndexable()  { XCTAssertEqual(kind("Takeout.zip"), .notIndexable) }
    func testJson_isNotIndexable() { XCTAssertEqual(kind("metadata.json"), .notIndexable) }
    func testXmp_isNotIndexable()  { XCTAssertEqual(kind("IMG_0001.xmp"), .notIndexable) }
    func testAae_isNotIndexable()  { XCTAssertEqual(kind("IMG_0001.aae"), .notIndexable) }
    func testNoExtension_isNotIndexable() { XCTAssertEqual(kind("README"), .notIndexable) }

    func testUppercaseExtension_isImage() {
        // Le fotocamere scrivono spesso estensioni maiuscole (DSC0001.JPG)
        XCTAssertEqual(kind("DSC0001.JPG"), .image)
    }

    func testUnknownExtension_isNotIndexable() {
        // Un formato non riconosciuto resta fuori dall'indice: sbagliare per
        // esclusione e' il verso sicuro (il file viene copiato, mai saltato).
        XCTAssertEqual(kind("foto.formatoinventato"), .notIndexable)
    }
}
```

- [ ] **Step 2: Registra il file di test in `project.pbxproj`**

Genera due ID:
```bash
FILEREF_ID=$(uuidgen | tr -d '-' | tr '[:lower:]' '[:upper:]' | cut -c1-24)
BUILDFILE_ID=$(uuidgen | tr -d '-' | tr '[:lower:]' '[:upper:]' | cut -c1-24)
echo "FILEREF_ID=$FILEREF_ID"; echo "BUILDFILE_ID=$BUILDFILE_ID"
```

Usa `grep -n "ImportSourceGuardTests" AppBackupFoto.xcodeproj/project.pbxproj` per trovare le 4 righe gemelle da cui copiare il formato esatto, e aggiungi accanto a ciascuna:

1. `PBXBuildFile`: `		<BUILDFILE_ID> /* IndexableKindTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEREF_ID> /* IndexableKindTests.swift */; };`
2. `PBXFileReference`: `		<FILEREF_ID> /* IndexableKindTests.swift */ = {isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = IndexableKindTests.swift; sourceTree = "<group>"; };`
3. Gruppo `AppBackupFotoTests`, dentro `children = ( ... )`: `				<FILEREF_ID> /* IndexableKindTests.swift */,`
4. `PBXSourcesBuildPhase` `62FE197CBAC2C2E908580583 /* Sources */`, dentro `files = ( ... )`: `				<BUILDFILE_ID> /* IndexableKindTests.swift in Sources */,`

- [ ] **Step 3: Verifica il fallimento atteso**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/IndexableKindTests 2>&1 | tail -30`
Expected: FAIL con `cannot find 'IndexableKind' in scope`. **Se invece il comando non trova affatto la classe di test, la registrazione in `project.pbxproj` non ha funzionato: fermati e segnalalo.**

- [ ] **Step 4: Implementa**

In `AppBackupFoto/ContentView.swift`, subito dopo la chiusura di `enum FileKind`:

```swift
/// Classificazione a tre vie per l'indice di contenuto (roadmap #31).
/// Sostituisce una lista di cartelle da escludere scritta a mano: la cartella "Zip"
/// resta fuori dall'indice perche' un archivio non e' ne' immagine ne' video, non
/// perche' si chiama cosi' — cosi' la regola regge anche per sorgenti future.
enum IndexableKind {
    case image
    case video
    case notIndexable

    /// Classifica per estensione via `UTType`. Limite noto e accettato: non ispeziona
    /// il contenuto, quindi un file con estensione errata/assente o un RAW di un modello
    /// non riconosciuto da macOS finisce in `.notIndexable`. Sbagliare per esclusione e'
    /// il verso sicuro: quel file non partecipa al dedup e viene copiato, mai saltato.
    static func of(url: URL) -> IndexableKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .notIndexable }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return .notIndexable
    }
}
```

- [ ] **Step 5: Verifica che i test passino**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/IndexableKindTests 2>&1 | tail -20`
Expected: `Executed 12 tests, with 0 failures`, `** TEST SUCCEEDED **`

- [ ] **Step 6: Build, suite completa, commit**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`, e **185 test** (173 + 12). Verifica il numero nel log, non solo `TEST SUCCEEDED`.

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/IndexableKindTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add IndexableKind three-way classification (roadmap #31)"
```

---

### Task 2: `indexEntryVerdict` — logica pura di attendibilità

Va prima dello store e dello scanner perché è la regola che entrambi consumano, ed è interamente pura quindi testabile senza filesystem né database.

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (subito dopo `enum IndexableKind` del Task 1)
- Create: `AppBackupFotoTests/IndexEntryVerdictTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Produce: `enum IndexEntryVerdict { case fresh, stale, needsVerification }`
- Produce: `func indexEntryVerdict(storedSize: Int64, storedMTime: Double, storedHashedAt: Double, currentSize: Int64, currentMTime: Double, racyMarginSeconds: Double = 2.0) -> IndexEntryVerdict`
- Consumato da: Task 4 (`LibraryIndexer`, aggiornamento incrementale) e Task 6 (dedup in import).

- [ ] **Step 1: Scrivi il file di test**

Crea `AppBackupFotoTests/IndexEntryVerdictTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class IndexEntryVerdictTests: XCTestCase {
    // Scenario base: file hashato molto tempo dopo l'ultima modifica.
    private let mtime: Double = 1_700_000_000
    private var hashedAt: Double { mtime + 3600 }   // ben oltre il margine racy

    private func verdict(size: Int64 = 100, mtime m: Double? = nil,
                         storedSize: Int64 = 100, storedMTime: Double? = nil,
                         hashedAt h: Double? = nil) -> IndexEntryVerdict {
        indexEntryVerdict(storedSize: storedSize,
                          storedMTime: storedMTime ?? mtime,
                          storedHashedAt: h ?? hashedAt,
                          currentSize: size,
                          currentMTime: m ?? mtime)
    }

    func testUnchanged_isFresh() {
        XCTAssertEqual(verdict(), .fresh)
    }

    func testSizeChanged_isStale() {
        XCTAssertEqual(verdict(size: 101), .stale)
    }

    func testMTimeChanged_isStale() {
        XCTAssertEqual(verdict(mtime: mtime + 42), .stale)
    }

    // Regola anti-racy (da git/borg): se il file risulta modificato entro il margine
    // rispetto a quando l'hash e' stato calcolato, non possiamo escludere che sia
    // cambiato subito dopo la lettura mantenendo lo stesso mtime.
    func testModifiedWithinRacyMarginOfHashing_needsVerification() {
        XCTAssertEqual(verdict(hashedAt: mtime + 1.0), .needsVerification)
    }

    func testModifiedExactlyAtRacyMarginBoundary_needsVerification() {
        XCTAssertEqual(verdict(hashedAt: mtime + 2.0), .needsVerification)
    }

    func testModifiedWellBeforeHashing_isFresh() {
        XCTAssertEqual(verdict(hashedAt: mtime + 2.5), .fresh)
    }

    // Tolleranza DST: uno shift esatto di un'ora (o mezz'ora, per i fusi a offset :30)
    // e' quasi certamente un cambio di fuso su ExFAT, non una modifica del file.
    // Non invalidare in blocco: riverificare.
    func testDstShiftForward_needsVerification() {
        XCTAssertEqual(verdict(mtime: mtime + 3600), .needsVerification)
    }

    func testDstShiftBackward_needsVerification() {
        XCTAssertEqual(verdict(mtime: mtime - 3600), .needsVerification)
    }

    func testHalfHourShift_needsVerification() {
        XCTAssertEqual(verdict(mtime: mtime + 1800), .needsVerification)
    }

    func testShiftWithin10msGranularityOfDst_needsVerification() {
        // ExFAT ha granularita' 10ms: uno shift DST puo' non essere esatto al microsecondo.
        XCTAssertEqual(verdict(mtime: mtime + 3600.01), .needsVerification)
    }

    func testNearlyButNotDstShift_isStale() {
        XCTAssertEqual(verdict(mtime: mtime + 3500), .stale)
    }

    // La dimensione ha la precedenza: se e' cambiata, il file e' cambiato, punto.
    // Nessuna tolleranza DST puo' salvarlo.
    func testDstShiftButSizeAlsoChanged_isStale() {
        XCTAssertEqual(verdict(size: 999, mtime: mtime + 3600), .stale)
    }
}
```

- [ ] **Step 2: Registra il file di test in `project.pbxproj`**

Stessa procedura del Task 1 Step 2, con nome `IndexEntryVerdictTests.swift` e due ID nuovi generati con `uuidgen`.

- [ ] **Step 3: Verifica il fallimento atteso**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/IndexEntryVerdictTests 2>&1 | tail -30`
Expected: FAIL con `cannot find 'indexEntryVerdict' in scope`.

- [ ] **Step 4: Implementa**

```swift
/// Esito della valutazione di attendibilita' di una entry dell'indice.
enum IndexEntryVerdict {
    /// La entry e' attendibile: l'hash memorizzato vale.
    case fresh
    /// Il file e' certamente cambiato: rihashare.
    case stale
    /// Non possiamo escludere un cambiamento: rihashare prima di fidarci in un
    /// percorso ad alto danno (skip in import); accettabile fidarsi in segnalazione.
    case needsVerification
}

/// Decide se l'hash memorizzato per un file e' ancora attendibile.
///
/// La chiave (percorso, dimensione, mtime) NON e' una garanzia: `mtime` e' riscrivibile
/// da userspace (exiftool, `rsync -t`, restore da Finder). restic e borg si irrobustiscono
/// con inode e ctime, ma su ExFAT — il filesystem dell'SSD — l'inode non e' stabile
/// (documentato da Apple DTS) e quel rinforzo non e' disponibile. Da qui le due difese:
///
/// 1. **Regola anti-racy**, presa da git e borg: se il file risulta modificato entro
///    `racyMarginSeconds` da quando ne abbiamo calcolato l'hash, non possiamo escludere
///    che sia cambiato subito dopo la lettura mantenendo lo stesso mtime.
///    Margine 2s e non 10ms: la granularita' misurata su macOS/ExFAT e' 10ms, ma la
///    spec ExFAT prevede 2 secondi e un'altra implementazione potrebbe esporli.
/// 2. **Tolleranza DST**: ExFAT memorizza i timestamp in ora locale, e uno studio forense
///    (DFRWS 2022) documenta divergenze fra implementazioni, macOS inclusa. Uno shift
///    esatto di 3600s o 1800s e' quasi certamente un cambio di fuso, non una modifica:
///    trattarlo come `stale` farebbe rihashare l'intera libreria due volte l'anno.
///    NOTA: questa seconda regola non ha prior art — e' una scelta di questo progetto.
func indexEntryVerdict(storedSize: Int64,
                       storedMTime: Double,
                       storedHashedAt: Double,
                       currentSize: Int64,
                       currentMTime: Double,
                       racyMarginSeconds: Double = 2.0) -> IndexEntryVerdict {
    // La dimensione ha sempre la precedenza: se cambia, il file e' cambiato.
    guard storedSize == currentSize else { return .stale }

    let delta = abs(currentMTime - storedMTime)
    // Tolleranza sulla granularita' ExFAT (10ms), con margine.
    let granularity = 0.05

    if delta <= granularity {
        // mtime invariato: resta solo il dubbio racy.
        return currentMTime >= storedHashedAt - racyMarginSeconds ? .needsVerification : .fresh
    }
    if abs(delta - 3600) <= granularity || abs(delta - 1800) <= granularity {
        return .needsVerification
    }
    return .stale
}
```

- [ ] **Step 5: Verifica che i test passino**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/IndexEntryVerdictTests 2>&1 | tail -20`
Expected: `Executed 12 tests, with 0 failures`

- [ ] **Step 6: Build, suite completa, commit**

Expected suite: **197 test** (185 + 12).

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/IndexEntryVerdictTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add indexEntryVerdict trust logic with racy and DST rules (roadmap #31)"
```

---

### Task 3: `LibraryIndexStore` — persistenza SQLite

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dopo `indexEntryVerdict`)
- Modify: `AppBackupFoto/ContentView.swift` riga 1-10 (aggiungere `import SQLite3`)
- Create: `AppBackupFotoTests/LibraryIndexStoreTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Produce: `struct LibraryIndexEntry { let path: String; let displayPath: String; let size: Int64; let mtime: Double; let hash: String; let hashedAt: Double }`
- Produce: `func normalizedIndexKey(_ relativePath: String) -> String`
- Produce: `final class LibraryIndexStore` con: `init(url: URL) throws`, `func upsert(_ entries: [LibraryIndexEntry]) throws`, `func entry(forKey key: String) throws -> LibraryIndexEntry?`, `func entries(withHash hash: String) throws -> [LibraryIndexEntry]`, `func hasAnyEntry(withSize size: Int64) throws -> Bool`, `func allKeys() throws -> Set<String>`, `func remove(keys: [String]) throws`, `func count() throws -> Int`, `static let schemaVersion = 1`
- Consumato da: Task 4 e Task 6.

- [ ] **Step 1: Scrivi il file di test**

Crea `AppBackupFotoTests/LibraryIndexStoreTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class LibraryIndexStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: LibraryIndexStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryIndexStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func entry(_ key: String, size: Int64 = 100, hash: String = "abc") -> LibraryIndexEntry {
        LibraryIndexEntry(path: normalizedIndexKey(key), displayPath: key,
                          size: size, mtime: 1_700_000_000, hash: hash, hashedAt: 1_700_003_600)
    }

    func testEmptyStore_hasNoEntries() throws {
        XCTAssertEqual(try store.count(), 0)
        XCTAssertNil(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg")))
    }

    func testUpsertThenRead() throws {
        try store.upsert([entry("Foto/a.jpg")])
        let got = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))
        XCTAssertEqual(got?.displayPath, "Foto/a.jpg")
        XCTAssertEqual(got?.hash, "abc")
        XCTAssertEqual(got?.size, 100)
    }

    func testUpsertSameKeyTwice_replacesInsteadOfDuplicating() throws {
        try store.upsert([entry("Foto/a.jpg", hash: "vecchio")])
        try store.upsert([entry("Foto/a.jpg", hash: "nuovo")])
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))?.hash, "nuovo")
    }

    func testEntriesWithHash_findsAllCopies() throws {
        try store.upsert([entry("Foto/a.jpg", hash: "H"),
                          entry("Import/b.jpg", hash: "H"),
                          entry("Altro/c.jpg", hash: "DIVERSO")])
        let found = try store.entries(withHash: "H")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.displayPath)), ["Foto/a.jpg", "Import/b.jpg"])
    }

    func testHasAnyEntryWithSize() throws {
        try store.upsert([entry("Foto/a.jpg", size: 500)])
        XCTAssertTrue(try store.hasAnyEntry(withSize: 500))
        XCTAssertFalse(try store.hasAnyEntry(withSize: 501))
    }

    func testRemoveKeys() throws {
        try store.upsert([entry("Foto/a.jpg"), entry("Foto/b.jpg")])
        try store.remove(keys: [normalizedIndexKey("Foto/a.jpg")])
        XCTAssertEqual(try store.count(), 1)
        XCTAssertNil(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg")))
    }

    func testAllKeys() throws {
        try store.upsert([entry("Foto/a.jpg"), entry("Foto/b.jpg")])
        XCTAssertEqual(try store.allKeys(), [normalizedIndexKey("Foto/a.jpg"),
                                             normalizedIndexKey("Foto/b.jpg")])
    }

    func testPersistsAcrossReopen() throws {
        let dbURL = tempDir.appendingPathComponent("persist.sqlite")
        let first = try LibraryIndexStore(url: dbURL)
        try first.upsert([entry("Foto/a.jpg")])
        let second = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try second.count(), 1)
    }

    func testBatchUpsertIsAtomicPerBatch() throws {
        let many = (0..<500).map { entry("Foto/f\($0).jpg", hash: "h\($0)") }
        try store.upsert(many)
        XCTAssertEqual(try store.count(), 500)
    }

    // Normalizzazione della chiave: ExFAT e' case-insensitive e non normalizza
    // l'Unicode, APFS preserva la normalizzazione originale invece di imporne una.
    // Senza normalizzazione lo stesso file produrrebbe due entry distinte.
    func testKeyNormalization_caseInsensitive() {
        XCTAssertEqual(normalizedIndexKey("Foto/IMG.JPG"), normalizedIndexKey("foto/img.jpg"))
    }

    func testKeyNormalization_unicodeNFCvsNFD() {
        let nfc = "Citt\u{00E0}/foto.jpg"        // à precomposta
        let nfd = "Citta\u{0300}/foto.jpg"       // a + accento combinante
        XCTAssertEqual(normalizedIndexKey(nfc), normalizedIndexKey(nfd))
    }

    func testKeyNormalization_preservesDistinctPaths() {
        XCTAssertNotEqual(normalizedIndexKey("Foto/a.jpg"), normalizedIndexKey("Foto/b.jpg"))
    }

    // Un indice scritto con uno schema diverso non va interpretato: si riparte.
    func testUnknownSchemaVersion_resetsIndex() throws {
        let dbURL = tempDir.appendingPathComponent("schema.sqlite")
        let first = try LibraryIndexStore(url: dbURL)
        try first.upsert([entry("Foto/a.jpg")])
        XCTAssertEqual(try first.count(), 1)

        // Simula un indice scritto da una versione futura dell'app.
        try first.setSchemaVersionForTesting(999)
        let second = try LibraryIndexStore(url: dbURL)
        XCTAssertEqual(try second.count(), 0, "schema sconosciuto: l'indice va ricostruito, non letto")
    }
}
```

- [ ] **Step 2: Registra il file di test in `project.pbxproj`**

Stessa procedura, nome `LibraryIndexStoreTests.swift`, due ID nuovi.

- [ ] **Step 3: Verifica il fallimento atteso**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/LibraryIndexStoreTests 2>&1 | tail -30`
Expected: FAIL con `cannot find 'LibraryIndexStore' in scope`.

- [ ] **Step 4: Aggiungi l'import**

In cima a `ContentView.swift`, accanto agli altri import (riga ~5, dove c'è già `import UniformTypeIdentifiers`):

```swift
import SQLite3
```

Verificato: SQLite3 di sistema è 3.51.0 e `import SQLite3` funziona da Swift senza dipendenze esterne.

- [ ] **Step 5: Implementa**

```swift
/// Una riga dell'indice di contenuto.
struct LibraryIndexEntry {
    /// Chiave normalizzata (NFC + minuscole), relativa alla root dell'SSD.
    let path: String
    /// Percorso come appare davvero su disco, per mostrarlo all'utente.
    let displayPath: String
    let size: Int64
    /// mtime LETTO DALL'SSD, mai quello della sorgente originale: la copia
    /// APFS -> ExFAT tronca a 10ms (misurato), quindi i due non coincidono mai.
    let mtime: Double
    let hash: String
    /// Istante in cui l'hash e' stato calcolato — serve alla regola anti-racy.
    let hashedAt: Double
}

/// Normalizza un percorso relativo per usarlo come chiave dell'indice.
/// ExFAT e' case-insensitive/case-preserving e non normalizza l'Unicode; APFS preserva
/// la normalizzazione originale. Senza questo passaggio lo stesso file potrebbe
/// generare due entry distinte (NFC vs NFD, o maiuscole/minuscole diverse).
func normalizedIndexKey(_ relativePath: String) -> String {
    relativePath.precomposedStringWithCanonicalMapping.lowercased()
}

/// Persistenza SQLite dell'indice. Scelta su JSON monolitico perche' un aggiornamento
/// incrementale costa O(log n) invece di riscrivere l'intero file, e perche' una
/// corruzione degrada parzialmente invece di rendere tutto illeggibile.
///
/// NOTA DI DURABILITA': su macOS `fsync()` non garantisce la persistenza fisica e la
/// SQLite di sistema puo' sostituire F_FULLFSYNC con F_BARRIERFSYNC. Conseguenza
/// peggiore: perdere l'ultima transazione in caso di power loss. Accettato — l'indice
/// e' una cache ricostruibile, mai una fonte di verita'.
final class LibraryIndexStore {
    static let schemaVersion = 1

    enum StoreError: Error, LocalizedError {
        case cannotOpen(String)
        case sqlFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let m): return "Impossibile aprire l'indice: \(m)"
            case .sqlFailed(let m):  return "Errore nell'indice: \(m)"
            }
        }
    }

    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK, db != nil else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sconosciuto"
            sqlite3_close(db)
            db = nil
            throw StoreError.cannotOpen(msg)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try createSchemaIfNeeded()
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sconosciuto"
            sqlite3_free(err)
            throw StoreError.sqlFailed(msg)
        }
    }

    private func createSchemaIfNeeded() throws {
        // Un indice scritto da una versione futura/sconosciuta dello schema non va
        // interpretato a caso: si riparte da zero. L'indice e' una cache, buttarlo
        // non perde nulla di originale.
        if let existing = try schemaVersionOnDisk(), existing != Self.schemaVersion {
            try exec("DROP TABLE IF EXISTS entries; DROP TABLE IF EXISTS meta;")
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS entries (
            path         TEXT PRIMARY KEY,
            display_path TEXT NOT NULL,
            size         INTEGER NOT NULL,
            mtime        REAL NOT NULL,
            hash         TEXT NOT NULL,
            hashed_at    REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_entries_hash ON entries(hash);
        CREATE INDEX IF NOT EXISTS idx_entries_size ON entries(size);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
        try exec("INSERT OR IGNORE INTO meta(key,value) VALUES('schema_version','\(Self.schemaVersion)');")
    }

    /// Legge la versione dello schema, o nil se il database e' nuovo/vuoto.
    private func schemaVersionOnDisk() throws -> Int? {
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='meta';", -1, &check, nil) == SQLITE_OK else { return nil }
        let hasMeta = sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        guard hasMeta else { return nil }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='schema_version';", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return Int(String(cString: text))
    }

    /// Inserisce o sostituisce entry in una sola transazione: un batch e' atomico,
    /// quindi un'interruzione lascia l'indice parziale ma coerente, mai a meta' riga.
    func upsert(_ entries: [LibraryIndexEntry]) throws {
        guard !entries.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO entries(path,display_path,size,mtime,hash,hashed_at) VALUES(?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for e in entries {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, e.path, -1, transient)
                sqlite3_bind_text(stmt, 2, e.displayPath, -1, transient)
                sqlite3_bind_int64(stmt, 3, e.size)
                sqlite3_bind_double(stmt, 4, e.mtime)
                sqlite3_bind_text(stmt, 5, e.hash, -1, transient)
                sqlite3_bind_double(stmt, 6, e.hashedAt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func readEntry(_ stmt: OpaquePointer?) -> LibraryIndexEntry {
        LibraryIndexEntry(path: String(cString: sqlite3_column_text(stmt, 0)),
                          displayPath: String(cString: sqlite3_column_text(stmt, 1)),
                          size: sqlite3_column_int64(stmt, 2),
                          mtime: sqlite3_column_double(stmt, 3),
                          hash: String(cString: sqlite3_column_text(stmt, 4)),
                          hashedAt: sqlite3_column_double(stmt, 5))
    }

    func entry(forKey key: String) throws -> LibraryIndexEntry? {
        var stmt: OpaquePointer?
        let sql = "SELECT path,display_path,size,mtime,hash,hashed_at FROM entries WHERE path=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW ? readEntry(stmt) : nil
    }

    func entries(withHash hash: String) throws -> [LibraryIndexEntry] {
        var stmt: OpaquePointer?
        let sql = "SELECT path,display_path,size,mtime,hash,hashed_at FROM entries WHERE hash=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, hash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [LibraryIndexEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(readEntry(stmt)) }
        return out
    }

    /// Filtro dimensione-prima: se nessun file indicizzato ha questa dimensione,
    /// il file in arrivo non va nemmeno hashato. E' lo stadio 1 del pipeline su cui
    /// convergono rmlint, jdupes e rdfind.
    func hasAnyEntry(withSize size: Int64) throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM entries WHERE size=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, size)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func allKeys() throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path FROM entries;", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    func remove(keys: [String]) throws {
        guard !keys.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM entries WHERE path=?;", -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for k in keys {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, k, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func count() throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries;", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Solo per i test: forza la versione dello schema per verificare il reset.
    func setSchemaVersionForTesting(_ version: Int) throws {
        try exec("INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','\(version)');")
    }
}
```

- [ ] **Step 6: Verifica che i test passino**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/LibraryIndexStoreTests 2>&1 | tail -20`
Expected: `Executed 13 tests, with 0 failures`

- [ ] **Step 7: Build, suite completa, commit**

Expected suite: **210 test** (197 + 13).

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/LibraryIndexStoreTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add LibraryIndexStore SQLite persistence (roadmap #31)"
```

---

### Task 4: `LibraryIndexer` — scansione, hashing, aggiornamento incrementale

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (dopo `LibraryIndexStore`)
- Create: `AppBackupFotoTests/LibraryIndexerTests.swift`
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consuma: `IndexableKind.of(url:)` (Task 1), `indexEntryVerdict` (Task 2), `LibraryIndexStore` (Task 3), `sha256(of:)` (esistente).
- Produce: `final class LibraryIndexer` con `struct Progress { var scanned: Int; var hashed: Int; var skipped: Int; var errors: Int; var total: Int }`, `init(store: LibraryIndexStore)`, `func scan(root: URL, batchSize: Int = 200, ignoringStoredHashes: Bool = false, onProgress: @escaping (Progress) -> Void = { _ in }) throws -> Progress`, `func cancel()`

`ignoringStoredHashes` è la modalità "verifica completa / ignora mtime" richiesta dalla spec: rihasha tutto senza fidarsi di nulla di memorizzato. Tutti e quattro i tool esaminati dalla ricerca (`rsync --checksum`, `restic --force`, `borg --files-cache=disabled`, `rmlint --xattr-clear`) ne offrono una — è un segnale forte che serva.
- Consumato da: Task 5 (UI) e Task 6 (dedup).

- [ ] **Step 1: Scrivi il file di test**

Crea `AppBackupFotoTests/LibraryIndexerTests.swift`:

```swift
import XCTest
@testable import AppBackupFoto

final class LibraryIndexerTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var store: LibraryIndexStore!
    private var indexer: LibraryIndexer!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryIndexerTests-\(UUID().uuidString)")
        root = tempDir.appendingPathComponent("SSD")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try LibraryIndexStore(url: tempDir.appendingPathComponent("index.sqlite"))
        indexer = LibraryIndexer(store: store)
    }

    override func tearDownWithError() throws {
        indexer = nil; store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeFile(_ relative: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    func testIndexesImagesAndVideos() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        try makeFile("Foto/b.mov", contents: "due")
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 2)
        XCTAssertEqual(try store.count(), 2)
    }

    func testIgnoresNonIndexableFiles() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        try makeFile("Zip/archivio.zip", contents: "grosso")
        try makeFile("Foto/a.xmp", contents: "sidecar")
        try makeFile("Takeout/meta.json", contents: "{}")
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 1, "solo a.jpg deve entrare nell'indice")
        XCTAssertEqual(try store.count(), 1)
    }

    func testSecondScanReusesStoredHashes() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        _ = try indexer.scan(root: root)
        let second = try indexer.scan(root: root)
        XCTAssertEqual(second.hashed, 0, "nulla e' cambiato: nessun rehash")
        XCTAssertEqual(second.skipped, 1)
    }

    func testChangedFileIsRehashed() throws {
        let url = try makeFile("Foto/a.jpg", contents: "uno")
        _ = try indexer.scan(root: root)
        let before = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))?.hash

        // Cambia contenuto E mtime, ben oltre il margine racy.
        try "contenuto completamente diverso".data(using: .utf8)!.write(to: url)
        let future = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)

        let second = try indexer.scan(root: root)
        XCTAssertEqual(second.hashed, 1)
        XCTAssertNotEqual(try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))?.hash, before)
    }

    func testDeletedFileIsRemovedFromIndex() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        try makeFile("Foto/b.jpg", contents: "due")
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 2)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/b.jpg"))
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 1, "le entry di file spariti vanno rimosse")
        XCTAssertNil(try store.entry(forKey: normalizedIndexKey("Foto/b.jpg")))
    }

    func testIdenticalContentProducesSameHash() throws {
        try makeFile("Foto/a.jpg", contents: "identico")
        try makeFile("Import/copia.jpg", contents: "identico")
        _ = try indexer.scan(root: root)
        let a = try store.entry(forKey: normalizedIndexKey("Foto/a.jpg"))!
        XCTAssertEqual(try store.entries(withHash: a.hash).count, 2)
    }

    func testExcludesSystemFiles() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        try makeFile("Foto/.DS_Store", contents: "junk")
        let p = try indexer.scan(root: root)
        XCTAssertEqual(p.hashed, 1)
    }

    func testProgressIsReported() throws {
        for i in 0..<5 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        var reports: [LibraryIndexer.Progress] = []
        _ = try indexer.scan(root: root, batchSize: 2) { reports.append($0) }
        XCTAssertFalse(reports.isEmpty, "il progresso deve essere riportato durante la scansione")
        XCTAssertEqual(reports.last?.hashed, 5)
    }

    // Cancellazione DURANTE la scansione: e' il flusso reale (l'utente preme
    // "Interrompi" mentre il lavoro gira). Un `cancel()` PRIMA di `scan()` non e' un
    // caso reale ed e' volutamente ignorato, perche' `scan` riparte pulita.
    func testCancelDuringScan_stopsEarly() throws {
        for i in 0..<50 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        let idx = indexer!
        let p = try idx.scan(root: root, batchSize: 5) { _ in idx.cancel() }
        XCTAssertLessThan(p.hashed, 50, "la cancellazione deve fermare la scansione")
        XCTAssertGreaterThan(try store.count(), 0, "cio' che era gia' stato committato resta")
    }

    // Il bug che questo test blocca: `cancelled` non veniva mai rimesso a false, quindi
    // dopo UNA cancellazione l'istanza non avrebbe indicizzato mai piu' nulla, e la
    // rimozione dei file spariti non sarebbe piu' girata. Con `LibraryIndexer` come
    // @StateObject della finestra (Task 6) il sintomo e' "l'indice ha smesso di
    // aggiornarsi finche' non riavvio l'app".
    func testScanAfterCancel_worksAgain() throws {
        for i in 0..<20 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        let idx = indexer!
        _ = try idx.scan(root: root, batchSize: 2) { _ in idx.cancel() }
        XCTAssertLessThan(try store.count(), 20, "la prima scansione e' stata interrotta")

        let second = try idx.scan(root: root)
        XCTAssertEqual(try store.count(), 20, "la seconda scansione deve completare l'indice")
        XCTAssertEqual(second.errors, 0)
    }

    func testPartialIndexAfterCancelIsStillUsable() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        let idx = indexer!
        _ = try idx.scan(root: root, batchSize: 2) { _ in idx.cancel() }
        // Un indice parziale deve essere leggibile e coerente, mai a meta' riga.
        let count = try store.count()
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 10)
        XCTAssertNoThrow(try store.allKeys())
        XCTAssertEqual(try store.allKeys().count, count)
    }

    // Guardia di plausibilita' (Q3). Una scansione che vede sparire piu' della meta'
    // dell'indice e' quasi sempre un'interruzione non riconosciuta: nel dubbio si
    // tiene l'indice, perche' svuotarlo costa una ricostruzione da 5-15 minuti e
    // lascia l'import successivo senza dedup.
    func testMassiveDisappearance_keepsIndex() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10)

        for i in 0..<8 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/f\(i).jpg"))
        }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10, "sparizione implausibile: l'indice si tiene")
    }

    // ...ma una cancellazione normale viene applicata, altrimenti l'indice non si
    // pulirebbe mai. (Copre anche il confine: 5 su 10 e' ancora plausibile.)
    func testHalfDisappearance_isStillApplied() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        for i in 0..<5 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/f\(i).jpg"))
        }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 5)
    }

    // La via d'uscita: dopo una cancellazione massiccia VERA, la "Ricostruzione
    // completa" scavalca la guardia e ripulisce le entry fantasma.
    func testFullRebuild_bypassesPlausibilityGuard() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        for i in 0..<8 {
            try FileManager.default.removeItem(at: root.appendingPathComponent("Foto/f\(i).jpg"))
        }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10, "la scansione normale si tiene tutto")

        _ = try indexer.scan(root: root, ignoringStoredHashes: true)
        XCTAssertEqual(try store.count(), 2, "la ricostruzione completa ripulisce")
    }

    // Modalita' "verifica completa": non fidarsi di nulla di memorizzato.
    func testIgnoringStoredHashes_rehashesEverything() throws {
        try makeFile("Foto/a.jpg", contents: "uno")
        _ = try indexer.scan(root: root)
        let normal = try indexer.scan(root: root)
        XCTAssertEqual(normal.hashed, 0, "scansione normale: riusa l'hash memorizzato")

        let full = try indexer.scan(root: root, ignoringStoredHashes: true)
        XCTAssertEqual(full.hashed, 1, "verifica completa: rihasha comunque")
        XCTAssertEqual(full.skipped, 0)
    }

    // Root assente all'INIZIO (SSD scollegato prima di partire): le entry gia'
    // indicizzate non vanno scambiate per file cancellati.
    // NB: questo test NON copre lo scollegamento a meta' scansione — la root sparisce
    // prima che `scan` cominci, quindi scatta la `guard` in cima. Il caso "a meta'"
    // e' coperto dal controllo dopo il ciclo piu' dalla guardia di plausibilita'
    // (`testMassiveDisappearance_keepsIndex`), perche' non e' simulabile in modo
    // deterministico da un test: dipende da quando l'enumeratore smette di produrre.
    func testRootAbsentAtStart_doesNotWipeIndex() throws {
        for i in 0..<10 { try makeFile("Foto/f\(i).jpg", contents: "c\(i)") }
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10)

        // Simula lo scollegamento: la root sparisce.
        try FileManager.default.removeItem(at: root)
        _ = try indexer.scan(root: root)
        XCTAssertEqual(try store.count(), 10,
                       "root assente non significa 'tutti i file cancellati': l'indice resta")
    }
}
```

- [ ] **Step 2: Registra il file di test in `project.pbxproj`**

Stessa procedura, nome `LibraryIndexerTests.swift`, due ID nuovi.

- [ ] **Step 3: Verifica il fallimento atteso**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/LibraryIndexerTests 2>&1 | tail -30`
Expected: FAIL con `cannot find 'LibraryIndexer' in scope`.

- [ ] **Step 4: Implementa**

```swift
/// Attraversa la libreria sull'SSD, classifica, hasha e aggiorna l'indice.
/// Interamente in sola lettura sul volume: non scrive, non sposta, non cancella nulla.
final class LibraryIndexer {
    struct Progress {
        var scanned = 0     // file esaminati
        var hashed = 0      // file effettivamente (ri)hashati
        var skipped = 0     // file gia' indicizzati e ancora attendibili
        var errors = 0      // file non indicizzabili per errore di lettura
        var total = 0       // entry totali nell'indice a fine scansione
    }

    private let store: LibraryIndexStore
    private let fm = FileManager.default

    /// L'utente ha interrotto. Azzerato all'inizio di ogni `scan`: un'istanza
    /// cancellata una volta deve poter tornare a scansionare.
    private var cancelled = false

    /// Il volume e' sparito sotto di noi. Tenuto SEPARATO da `cancelled` perche' ha
    /// una conseguenza diversa: dopo una cancellazione dell'utente l'indice e'
    /// parziale ma il disco c'e'; dopo uno scollegamento non sappiamo piu' nulla di
    /// cio' che non abbiamo visto, quindi la rimozione delle entry non deve girare.
    private var volumeVanished = false

    init(store: LibraryIndexStore) { self.store = store }

    func cancel() { cancelled = true }

    // Le esclusioni NON sono ridichiarate qui: `LibraryExclusions` e' la fonte unica
    // condivisa con FileSyncer e ReviewEngine. Una seconda copia "da tenere allineata"
    // e' esattamente il modo in cui le due divergono.

    /// Scansione completa con aggiornamento incrementale.
    /// I commit avvengono a batch (non uno per file, non uno solo alla fine): cosi'
    /// un'interruzione lascia un indice parziale ma valido e utile, mai inutilizzabile.
    @discardableResult
    func scan(root: URL, batchSize: Int = 200,
              ignoringStoredHashes: Bool = false,
              onProgress: @escaping (Progress) -> Void = { _ in }) throws -> Progress {
        // Ogni scansione riparte pulita. Senza questo reset, `cancel()` (o un
        // singolo scollegamento) spegnerebbe l'indicizzazione per tutta la vita
        // dell'istanza: ogni `scan` successiva uscirebbe subito senza fare nulla e
        // la rimozione dei file spariti non girerebbe mai piu'. Se `LibraryIndexer`
        // e' un `@StateObject` che vive quanto la finestra (Task 6), il sintomo e'
        // "l'indice ha smesso di aggiornarsi finche' non riavvio l'app".
        cancelled = false
        volumeVanished = false

        var progress = Progress()
        var batch: [LibraryIndexEntry] = []
        var seenKeys = Set<String>()
        let knownKeys = try store.allKeys()

        // Root assente (SSD scollegato) NON significa "tutti i file cancellati".
        // Senza questa guardia l'enumeratore restituirebbe zero elementi, `seenKeys`
        // resterebbe vuoto e la rimozione dei file spariti cancellerebbe l'INTERO
        // indice — che e' esattamente il contrario di quello che serve.
        guard fm.fileExists(atPath: root.path) else {
            progress.total = try store.count()
            onProgress(progress)
            return progress
        }

        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return progress
        }

        while let url = enumerator.nextObject() as? URL {
            if cancelled { break }
            if LibraryExclusions.shouldExclude(url) { enumerator.skipDescendants(); continue }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard IndexableKind.of(url: url) != .notIndexable else { continue }

            progress.scanned += 1

            let relative = String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
            let key = normalizedIndexKey(relative)
            seenKeys.insert(key)

            let size = Int64(values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

            // Riuso dell'hash memorizzato quando la entry e' ancora attendibile.
            // In modalita' "verifica completa" non ci si fida di nulla di memorizzato.
            if !ignoringStoredHashes, let existing = try store.entry(forKey: key) {
                let verdict = indexEntryVerdict(storedSize: existing.size,
                                                storedMTime: existing.mtime,
                                                storedHashedAt: existing.hashedAt,
                                                currentSize: size,
                                                currentMTime: mtime)
                if verdict == .fresh {
                    progress.skipped += 1
                    continue
                }
                // .stale e .needsVerification portano entrambi al rehash: durante la
                // scansione conviene sempre risolvere il dubbio, il costo e' lo stesso.
            }

            guard let hash = sha256(of: url) else {
                progress.errors += 1
                continue
            }

            // Difesa contro una lettura troncata (es. volume scollegato a meta'):
            // se la dimensione e' cambiata sotto di noi, NON indicizzare. Un hash
            // calcolato su una lettura parziale verrebbe poi usato per saltare un
            // file in import — fallimento silenzioso con perdita di uno scatto.
            let sizeAfter = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard let sizeAfter, Int64(sizeAfter) == size else {
                progress.errors += 1
                continue
            }

            batch.append(LibraryIndexEntry(path: key, displayPath: relative, size: size,
                                           mtime: mtime, hash: hash,
                                           hashedAt: Date().timeIntervalSince1970))
            progress.hashed += 1

            if batch.count >= batchSize {
                try store.upsert(batch)
                batch.removeAll(keepingCapacity: true)
                progress.total = try store.count()
                onProgress(progress)

                // Volume scollegato a meta' scansione: fermarsi in modo pulito invece
                // di produrre errori per 100.000 file. Qui e' solo un'uscita ANTICIPATA
                // opportunistica: la garanzia vera sta nel controllo dopo il ciclo,
                // perche' questo ramo gira solo quando un batch si riempie.
                if !fm.fileExists(atPath: root.path) {
                    volumeVanished = true
                    break
                }
            }
        }

        if !batch.isEmpty { try store.upsert(batch) }

        // ---- Rimozione dei file spariti: tre guardie, tutte necessarie ----
        //
        // Il controllo di esistenza della root sta QUI e non solo dentro il ramo del
        // batch. Nella scansione incrementale — quella automatica all'avvio, il caso
        // piu' frequente — quasi tutti i file sono `.fresh` e fanno `continue` PRIMA
        // di `batch.append`: il batch non si riempie mai, quel ramo non viene mai
        // eseguito, e uno scollegamento a meta' passerebbe inosservato. L'enumeratore
        // finirebbe, `volumeVanished` resterebbe falso, e `knownKeys - seenKeys`
        // rimuoverebbe TUTTI i file non ancora visitati: l'indice svuotato, la
        // ricostruzione da 5-15 minuti da rifare, e — peggio — il primo import
        // successivo senza dati di dedup ricrea esattamente i doppioni che questa
        // feature esiste per evitare.
        if !fm.fileExists(atPath: root.path) { volumeVanished = true }

        // In modalita' "verifica completa" ogni file viene comunque visitato, quindi
        // `seenKeys` e' completo e il confronto resta valido.
        let scanWasComplete = !cancelled && !volumeVanished
        let vanished = knownKeys.subtracting(seenKeys)

        // Terza guardia, di plausibilita': sparire piu' della meta' dell'indice in
        // una sola scansione e' quasi sempre un'interruzione che non abbiamo
        // riconosciuto, non 60.000 cancellazioni reali fatte dall'utente. Nel dubbio
        // si tiene: una entry stantia costa una riverifica al prossimo import
        // (percorso ad alto danno, che rilegge comunque il file candidato, quindi su
        // un file sparito non scatta nessuno skip), mentre un indice svuotato costa
        // una ricostruzione completa e lascia l'import successivo senza dedup.
        //
        // `ignoringStoredHashes` la scavalca di proposito: e' la "Ricostruzione
        // completa", un'azione esplicita dell'utente che significa "fidati del
        // disco". Senza questa via d'uscita, dopo una cancellazione massiccia VERA
        // le entry fantasma resterebbero per sempre (ogni scansione successiva
        // rivedrebbe la stessa sparizione implausibile) e il pannello Doppioni
        // mostrerebbe gruppi che non esistono piu'.
        let plausible = ignoringStoredHashes
            || knownKeys.isEmpty
            || vanished.count * 2 <= knownKeys.count

        if scanWasComplete && !vanished.isEmpty && plausible {
            try store.remove(keys: Array(vanished))
        }

        progress.total = try store.count()
        onProgress(progress)
        return progress
    }
}
```

**Perche' `volumeVanished` non e' semplicemente `cancelled`.** Sono due fatti diversi con la stessa conseguenza *immediata* (fermarsi) ma conseguenze diverse a valle: dopo una cancellazione dell'utente il disco c'e' ancora e l'indice parziale e' affidabile per cio' che ha visto; dopo uno scollegamento non sappiamo nulla di cio' che non abbiamo visitato. Riunirli e' gia' costato un bug in questo progetto — vedi `isRunning`/`vmPossiblyUp` in `ImmichManager` (`.claude/rules/architecture.md`), dove due segnali fusi in uno hanno prodotto un vicolo cieco nella UI.

- [ ] **Step 5: Verifica che i test passino**

Run: `xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test -only-testing:AppBackupFotoTests/LibraryIndexerTests 2>&1 | tail -20`
Expected: `Executed 16 tests, with 0 failures`

- [ ] **Step 6: Build, suite completa, commit**

Expected suite: **226 test** (210 + 16).

```bash
git add AppBackupFoto/ContentView.swift AppBackupFotoTests/LibraryIndexerTests.swift AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "Add LibraryIndexer with incremental scan and truncated-read guard (roadmap #31)"
```

---

### Task 5: Dedup in `FileSyncer.sync` e in `runImport`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `FileSyncer.SyncResult` (~riga 1539), `FileSyncer.sync`/`syncDir`/`syncFile`, `JobStats` (~riga 1316), `BackupRunner.runImport`, `CompletionSheet`

**Interfaces:**
- Consuma: `LibraryIndexStore`, `LibraryIndexer`, `indexEntryVerdict`, `sha256(of:)`.
- Produce: `FileSyncer.SyncResult.duplicatesSkipped: Int`, il parametro `isDuplicate: (URL) -> Bool` su `FileSyncer.sync`, e `BackupRunner.libraryIndexStore`.

**Pattern da seguire**: `isDuplicate` si aggiunge con **default no-op** alle firme pubbliche, esattamente come è stato fatto per `onCurrentFile` in #17 — così `runMacToSSD`, `runSSDToHDD`, `runSyncS3` e `RestoreEngine` non vanno toccati affatto e continuano a comportarsi identici.

- [ ] **Step 1: Estendi `SyncResult` e `JobStats`**

In `FileSyncer.SyncResult`, accanto a `changedSkipped`:
```swift
    var duplicatesSkipped = 0   // gia' presenti altrove con contenuto identico (roadmap #31)
```

In `JobStats`, accanto a `changedSkipped`:
```swift
    var duplicatesSkipped = 0
```

- [ ] **Step 2: Aggiungi il predicato a `FileSyncer`**

Aggiungi il parametro con default no-op a `sync`, `syncDir` e `syncFile` (stessa catena già percorsa da `onCurrentFile`):

```swift
    func sync(from src: URL, to dst: URL, deep: Bool,
              onStatus: @escaping (String) -> Void,
              onProgress: @escaping (SyncResult) -> Void,
              onCurrentFile: @escaping (URL) -> Void = { _ in },
              isDuplicate: @escaping (URL) -> Bool = { _ in false }) async throws -> SyncResult {
```

In `syncFile`, **prima** della copia e **dopo** il controllo di esistenza a destinazione (l'ordine conta: zero-overwrite resta la prima regola), aggiungi:

```swift
        // Dedup per contenuto (roadmap #31): il file esiste gia' altrove nella libreria
        // con contenuto byte-identico. Non e' un errore e non e' un file "cambiato":
        // ha un contatore suo, per non confondersi con changedSkipped (#13).
        if isDuplicate(src) {
            result.duplicatesSkipped += 1
            result.done += 1
            return
        }
```

- [ ] **Step 3: Aggiungi lo store a `BackupRunner` e il predicato a `runImport`**

In `BackupRunner`, accanto agli altri membri:

```swift
    /// Indice di contenuto della libreria (roadmap #31). Lazy: se non si riesce ad
    /// aprirlo, il dedup semplicemente non avviene — l'indice e' una cache, mai un
    /// prerequisito per importare. Nessun percorso di codice deve fallire per colpa sua.
    private(set) lazy var libraryIndexStore: LibraryIndexStore? = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppBackupFoto")
        return try? LibraryIndexStore(url: dir.appendingPathComponent("library-index.sqlite"))
    }()
```

In `runImport`, costruisci il predicato e passalo a `sync`. Sostituisci la chiamata a `self?.syncer.sync(...)` con:

```swift
            let store = self.libraryIndexStore
            return try await self?.syncer.sync(from: source, to: dst, deep: false,
                onStatus: { self?.publishStatus($0) },
                onProgress: { self?.publishProgress($0) },
                onCurrentFile: { self?.publishCurrentFile($0) },
                isDuplicate: { url in
                    guard let store else { return false }
                    return BackupRunner.isAlreadyInLibrary(url: url, store: store)
                })
```

E aggiungi il metodo, `nonisolated` perché viene invocato dal thread di lavoro di `FileSyncer`, non dal MainActor (stessa lezione di `makeThumbnail` in #17):

```swift
    /// Decide se un file in arrivo e' gia' presente nella libreria con contenuto identico.
    ///
    /// Due stadi, come rmlint/jdupes/rdfind: prima la dimensione (gratis), poi l'hash
    /// (costoso). Un file la cui dimensione non compare nell'indice non viene nemmeno
    /// hashato.
    ///
    /// MODELLO DI FIDUCIA (vedi spec #31): questo e' il percorso AD ALTO DANNO — un hash
    /// stantio qui farebbe saltare in silenzio una foto diversa. Percio' NON ci si fida
    /// dell'hash memorizzato: il candidato sul disco viene riletto e rihashato prima di
    /// dichiarare il duplicato. Costa la lettura di un solo file per candidato.
    nonisolated static func isAlreadyInLibrary(url: URL, store: LibraryIndexStore) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let hasSameSize = try? store.hasAnyEntry(withSize: Int64(size)),
              hasSameSize else { return false }
        guard let sourceHash = sha256(of: url),
              let candidates = try? store.entries(withHash: sourceHash),
              !candidates.isEmpty else { return false }

        // Riverifica: l'hash memorizzato potrebbe essere stantio (mtime riscrivibile
        // da userspace, inode non affidabili su ExFAT). Rileggiamo davvero il candidato.
        guard let ssdRoot = BookmarkManager.shared.urls[.ssd] else { return false }
        for candidate in candidates {
            let candidateURL = ssdRoot.appendingPathComponent(candidate.displayPath)
            guard FileManager.default.fileExists(atPath: candidateURL.path) else { continue }
            if sha256(of: candidateURL) == sourceHash { return true }
        }
        return false
    }
```

- [ ] **Step 4: Propaga il contatore e mostralo**

In `BackupRunner.run(label:)` e in `publishProgress`, accanto a `self.stats.changedSkipped = r.changedSkipped`, aggiungi:
```swift
                        self.stats.duplicatesSkipped = r.duplicatesSkipped
```

In `CompletionSheet`, accanto alla riga condizionale già esistente per `changedSkipped`, aggiungi la gemella:
```swift
            if stats.duplicatesSkipped > 0 {
                Text("Già presenti in libreria (saltati): \(stats.duplicatesSkipped)")
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 5: Build e suite completa**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build 2>&1 | tail -10
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`, **226 test invariati** (questo task non ne aggiunge: è wiring su percorsi con I/O reale, come `runMacToSSD` e gli altri job che non hanno XCTest diretti). Il criterio è **nessuna regressione**: in particolare i test di `FileSyncerZeroOverwriteTests` e `FileSyncerChangedSkippedTests` devono restare verdi, a prova che il default no-op non ha alterato il comportamento dei flussi esistenti.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Wire content dedup into FileSyncer.sync and runImport (roadmap #31)"
```

---

### Task 6: UI — costruzione e aggiornamento dell'indice

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` — `ToolsSheet` (pannello Revisione), `SettingsSheet` (toggle), `BackupRunner`

**Interfaces:**
- Consuma: `LibraryIndexer`, `LibraryIndexStore`, `BookmarkManager.urls[.ssd]`, `VolumeMonitor.ssdMounted`.
- Produce: `@AppStorage("autoRefreshLibraryIndex")`, stato pubblicato per il progresso.

- [ ] **Step 1: Stato pubblicato in `BackupRunner`**

```swift
    @Published var indexProgress: LibraryIndexer.Progress? = nil
    @Published var isIndexing = false
    private var indexer: LibraryIndexer? = nil

    /// Costruisce o aggiorna l'indice. `full: true` = verifica completa, ignora
    /// tutto quello che c'e' in cache e rihasha ogni file.
    func rebuildLibraryIndex(full: Bool = false) {
        guard !isIndexing, let store = libraryIndexStore,
              let ssdURL = bm.startAccessing(.ssd) else { return }
        guard isLikelyVolumeRoot(ssdURL) else {
            bm.stopAccessing(.ssd)
            alert("Bookmark SSD non valido",
                  "Il percorso '\(ssdURL.path)' non è la radice del volume.\n\nVai in Impostazioni (⚙) → riseleziona SSD.")
            return
        }
        isIndexing = true
        indexProgress = LibraryIndexer.Progress()
        let idx = LibraryIndexer(store: store)
        indexer = idx
        Task.detached(priority: .utility) { [weak self] in
            defer { Task { @MainActor in self?.bm.stopAccessing(.ssd); self?.isIndexing = false } }
            do {
                _ = try idx.scan(root: ssdURL, ignoringStoredHashes: full) { p in
                    Task { @MainActor in self?.indexProgress = p }
                }
            } catch {
                await MainActor.run {
                    self?.pendingAlert = SimpleAlert(title: "Errore durante l'indicizzazione",
                                                     message: error.localizedDescription)
                }
            }
        }
    }

    func cancelIndexing() { indexer?.cancel() }
```

Aggiungi anche l'osservatore di smontaggio, così una scansione in corso si ferma appena l'utente scollega l'SSD invece di aspettare il controllo del batch successivo. Registralo dove `BackupRunner` fa già le sue inizializzazioni:

```swift
        // ATTENZIONE: le notifiche di NSWorkspace sono pubblicate sul SUO notification
        // center, non su NotificationCenter.default. Registrarsi su quello sbagliato
        // compila, non produce errori a runtime, e semplicemente non scatta mai.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willUnmountNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Non filtriamo per volume: fermare una scansione in corso a ogni
                // smontaggio e' innocuo (l'indice parziale resta valido e la scansione
                // successiva riprende), mentre continuare a leggere da un volume che
                // sta sparendo produce hash su letture troncate.
                self?.cancelIndexing()
            }
```

- [ ] **Step 2: Card "Indice libreria" in `ToolsSheet`**

Nella `ScrollView` del pannello Revisione, accanto alle card esistenti, aggiungi una card con: numero di file indicizzati (`try? runner.libraryIndexStore?.count()`), bottone "Costruisci indice" / "Aggiorna indice", bottone "Interrompi" visibile solo durante la scansione, e la `Progress` corrente (file esaminati / hashati / saltati). Prima di avviare una costruzione completa, mostra un `SimpleAlert` di conferma che spieghi che l'operazione legge per intero ogni foto e video dell'SSD e può richiedere diversi minuti.

- [ ] **Step 3: Toggle in `SettingsSheet`**

Accanto al toggle del backup automatico:
```swift
    @AppStorage("autoRefreshLibraryIndex") private var autoRefreshLibraryIndex = true
```
con etichetta "Aggiorna automaticamente l'indice della libreria" e una didascalia che chiarisca che l'aggiornamento automatico è incrementale e leggero, mentre la prima costruzione resta sempre manuale.

- [ ] **Step 4: Aggancio automatico**

In `ContentView`, accanto all'`.onChange(of: volumes.ssdMounted)` già esistente per il backup automatico, aggiungi l'aggiornamento incrementale quando `autoRefreshLibraryIndex` è attivo, **solo se l'indice esiste già** (`count() > 0`): la prima costruzione non deve mai partire da sola. Aggiungi lo stesso aggiornamento a fine di un job di import riuscito.

- [ ] **Step 5: Build, suite completa, verifica manuale**

Expected: `** BUILD SUCCEEDED **`, 226 test invariati.

Verifica manuale (richiede SSD collegato, quindi **a carico di Enrico**): aprire Diagnostica, vedere la card, avviare la costruzione, verificare che il progresso avanzi, interromperla e verificare che l'indice resti utilizzabile, riavviarla e verificare che riprenda senza rihashare ciò che era già stato fatto.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "Add library index UI: build/refresh card, toggle, auto incremental refresh (roadmap #31)"
```

---

### Task 7: Documentazione

**Files:**
- Modify: `Docs/ROADMAP.md`, `Docs/CLAUDE.md`, `.claude/rules/architecture.md`

- [ ] **Step 1: `Docs/ROADMAP.md`**

Aggiungi il punto **31** al capitolo aperto: indice di contenuto della libreria, nucleo implementato (data odierna), con riferimento a spec e piano. Segnala che il **pannello Doppioni** resta da fare come incremento successivo e che #27-A riprende dal Task 3.

**Controllo incrociato esplicito**: dopo la modifica, rileggi l'**intero** `Docs/ROADMAP.md` cercando altre righe riassuntive che parlano dello stato del capitolo (le sezioni di riepilogo a fine capitolo si sono disallineate su #14, #15 e #16) e correggile. Non fermarti alla prima occorrenza trovata con un grep.

- [ ] **Step 2: `Docs/CLAUDE.md`**

Aggiorna la tabella "Stato attuale" con la riga dell'indice, e la sezione "Verifiche manuali pendenti" con la verifica della prima costruzione reale su SSD.

- [ ] **Step 3: `.claude/rules/architecture.md`**

Aggiungi una sezione sui quattro componenti nuovi. Documenta esplicitamente, perché sono le cose che un futuro intervento rischia di rompere senza accorgersene:
- il **modello di fiducia a due livelli** e perché lo skip in import rileva sempre l'hash invece di fidarsi della cache;
- che l'**inode non è utilizzabile** su ExFAT e perché (con la fonte);
- che la **tolleranza DST** non ha prior art ed è una scelta di questo progetto;
- che le chiavi dell'indice sono **normalizzate NFC + minuscole** e perché;
- che `isDuplicate` ha un **default no-op** apposta, così i tre job esistenti e `RestoreEngine` non sono toccati.

- [ ] **Step 4: Commit**

```bash
git add Docs/ROADMAP.md Docs/CLAUDE.md .claude/rules/architecture.md
git commit -m "docs: document library content index core (roadmap #31)"
```
