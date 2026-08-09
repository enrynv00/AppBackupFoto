# Roadmap #14: String Catalog (pulizia, nessuna traduzione)

Data: 2026-08-09

## Problema

`Docs/ROADMAP.md` punto #14: stringhe italiane hardcoded in `ContentView.swift`, `STRING_CATALOG_GENERATE_SYMBOLS = YES` già nelle build settings del target ma nessuno String Catalog (`.xcstrings`) esiste ancora nel progetto — l'impostazione non ha effetto senza un catalogo da cui generare i simboli.

Il punto veniva da una revisione stile-CTO basata su app commerciali (Arq, CCC, ChronoSync), pensata per un prodotto "da mercato". Chiarito con l'utente: l'app è personale, usata solo da lui in italiano — **nessuna vera localizzazione multi-lingua richiesta ora**. Obiettivo di questo intervento: solo pulizia/preparazione (String Catalog presente e popolato), non traduzione.

## Scoperta tecnica rilevante

Il target dell'app (non il target test) ha già `SWIFT_EMIT_LOC_STRINGS = YES` nelle sue build configuration (righe indicative 487/519 di `project.pbxproj`), a differenza delle configurazioni a livello di progetto/target test dove è `NO`. Questo significa che il compilatore Swift **estrae automaticamente durante la build** tutte le stringhe usate in view SwiftUI (`Text`, `Button`, `Label`, ecc. — che usano implicitamente `LocalizedStringKey`) verso un String Catalog presente nel target, **incluse le stringhe con interpolazione** (es. `Text("Recuperate \(engine.progress.done) di \(engine.progress.total) foto")`), generando correttamente i placeholder di formato.

Non serve quindi costruire il catalogo a mano né usare il refactoring GUI di Xcode ("Migrate to String Catalog") — basta che un file `.xcstrings` vuoto esista nel target e sia incluso nella build; una build normale lo popola.

## Decisioni di design (dal brainstorming)

- **Obiettivo**: solo pulizia/preparazione. L'app resta e resterà solo in italiano — nessuna nuova lingua aggiunta, nessuna vera traduzione.
- **Ambito stringhe**: solo `Text`/`Button`/`Label` SwiftUI in `ContentView.swift` (quelle che l'estrazione automatica del compilatore copre). Alert/dialoghi/voci di menu costruiti come `String` semplice restano fuori scope — decisione esplicita, per tenere l'intervento piccolo e a rischio minimo.
- **`developmentRegion`**: correggere da `en` a `it` nel `project.pbxproj` — incoerenza notata (il codice è sempre stato in italiano, mai in inglese), va allineata insieme a questo intervento visto che si tocca comunque la configurazione di localizzazione.
- **`STRING_CATALOG_GENERATE_SYMBOLS`**: resta `YES` com'è già, nessuna modifica necessaria (genera solo i simboli Swift accessori dal catalogo, non serve toccarlo).

## Design tecnico

1. `project.pbxproj`: `developmentRegion = en;` → `developmentRegion = it;`.
2. Nuovo file `AppBackupFoto/Localizable.xcstrings`, creato con struttura JSON minima valida (`sourceLanguage: "it"`, nessuna entry — il compilatore le aggiunge al build), aggiunto al target come risorsa (`PBXFileReference` + `PBXBuildFile` in Resources build phase, coerente con come sono gestite le altre risorse del target).
3. Build (`xcodebuild build`) per far estrarre al compilatore le stringhe usate in `ContentView.swift` — nessuna modifica manuale al codice Swift, il meccanismo è già abilitato sul target (`SWIFT_EMIT_LOC_STRINGS = YES`).
4. Verifica che il catalogo popolato dopo la build contenga sia stringhe semplici sia almeno una delle interpolate, con placeholder generati correttamente (spot-check, non un controllo esaustivo di tutte le ~40 stringhe).

## Fuori scope

- Nessuna nuova lingua/traduzione reale.
- Alert, dialoghi, voci di menu bar, notifiche costruiti come `String` Swift semplice (non `Text`/`Button`/`Label` SwiftUI diretti) — non coperti dall'estrazione automatica del compilatore, andrebbero cablati manualmente; deciso di lasciarli fuori per ora.
- Nessun cambiamento a `STRING_CATALOG_GENERATE_SYMBOLS`.
- Nessun refactoring del codice esistente in `ContentView.swift` — l'estrazione è puramente a livello di build/project settings.

## Testing

- Build pulita (`xcodebuild build`) per confermare che il catalogo venga riconosciuto e popolato senza errori.
- Verifica che il file `.xcstrings` non sia più vuoto dopo il build; spot-check di una stringa semplice e di una interpolata per confermare il formato corretto.
- Suite XCTest esistente invariata — nessuna logica applicativa toccata, ci si aspetta la stessa conta di test verdi di prima.
- Verifica visiva (lancio app) che l'interfaccia mostri ancora il testo italiano corretto, non chiavi grezze — modo di fallimento tipico se il catalogo/target membership fosse mal configurato.
