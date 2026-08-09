# Roadmap #14: String Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere uno String Catalog (`Localizable.xcstrings`) al target `AppBackupFoto`, popolato automaticamente dal compilatore con le stringhe italiane già usate in `ContentView.swift`, senza aggiungere nessuna nuova lingua o tradurre nulla — solo pulizia/preparazione (roadmap #14).

**Architecture:** Il target `AppBackupFoto` ha già `SWIFT_EMIT_LOC_STRINGS = YES` nelle sue build configuration — il compilatore Swift estrae automaticamente, ad ogni build, le stringhe usate in view SwiftUI (`Text`, `Button`, `Label`, che usano implicitamente `LocalizedStringKey`) verso qualunque String Catalog presente nel target, incluse le stringhe con interpolazione (placeholder generati correttamente dal compilatore, non a mano). Basta quindi: (1) correggere `developmentRegion`/`knownRegions` da `en` a `it` in `project.pbxproj` per allinearli alla lingua reale del codice, (2) creare un file `AppBackupFoto/Localizable.xcstrings` vuoto con `sourceLanguage: "it"`. Il target `AppBackupFoto` usa un `PBXFileSystemSynchronizedRootGroup` (righe 65-73 di `project.pbxproj`) — qualunque file aggiunto dentro la cartella `AppBackupFoto/` viene incluso automaticamente nel target, **non serve aggiungere manualmente `PBXFileReference`/`PBXBuildFile`** per il nuovo file (a differenza del target `AppBackupFotoTests`, che non è file-system-synchronized).

**Tech Stack:** Xcode 26.6 String Catalogs (formato JSON `.xcstrings`), `xcodebuild` da riga di comando, XCTest.

## Global Constraints

- File principale unico: tutto il codice app resta in `AppBackupFoto/ContentView.swift` — questo intervento non tocca `ContentView.swift`.
- Nessuna nuova lingua, nessuna traduzione reale — solo italiano, `sourceLanguage: "it"`.
- Ambito stringhe: solo `Text`/`Button`/`Label` SwiftUI (estrazione automatica del compilatore). Alert/dialoghi/menu costruiti come `String` semplice restano fuori scope, non toccarli.
- `STRING_CATALOG_GENERATE_SYMBOLS` resta `YES` com'è già — non modificarlo.
- Build (`xcodebuild ... build`) e test (`xcodebuild ... test`) verdi prima di ogni commit.
- Baseline attuale (verificata prima di questo piano): 75 test XCTest verdi, 0 falliti. Ci si aspetta la stessa conta di 75 dopo ogni task — nessuna logica applicativa viene toccata.
- Comando build: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
- Comando test: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`

---

### Task 1: Correggere `developmentRegion`/`knownRegions` e creare il catalogo vuoto

**Files:**
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (righe indicative 212, 214-217 — verificare nel file reale col contenuto esatto mostrato sotto)
- Create: `AppBackupFoto/Localizable.xcstrings`

**Interfaces:**
- Consumes: nessuna dipendenza da altri task
- Produces: file `AppBackupFoto/Localizable.xcstrings` vuoto e valido, pronto per essere popolato dalla build in Task 2. Nessuna funzione/tipo Swift coinvolto.

- [ ] **Step 1: Leggere il blocco attuale in `project.pbxproj`**

Il blocco attuale (contesto attorno alla riga 212) è:

```
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
```

- [ ] **Step 2: Modificare `developmentRegion` e `knownRegions`**

Sostituisci il blocco sopra con:

```
			developmentRegion = it;
			hasScannedForEncodings = 0;
			knownRegions = (
				it,
				Base,
			);
```

- [ ] **Step 3: Creare `AppBackupFoto/Localizable.xcstrings`**

Crea il file con questo contenuto esatto (struttura minima valida di uno String Catalog vuoto, lingua sorgente italiano):

```json
{
  "sourceLanguage" : "it",
  "strings" : {

  },
  "version" : "1.0"
}
```

- [ ] **Step 4: Build per verificare che il progetto riconosca il nuovo file senza errori**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Verificare che `Localizable.xcstrings` sia stato popolato automaticamente dalla build**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && python3 -c "import json; d=json.load(open('AppBackupFoto/Localizable.xcstrings')); print('entries:', len(d['strings'])); print(list(d['strings'].keys())[:5])"`
Expected: `entries:` maggiore di 0 (indicativamente 25-45, tante quante le stringhe letterali usate in `Text`/`Button`/`Label` in `ContentView.swift`).

Se `entries: 0`, il file non è stato incluso nel target: verificare che il file sia effettivamente dentro la cartella `AppBackupFoto/` (non in una sottocartella non prevista) e ripetere la build — non procedere al passo successivo finché il conteggio non è maggiore di 0.

- [ ] **Step 6: Spot-check di una stringa semplice e di una interpolata**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && python3 -c "
import json
d = json.load(open('AppBackupFoto/Localizable.xcstrings'))
keys = list(d['strings'].keys())
simple = [k for k in keys if '%' not in k][:1]
interp = [k for k in keys if '%' in k][:1]
print('simple:', simple)
print('interpolated:', interp)
"`

Expected: `simple` contiene una stringa italiana leggibile (es. qualcosa come `['Impostazioni']` o simile, dipende da cosa il compilatore ha estratto). `interpolated` contiene una chiave con placeholder di formato (es. qualcosa come `['Recuperate %lld di %lld foto']`) — conferma che il compilatore ha gestito correttamente l'interpolazione senza intervento manuale.

- [ ] **Step 7: Eseguire la suite di test per confermare nessuna regressione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: `Executed 75 tests, with 0 failures` e `** TEST SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto.xcodeproj/project.pbxproj AppBackupFoto/Localizable.xcstrings
git commit -m "Add String Catalog for roadmap #14 (Italian-only, no translation)"
```

---

### Task 2: Aggiornamento documentazione (`Docs/CLAUDE.md`, `Docs/ROADMAP.md`)

**Files:**
- Modify: `Docs/ROADMAP.md` (voce #14 nella sezione "Valore aggiunto", e la riga riassuntiva "Da dove partire" se presente in fondo)
- Modify: `Docs/CLAUDE.md` (solo se esiste una sezione che elenca lo stato di localizzazione/build settings del progetto — verificare col grep sotto prima di modificare)

**Interfaces:**
- Consumes: risultato di Task 1 (catalogo creato e popolato, build/test verdi)
- Produces: nessuna interfaccia di codice — solo documentazione aggiornata, letta dalle sessioni future su questo progetto

- [ ] **Step 1: Verificare i punti esatti da aggiornare**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "14\." Docs/ROADMAP.md`

- [ ] **Step 2: Aggiornare la voce #14 in `Docs/ROADMAP.md`**

Trova la riga:

```
14. **Stringhe italiane hardcoded, nessuna localizzazione** — `STRING_CATALOG_GENERATE_SYMBOLS = YES` già nelle build settings, ma le stringhe non sono estratte in un String Catalog.
```

Sostituiscila con:

```
14. ✅ **Fatto (2026-08-09) — Stringhe italiane hardcoded, nessuna localizzazione.** Aggiunto `AppBackupFoto/Localizable.xcstrings` (String Catalog, `sourceLanguage: "it"`), popolato automaticamente dal compilatore (`SWIFT_EMIT_LOC_STRINGS`, già attivo sul target) con le stringhe usate in `Text`/`Button`/`Label` di `ContentView.swift`, incluse quelle con interpolazione. Solo pulizia/preparazione, deciso esplicitamente contro una vera localizzazione multi-lingua (l'app resta solo in italiano, nessun utente non italofono) — go/no-go come per #5. `developmentRegion`/`knownRegions` corretti da `en` a `it` (incoerenza preesistente, mai allineata). Alert/dialoghi/menu costruiti come `String` semplice restano fuori scope. Vedi `Docs/superpowers/specs/2026-08-09-string-catalog-design.md`.
```

- [ ] **Step 3: Aggiornare la sezione riassuntiva di fine file se presente**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n "Da dove partire\|Stato aggiornato" Docs/ROADMAP.md`

Nella riga che elenca i punti fatti (es. `Fatti: #1 restore, #2 ..., #13 segnalazione file cambiati.`), aggiungi `, #14 String Catalog` in coda alla lista esistente, mantenendo lo stesso stile della frase.

- [ ] **Step 4: Verificare se `Docs/CLAUDE.md` menziona esplicitamente la mancanza di localizzazione**

Run: `cd /Users/enriconannivicenzi/Desktop/AppBackupFoto && grep -n -i "local" Docs/CLAUDE.md`

Se non ci sono righe rilevanti (probabile — `Docs/CLAUDE.md` documenta architettura, non lo stato della roadmap), non modificare `Docs/CLAUDE.md` e passare al commit. Se invece esiste una riga che dichiara esplicitamente "nessuna localizzazione" o simile, aggiornarla con una frase coerente a quella scritta in `Docs/ROADMAP.md` al passo 2.

- [ ] **Step 5: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/ROADMAP.md Docs/CLAUDE.md
git commit -m "Update Docs/CLAUDE.md and ROADMAP.md: String Catalog (#14) shipped"
```
