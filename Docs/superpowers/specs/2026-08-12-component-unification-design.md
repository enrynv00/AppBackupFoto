# Fase 3 — Unificazione componenti (roadmap #23)

Data: 2026-08-12

## Problema

Roadmap #23 (terzo capitolo del piano "Design polish", dopo Fase 1 — fondamenta design, roadmap #21, e Fase 2 — struttura/Liquid Glass, roadmap #22, entrambe chiuse e verificate). L'audit UI originale (Architect agent, 2026-08-12) aveva segnalato, priorità Alto: "Card copiaincollata con 4 radius e 3 opacità diverse" — Fase 1 ha già unificato i *valori* (`AppSpacing.cardCornerRadius`/`cardOpacity`), ma la *struttura* resta copiaincollata: 9 occorrenze dello stesso pattern `.background(.quaternary.opacity(...)).clipShape(RoundedRectangle(cornerRadius: ...))` scritte a mano ogni volta. Stesso audit, priorità Medio: "`StatCard`/`CStat` duplicati" (differiscono solo per `frame`, non più per valori dopo Fase 1) e "`GroupBox` in Tools vs card manuali altrove — due linguaggi visivi convivono".

## Decisioni prese in brainstorming

- **Pattern card**: un `ViewModifier` (`.cardBackground()`), non un componente wrapper — cambio minimo per ognuna delle 9 occorrenze (sostituisce 2 modificatori concatenati con 1, nessuna ristrutturazione del contenuto esistente).
- **`StatCard`/`CStat`**: unificati in una sola struct, chiamata `StatTile` (nome più descrittivo di `CStat`, `StatCard` era già quasi giusto). Parametro `compact: Bool`: `true` riproduce il comportamento `CStat` (`frame(minWidth: 58)` + `padding(.horizontal, 8)`, usato in `CompletionSheet` per la riga compatta a fine job), `false` riproduce il comportamento `StatCard` (`frame(maxWidth: .infinity)`, usato in `StatsPanel` durante un job in corso). Nessun cambio alla resa visiva in nessuno dei due contesti — stesso identico output di oggi, solo una struct invece di due.
- **`GroupBox` in `ToolsSheet`**: un `GroupBoxStyle` custom (applicato via `.groupBoxStyle(...)`) che riusa gli stessi token del pattern card (`AppSpacing.cardCornerRadius`/`cardOpacity`) — non una sostituzione di `GroupBox` con `VStack`+`.cardBackground()`. Mantiene il comportamento nativo (label semantica, accessibilità) dei 4 blocchi esistenti (Cartelle Configurate, S3 — Cubbit, Sync Info, Revisione), cambia solo l'aspetto.
- **Nessun cambio ai design token** di Fase 1 (`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize`) — riusati così come sono.
- **Nessun cambio strutturale oltre questi 3 punti** — niente nuove view, niente cambi a `NavigationSplitView`/Liquid Glass (Fase 2, già fatta), niente micro-interazioni (Fase 4), niente dialoghi (Fase 5).

## Design tecnico

### 1. `.cardBackground()` — ViewModifier

Nuovo `ViewModifier` (nome esatto e posizione di definizione da confermare in fase di piano, verosimilmente vicino agli altri design token o subito dopo di essi):

```swift
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.quaternary.opacity(AppSpacing.cardOpacity))
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}
```

Applicato alle 9 occorrenze esistenti, sostituendo `.background(.quaternary.opacity(AppSpacing.cardOpacity)).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))` (o le 2 varianti ancora con valori letterali `0.4`/`8` non ancora passate a token, se ce ne sono — da verificare in piano contro il file reale) con `.cardBackground()`. Il `.padding(...)` che precede ciascuna occorrenza (diverso da caso a caso: `AppSpacing.md`, `AppSpacing.sm`, ecc.) resta invariato, non fa parte del modificatore — solo background+clipShape vengono accorpati.

### 2. `StatTile` — merge di `StatCard`/`CStat`

```swift
struct StatTile: View {
    let label: String; let value: String; let accent: Color
    var compact: Bool = false
    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            Text(value).font(AppFont.heroNumber)
                .foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: compact ? nil : .infinity, minWidth: compact ? 58 : nil)
        .padding(.vertical, AppSpacing.sm)
        .padding(.horizontal, compact ? 8 : 0)
        .cardBackground()
    }
}
```

(scheletro concettuale — la sintassi esatta del modificatore `.frame` condizionale va verificata in fase di piano contro il comportamento reale di entrambi i casi, il principio è "stesso output visivo di `StatCard` quando `compact: false`, stesso output di `CStat` quando `compact: true`", non questo specifico frammento di codice se il compilatore richiede una forma diversa).

Call site in `CompletionSheet` (oggi `CStat(...)`, 4 occorrenze): diventano `StatTile(..., compact: true)`.
Call site in `StatsPanel` (oggi `StatCard(...)`, 5 occorrenze): diventano `StatTile(...)` (compact di default `false`, nessun cambio visibile).

Le struct `StatCard` e `CStat` vengono rimosse (non deprecate/lasciate come alias — nessun altro call site le usa oltre a quelli elencati, verificato con grep in fase di brainstorming).

### 3. `GroupBoxStyle` custom per `ToolsSheet`

```swift
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            configuration.label
            configuration.content
        }
        .padding(AppSpacing.md)
        .cardBackground()
    }
}
```

Applicato con `.groupBoxStyle(CardGroupBoxStyle())` — a livello di `ToolsSheet` (una sola applicazione che si propaga a tutti e 4 i `GroupBox` interni, se supportato dall'ereditarietà dell'environment di SwiftUI — altrimenti applicato singolarmente a ciascuno dei 4, da verificare in fase di piano). Nessun cambio al contenuto interno dei 4 blocchi (`GroupBox("Cartelle Configurate") { ... }` ecc.) — cambia solo la resa visiva del contenitore.

## Testing

Nessuna nuova logica di business — solo refactor di view/modificatori. Nessun nuovo XCTest sensato (stesso ragionamento delle fasi precedenti). Suite esistente (79 test) va rieseguita dopo ogni task. **Verifica manuale richiesta**: aprire l'app, controllare che `StatsPanel` (durante un job, o quantomeno via ispezione visiva della UI idle) e `CompletionSheet` (a fine job) abbiano esattamente lo stesso aspetto di prima; aprire Tools/Diagnostica e controllare che i 4 `GroupBox` abbiano ora lo stesso linguaggio visivo (sfondo/corner radius) delle altre card dell'app, senza aver perso le rispettive label.

## Fuori scope

- Nessun cambio ai design token di Fase 1.
- Nessun cambio strutturale a `NavigationSplitView`/Liquid Glass (Fase 2, già fatta).
- Nessuna micro-interazione (`onHover`, `contentTransition`, `symbolEffect`, skeleton) — Fase 4.
- Nessuna migrazione `NSAlert`→SwiftUI `.alert` — Fase 5.
- Nessun nuovo componente oltre ai 3 elencati (`.cardBackground()`, `StatTile`, `CardGroupBoxStyle`).
