# Fase 4 — Micro-interazioni (roadmap #24)

Data: 2026-08-12

## Problema

Roadmap #24 (quarto capitolo del piano "Design polish", dopo Fase 1-3 — design token, struttura/Liquid Glass, unificazione componenti — tutte chiuse e verificate). L'audit UI originale (Architect agent, 2026-08-12) aveva segnalato: "Zero `onHover` in tutto il file, su 8+ righe `buttonStyle(.plain)` → sembrano morte al passaggio del mouse" e "Animazioni assenti su numeri e cambi di fase — nessuna `contentTransition(.numericText())` sui contatori". La ricerca sulle best practice macOS 2025-2026 (Researcher agent, stessa data) aveva raccomandato `contentTransition`/`symbolEffect` per numeri/icone di stato e hover feedback su ogni elemento interattivo, non solo bottoni.

## Decisioni prese in brainstorming

- **Hover**: tint di sfondo leggero (pattern standard macOS per righe di lista/menu), non scale/opacity (più da app mobile). Applicato a `HamburgerRow`, `OpsButton`, `LocationRow`, e le righe cliccabili del wizard Ripristina (`chooseFoldersStep` folder row, `restoreSourceRow`, `s3SourceRow` quando disponibile).
- **Numeri**: `.contentTransition(.numericText())` sul valore in `StatTile` (Fase 3), sulla percentuale e sulla velocità in `StatsPanel` — nessun cambio ad altri numeri nell'app (es. non ai contatori dentro `ToolsSheet`, fuori scope).
- **Icone di stato**: `.contentTransition(.symbolEffect(.replace))` sull'icona in `PhaseIndicator` (transizione morph quando `phase.icon` cambia tra idle/successo/errore — il caso "running" già non mostra l'icona, sostituita da uno spinner, invariato).
- **Skeleton/`.redacted`**: fuori scope per questa fase — nessun caso reale nel codice attuale (i 3 `ProgressView()` nudi sono spinner brevi con contesto già chiaro, non liste che caricano a lungo mostrando dati fasulli). Non forzato artificialmente.
- **Nessun cambio ai design token/componenti** di Fase 1-3 (`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize`, `.cardBackground()`, `StatTile`, `CardGroupBoxStyle`) — riusati così come sono.

## Design tecnico

### 1. Hover — tint di sfondo su righe cliccabili

Pattern applicato a ciascuna delle righe elencate: uno `@State private var isHovering = false` locale alla view (o, se la struct non è già `@State`-capable per via di essere un `View` semplice con `let` properties, tramite `@State` aggiunto direttamente alla struct — ognuna di queste è già una `struct: View` autonoma, quindi può avere il proprio `@State`), aggiornato con `.onHover { isHovering = $0 }`, e uno sfondo condizionale (es. `Color.primary.opacity(isHovering ? 0.05 : 0)`) applicato dietro al contenuto esistente della riga. Esempio concettuale (la sintassi esatta e il punto preciso di inserimento per ciascuna delle ~6 righe vanno decisi in fase di piano contro il codice reale di ognuna, che ha strutture leggermente diverse):

```swift
.background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
.onHover { isHovering = $0 }
```

Nessun cambio al comportamento di click/azione esistente — solo un layer di feedback visivo aggiuntivo. Animazione implicita leggera (`.animation(.easeInOut(duration: 0.1), value: isHovering)` o simile) per evitare uno scatto secco.

### 2. Numeri — `contentTransition(.numericText())`

Applicato a: `StatTile.body`'s `Text(value)` (Fase 3, riga ~3047 al momento della scrittura di questa spec), `Text("\(stats.percent)%")` in `StatsPanel` (riga ~3433), `Text("velocita \(stats.speed)")` in `StatsPanel` (riga ~3441). Ciascuno guadagna `.contentTransition(.numericText())`, e — dato che SwiftUI applica le content transition solo dentro un contesto di animazione esplicito — un `.animation(.default, value: <valore osservato>)` sulla view che contiene il testo (o sul testo stesso), dove `<valore osservato>` è la proprietà che cambia (es. `stats.percent`, `stats.speed`, il parametro `value` di `StatTile`). Il principio: quando i numeri cambiano durante un job, le cifre si aggiornano con un cross-dissolve invece di un cambio istantaneo — dettaglio da confermare visivamente in fase di piano con un job reale o un valore forzato temporaneamente, dato che l'effetto è visibile solo con valori che cambiano nel tempo.

### 3. Icona di stato — `symbolEffect` in `PhaseIndicator`

```swift
Image(systemName: phase.icon)
    .foregroundStyle(phase.color)
    .contentTransition(.symbolEffect(.replace))
```

Applicato al ramo `else` di `PhaseIndicator.body` (il caso non-`.running`, righe ~3379-3382 al momento della scrittura di questa spec) — l'icona esistente (`circle.dotted`/`checkmark.circle.fill`/`xmark.circle.fill`) guadagna solo il modificatore, nessun cambio al system name scelto per ciascuno stato. Stesso `.animation(.default, value: phase)` (o equivalente) necessario perché la transizione si attivi al cambio di `phase`.

## Testing

Nessuna nuova logica di business — solo styling/animazioni. Nessun nuovo XCTest sensato (stesso ragionamento delle fasi precedenti). Suite esistente (79 test) va rieseguita dopo ogni task. **Verifica manuale richiesta** (non del tutto automatizzabile in ambiente headless, alcuni effetti si vedono solo con interazione reale del mouse o durante un job in corso): passare il mouse su ciascuna delle righe elencate e confermare il tint hover; se possibile avviare un job reale (o forzare temporaneamente un cambio di `stats.percent`/`stats.speed` per la verifica, poi tornare al comportamento normale) per vedere la transizione numerica; cambiare `phase` (es. da idle a un job che termina) per vedere la transizione dell'icona.

## Fuori scope

- Nessuno skeleton/`.redacted(reason: .placeholder)` — nessun caso reale identificato in questa fase.
- Nessun cambio ai design token/componenti di Fase 1-3.
- Nessuna migrazione `NSAlert`→SwiftUI `.alert` — Fase 5.
- Nessun hover su elementi non elencati (es. `VolumeRow`, che non è cliccabile, o i bottoni standard SwiftUI che hanno già un feedback nativo del proprio `.buttonStyle`).
- Nessun cambio ad altri numeri nell'app oltre ai 3 elencati (es. contatori in `ToolsSheet`/`CompletionSheet`, fuori scope).
