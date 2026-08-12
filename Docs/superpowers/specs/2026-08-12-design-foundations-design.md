# Fase 1 — Fondamenta design (roadmap #21)

Data: 2026-08-12

## Problema

Roadmap #21 (nuovo capitolo "Design polish", aperto dopo la chiusura della roadmap tecnica originale): l'app funziona ma ha un look "ok, non polished, non cutting edge" (feedback diretto di Enrico). Audit UI (Architect agent, 2026-08-12) su `ContentView.swift` ha trovato zero design token: 13 blu, 13 rossi, 12 verdi, 10 arancioni, 4 viola hardcoded senza semantica (`.purple` usato per 3 cose diverse: Cubbit S3, Tools, pallino volume always-on); 16 dimensioni di font numeriche sovrapposte a 3 stili semantici mescolati (`.caption`/`.caption2`/`.title2`); 15 valori di `spacing` e 16 di `padding` senza griglia comune (3, 5, 14, 18, 22, 28, 36, 38, 40...); pattern "card" copiaincollato 9 volte con 3 opacità e 4 corner radius diversi. Ricerca (Researcher agent, 2026-08-12) su best practice macOS 2025-2026 conferma: le app curate (Raycast citata come riferimento concreto) usano un accent singolo + colori semantici per stato, mai colori arbitrari decorativi, e una griglia di spacing coerente (4/8pt).

Questa è la Fase 1 di un lavoro di restyling diviso in 5 fasi indipendenti (vedi `Docs/ROADMAP.md`, punti 21-25) — le fondamenta (palette/tipografia/spacing) devono essere pronte prima delle fasi successive (struttura, componenti, micro-interazioni, dialoghi), che le useranno.

## Decisioni prese in brainstorming

- **Scope generale scelto da Enrico**: restyling completo, incluse Fase 2 (struttura, `NavigationSplitView` + Liquid Glass) e le fasi successive — questa spec copre solo Fase 1.
- **Target macOS**: alzato a macOS 26 (Tahoe) — Enrico lo usa già sulla sua macchina, nessun vincolo di compatibilità con versioni precedenti per questo progetto single-user.
- **Accent color**: nessuna modifica — resta il colore di sistema di default (quello impostato da Enrico in Preferenze di Sistema), non un colore custom. `AccentColor.colorset` resta vuoto/default.
- **Come definire i token**: enum Swift dentro `ContentView.swift`, non color set in `Assets.xcassets`. Coerente con la convenzione esplicita del progetto ("nessun nuovo file `.swift`, tutto il codice del target app vive in `ContentView.swift`") e con la preferenza di Enrico di avere tutto in un solo posto controllabile in codice.
- **Palette semantica approvata** (dettaglio sotto): 3 colori di stato (successo/errore/warning), 3 colori identità-destinazione (Mac→SSD/SSD→HDD/SSD→Cubbit S3), 1 grigio neutro per Tools/utility — ogni colore ha un solo significato in tutta l'app, nessuna condivisione tra ruoli diversi.
- **Tipografia approvata**: 5 ruoli di testo con nome (non 7-8, Enrico ha confermato 5 sufficienti) + 2 taglie icona "hero".
- **Spacing approvato**: griglia fissa a 6 valori (4/8/12/16/24/32), base 4pt — non 5pt o altra unità.

## Design tecnico

### 1. Palette semantica

Nuovo enum `AppColor` (o nome equivalente da confermare in fase di piano contro eventuali collisioni di nome nel file reale) con case computate che restituiscono `Color`:

**Colori di stato** (wrappano colori dinamici di sistema già semantici — nessun nuovo valore RGB, solo un nome coerente al posto di `.green`/`.red`/`.orange` sparsi):
- `.success` → `Color.green`
- `.error` → `Color.red`
- `.warning` → `Color.orange`

**Colori identità-destinazione** (un hue per destinazione, riusato SOLO per quella destinazione ovunque compaia: icone, badge, voci di log, grafici):
- `.macToSSD` → `Color.blue`
- `.ssdToHDD` → `Color.teal`
- `.ssdToCubbit` → `Color.purple` (liberato dagli altri due usi impropri attuali: Tools e pallino volume always-on)

**Colore utility**:
- `.utility` → un grigio neutro di sistema (es. `Color.secondary` o `Color(NSColor.systemGray)`, da confermare in fase di piano quale variante di grigio rende meglio nel contesto reale) — usato per Tools e per il pallino volume always-on, che oggi condividono impropriamente il viola.

Regola di applicazione: i colori di stato non vengono mai usati decorativamente (es. mai un'icona verde solo perché "sta bene"), i colori destinazione non vengono mai usati per comunicare stato (es. mai il blu di Mac→SSD per dire "successo").

### 2. Tipografia

Nuovo enum (es. `AppFont` o `AppTextStyle`, nome da confermare in piano) con 5 ruoli, ciascuno una combinazione fissa size/weight che sostituisce le 16 dimensioni numeriche sparse e i 3 stili semantici mescolati oggi in uso:

1. **Titolo** (sheet/pannello) — sostituisce l'attuale mix `.title2`/`.title3`/`size:15,.medium` usato per lo stesso ruolo in punti diversi.
2. **Intestazione sezione** — sotto-titoli all'interno di uno sheet/pannello.
3. **Corpo** (righe/liste) — il testo standard di righe cliccabili, voci di menu, contenuto principale. Oggi sparso tra 13pt e 14pt in punti diversi per lo stesso ruolo — diventa un solo valore.
4. **Didascalia** — metadati secondari, timestamp, sottotitoli minori (oggi `.caption`/`.caption2` mescolati senza criterio).
5. **Numero hero** — le statistiche grandi (MB/s, contatori, percentuali nelle StatCard/CStat). Oggi 5 dimensioni diverse (36/40/48/52/60px) per lo stesso ruolo — diventa un solo valore.

Le icone "hero" (oggi 5 dimensioni diverse tra 36 e 60px) si riducono a 2 taglie: una per icone dentro sheet/pannelli a schermo intero, una più piccola per icone dentro card/righe.

I valori esatti in punti per ciascun ruolo (es. "corpo" = 13pt regular vs 14pt) vanno decisi in fase di piano guardando la distribuzione reale delle occorrenze in `ContentView.swift`, per capire quale valore attuale è già maggioritario e minimizzare le eccezioni visive impreviste — questa spec fissa i *ruoli* e il principio "un ruolo, una sola combinazione ovunque", non i numeri finali.

### 3. Spacing

Nuovo enum (es. `AppSpacing`) con 6 costanti fisse:

```swift
enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}
```

Migrazione: ogni valore arbitrario oggi in uso (`spacing`/`padding` con 3, 5, 14, 18, 22, 28, 36, 38, 40...) viene arrotondato al valore di griglia più vicino. Esempio esplicito confermato in brainstorming: i 5 padding contenitore sheet oggi diversi (28/32/36/38/40) diventano tutti `AppSpacing.xxl` (32). Il pattern "card" (oggi copiaincollato 9 volte con 3 opacità/4 corner radius diversi) userà anch'esso valori fissi dalla stessa filosofia: un solo corner radius (valore esatto da confermare in piano, orientativamente 10, il valore già maggioritario nell'audit) e una sola opacità per lo sfondo `.quaternary`.

## Migrazione

Questa fase tocca **solo** i valori (colori/font/spacing), non la struttura delle view (niente `NavigationSplitView`, niente materials — quello è Fase 2) e non introduce nuovi componenti condivisi riutilizzabili tra card diverse (quello è Fase 3, che userà però già questi token). Ogni occorrenza hardcoded nel file va sostituita con il token corrispondente — il piano di implementazione enumererà i call site reali con numeri di riga, dato che è probabile che alcuni siano scoperti solo aprendo il file (l'audit ha già fornito una mappa parziale con riferimenti riga, da usare come base ma da riverificare contro il file reale al momento del piano, coerente con la pratica già seguita nelle fasi precedenti del progetto).

## Testing

Nessuna nuova logica di business, solo valori statici e styling — nessun nuovo XCTest sensato (stesso ragionamento già applicato a #11/#15/#16/#20). La suite esistente va comunque rieseguita dopo ogni task per assicurarsi che nessuna modifica di styling rompa build o test esistenti (nessuno dei test attuali dovrebbe dipendere da colori/font/spacing, ma va verificato). Verifica visiva manuale richiesta a fine fase (non eseguibile in ambiente headless): aprire l'app e controllare a occhio che nessuna sezione sembri "rotta" (contrasto insufficiente, testo tagliato per un padding ridotto, colore di stato che non si vede più su un dato sfondo).

## Fuori scope

- Nessun cambio strutturale (`HSplitView`→`NavigationSplitView`, materials/Liquid Glass) — Fase 2.
- Nessuna unificazione di componenti duplicati (`StatCard`/`CStat`, `GroupBox` vs card manuali) — Fase 3, che riuserà questi token.
- Nessuna micro-interazione (`onHover`, `contentTransition`, `symbolEffect`, skeleton) — Fase 4.
- Nessuna migrazione `NSAlert`→SwiftUI `.alert` — Fase 5.
- Nessun colore accent custom — resta il default di sistema per scelta esplicita di Enrico.
- Nessun color set in `Assets.xcassets` — tutto in enum Swift per scelta esplicita di Enrico.
