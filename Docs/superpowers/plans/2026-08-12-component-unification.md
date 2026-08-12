# Fase 3 — Unificazione componenti (roadmap #23) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminare la duplicazione strutturale del pattern "card" (9 occorrenze), unire `StatCard`/`CStat` in un'unica struct `StatTile`, e allineare visivamente i 4 `GroupBox` di `ToolsSheet` al resto dell'app con uno stile custom.

**Architecture:** 3 nuovi tipi Swift dentro `ContentView.swift` (`CardBackground` + `.cardBackground()`, `StatTile`, `CardGroupBoxStyle`), nessun nuovo file. Nessuna nuova view strutturale — solo consolidamento di codice esistente, stesso output visivo.

**Tech Stack:** SwiftUI. Nessuna nuova dipendenza.

## Global Constraints

- Nessun nuovo file `.swift` — tutto dentro `AppBackupFoto/ContentView.swift`.
- Nessun cambio ai design token di Fase 1 (`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize`) — riusati così come sono.
- Nessun cambio strutturale a `NavigationSplitView`/Liquid Glass (Fase 2, già fatta).
- Stesso output visivo di oggi in ogni punto toccato — questa fase è un refactor di duplicazione, non un restyling: se un task cambia la resa visiva rispetto a prima (anche di 1pt), non è quello previsto dalla spec, fermati e segnala.
- Ogni task termina con build (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`, atteso `** BUILD SUCCEEDED **`) e test (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test`, attesi tutti verdi — se un test fallisce con un timeout ambientale tipo "test runner hung before establishing connection", è un flake noto, riprova una volta) prima del commit. Nessun nuovo XCTest sensato in questa fase (solo refactor di view, stesso ragionamento delle fasi precedenti).
- I numeri di riga sotto sono verificati al momento della scrittura di questo piano (2026-08-12, dopo la chiusura di Fase 1 e Fase 2) — possono slittare da un task al successivo. Localizza sempre il contenuto reale con grep/ricerca testuale prima di ogni edit; se il contenuto reale differisce sostanzialmente da quanto mostrato, fermati e segnala invece di procedere alla cieca.

---

### Task 1: `.cardBackground()` — ViewModifier riusabile

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo modifier vicino agli altri design token, oggi subito dopo `enum AppIconSize` a riga ~57-60 — verifica con `grep -n "^enum AppIconSize" -A 5`; poi 7 call site: righe 2601, 2616, 2627, 2637, 2693, 2858, 3621 al momento della scrittura di questo piano — **NON** le righe 3037 e 3435, quelle sono dentro `CStat`/`StatCard` e vengono gestite nel Task 2)

**Interfaces:**
- Consumes: `AppSpacing.cardOpacity`, `AppSpacing.cardCornerRadius` (Fase 1, già esistenti).
- Produces: `View.cardBackground() -> some View`, usato dal Task 2 (`StatTile`) e dal Task 3 (`CardGroupBoxStyle`).

- [ ] **Step 1: Verifica il punto di inserimento e le 7 occorrenze da migrare**

```bash
grep -n "^enum AppIconSize" -A 5 AppBackupFoto/ContentView.swift
grep -n "\.quaternary\.opacity" AppBackupFoto/ContentView.swift
```

Atteso: `enum AppIconSize { ... }` seguito da una riga vuota e poi `// MARK: - App entry`; e 9 occorrenze totali di `.quaternary.opacity` (le stesse elencate sopra + le 2 dentro `CStat`/`StatCard`, che in questo task non tocchi). Se il conteggio o il contenuto differisce, fermati e segnala.

- [ ] **Step 2: Aggiungi `CardBackground` subito dopo `enum AppIconSize`**

```swift
/// Sfondo "card" riusato in tutta l'app: stesso corner radius/opacità ovunque.
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

- [ ] **Step 3: Sostituisci le 7 occorrenze**

Riga 2601:
```swift
// Prima:
            .padding(AppSpacing.md).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
// Dopo:
            .padding(AppSpacing.md).cardBackground()
```

Riga 2616:
```swift
// Prima:
                }.padding(AppSpacing.md).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
// Dopo:
                }.padding(AppSpacing.md).cardBackground()
```

Riga 2627:
```swift
// Prima:
                    .padding(AppSpacing.md).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
// Dopo:
                    .padding(AppSpacing.md).cardBackground()
```

Riga 2637:
```swift
// Prima:
                .padding(AppSpacing.md).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
// Dopo:
                .padding(AppSpacing.md).cardBackground()
```

Riga 2693:
```swift
// Prima:
                            .padding(AppSpacing.md).background(.quaternary.opacity(AppSpacing.cardOpacity)).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
// Dopo:
                            .padding(AppSpacing.md).cardBackground()
```

Riga 2858:
```swift
// Prima:
        .padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
// Dopo:
        .padding(12).cardBackground()
```

Riga 3621:
```swift
// Prima:
            .padding(AppSpacing.sm).background(.quaternary.opacity(AppSpacing.cardOpacity)).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
// Dopo:
            .padding(AppSpacing.sm).cardBackground()
```

Per ciascuna riga, il `.padding(...)` che precede resta esattamente com'è (valori diversi da riga a riga: `AppSpacing.md`, `12`, `AppSpacing.sm`) — sostituisci solo `.background(.quaternary.opacity(...)).clipShape(RoundedRectangle(cornerRadius: ...))` con `.cardBackground()`.

- [ ] **Step 4: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add .cardBackground() ViewModifier, migrate 7 call sites (roadmap #23)

Consolida il pattern .background(.quaternary.opacity(...)).clipShape(
RoundedRectangle(cornerRadius: ...)), oggi ripetuto 9 volte, in un
solo ViewModifier. Le 2 occorrenze dentro CStat/StatCard restano
per il Task 2 (merge in StatTile). Nessun cambio alla resa visiva.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `StatTile` — merge di `StatCard`/`CStat`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `CStat` a riga ~3029, struct `StatCard` a riga ~3427 — verifica con `grep -n "struct CStat\|struct StatCard"`; 4 call site `CStat(...)` righe ~2999-3002; 5 call site `StatCard(...)` righe ~3417-3421)

**Interfaces:**
- Consumes: `.cardBackground()` (Task 1).
- Produces: `StatTile(label: String, value: String, accent: Color, compact: Bool = false) -> View`, usato ovunque `CStat`/`StatCard` erano usati prima.

- [ ] **Step 1: Verifica `CStat` e `StatCard` e i loro call site**

```bash
grep -n "struct CStat" -A 10 AppBackupFoto/ContentView.swift
grep -n "struct StatCard" -A 10 AppBackupFoto/ContentView.swift
grep -n "CStat(\|StatCard(" AppBackupFoto/ContentView.swift
```

Contenuto atteso di `CStat`:
```swift
struct CStat: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            Text(value).font(AppFont.heroNumber).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 58).padding(.vertical, AppSpacing.sm).padding(.horizontal, 8)
        .background(.quaternary.opacity(AppSpacing.cardOpacity)).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
    }
}
```

Contenuto atteso di `StatCard`:
```swift
struct StatCard: View {
    let label: String; let value: String; let accent: Color
    var body: some View {
        VStack(spacing: AppSpacing.xs) {
            Text(value).font(AppFont.heroNumber)
                .foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, AppSpacing.sm)
        .background(.quaternary.opacity(AppSpacing.cardOpacity)).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
    }
}
```

4 call site `CStat(label: "Copiati", value: "\(stats.copied)", color: AppColor.inProgress)` / `CStat(label: "Skippati", value: "\(stats.skipped)", color: .secondary)` / `CStat(label: "Errori", value: "\(stats.errors)", color: stats.errors > 0 ? AppColor.error : .secondary)` / `CStat(label: "Durata", value: stats.elapsed, color: .secondary)`.

5 call site `StatCard(label: "Copiati", value: "\(stats.copied)", accent: AppColor.inProgress)` / `StatCard(label: "Skippati", value: "\(stats.skipped)", accent: .secondary)` / `StatCard(label: "Errori", value: "\(stats.errors)", accent: stats.errors > 0 ? AppColor.error : .secondary)` / `StatCard(label: "Trascorso", value: stats.elapsed, accent: .secondary)` / `StatCard(label: "ETA", value: stats.eta, accent: .secondary)`.

Se il contenuto reale differisce sostanzialmente da questo, fermati e segnala.

- [ ] **Step 2: Sostituisci entrambe le struct con `StatTile`**

Rimuovi interamente sia `struct CStat: View { ... }` sia `struct StatCard: View { ... }`, e al posto di **una delle due** (es. dove si trovava `CStat`) inserisci:

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

(Nota: `StatCard` non aveva `.lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)` — verifica di aver riportato ESATTAMENTE questi 3 modificatori dal contenuto reale di `StatCard` che hai letto allo Step 1: `CStat` non li aveva, ma `StatTile` unificata li applica sempre, comportamento innocuo per `CStat`/compact — dato che sono solo modificatori di visualizzazione testo che non cambiano nulla se il testo è già corto, come nel caso dei valori numerici brevi di `CStat`.)

L'altra struct (dove si trovava `StatCard`, ormai vuota) va rimossa del tutto, non lasciata come guscio vuoto.

- [ ] **Step 3: Aggiorna i 4 call site ex-`CStat` a `StatTile(..., compact: true)`**

```swift
// Prima:
                CStat(label: "Copiati",  value: "\(stats.copied)",  color: AppColor.inProgress)
                CStat(label: "Skippati", value: "\(stats.skipped)", color: .secondary)
                CStat(label: "Errori",   value: "\(stats.errors)",  color: stats.errors > 0 ? AppColor.error : .secondary)
                CStat(label: "Durata",   value: stats.elapsed,      color: .secondary)
// Dopo:
                StatTile(label: "Copiati",  value: "\(stats.copied)",  accent: AppColor.inProgress, compact: true)
                StatTile(label: "Skippati", value: "\(stats.skipped)", accent: .secondary, compact: true)
                StatTile(label: "Errori",   value: "\(stats.errors)",  accent: stats.errors > 0 ? AppColor.error : .secondary, compact: true)
                StatTile(label: "Durata",   value: stats.elapsed,      accent: .secondary, compact: true)
```

(nota: il parametro si chiamava `color:` in `CStat`, diventa `accent:` in `StatTile` — coerente col nome già usato da `StatCard`)

- [ ] **Step 4: Aggiorna i 5 call site ex-`StatCard` a `StatTile(...)`**

```swift
// Prima:
                StatCard(label: "Copiati",   value: "\(stats.copied)",  accent: AppColor.inProgress)
                StatCard(label: "Skippati",  value: "\(stats.skipped)", accent: .secondary)
                StatCard(label: "Errori",    value: "\(stats.errors)",  accent: stats.errors > 0 ? AppColor.error : .secondary)
                StatCard(label: "Trascorso", value: stats.elapsed,      accent: .secondary)
                StatCard(label: "ETA",       value: stats.eta,           accent: .secondary)
// Dopo:
                StatTile(label: "Copiati",   value: "\(stats.copied)",  accent: AppColor.inProgress)
                StatTile(label: "Skippati",  value: "\(stats.skipped)", accent: .secondary)
                StatTile(label: "Errori",    value: "\(stats.errors)",  accent: stats.errors > 0 ? AppColor.error : .secondary)
                StatTile(label: "Trascorso", value: stats.elapsed,      accent: .secondary)
                StatTile(label: "ETA",       value: stats.eta,           accent: .secondary)
```

(solo il nome del tipo cambia da `StatCard` a `StatTile`, nessun parametro — `compact` resta al suo default `false`, stesso comportamento visivo di prima)

- [ ] **Step 5: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Se il compilatore segnala un conflitto di overload o un tipo mancante, verifica di aver rimosso ENTRAMBE le vecchie struct (nessun residuo di `CStat`/`StatCard` da qualche parte).

- [ ] **Step 6: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 7: Verifica manuale visiva**

Avvia l'app (bundle in `~/Library/Developer/Xcode/DerivedData`, trova con `find ~/Library/Developer/Xcode/DerivedData -iname "AppBackupFoto.app" -maxdepth 6`), controlla che `StatsPanel` (visibile durante un job, o quantomeno che l'app compili e non crashi all'avvio) e `CompletionSheet` non abbiano subito cambi visivi imprevisti rispetto a prima — se non riesci a innescare un job reale, uno screenshot dell'app idle è comunque utile per confermare che nessun crash/layout rotto sia stato introdotto. Chiudi l'app dopo la verifica.

- [ ] **Step 8: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Merge StatCard/CStat into StatTile (roadmap #23)

Le due struct erano identiche salvo il frame (CStat: larghezza
fissa ~58pt per la riga compatta di CompletionSheet; StatCard:
larghezza flessibile per StatsPanel) — unificate in StatTile con
un parametro compact: Bool, default false (comportamento StatCard).
Stesso output visivo in entrambi i contesti, 9 call site aggiornati.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `CardGroupBoxStyle` per `ToolsSheet`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (nuovo stile vicino a `CardBackground`/`StatTile`; struct `ToolsSheet` oggi a riga ~3630 — verifica con `grep -n "struct ToolsSheet"`; 4 `GroupBox` a righe ~3673/3691/3762/3769)

**Interfaces:**
- Consumes: `.cardBackground()` (Task 1).
- Produces: nessuna nuova interfaccia — chiude la fase.

- [ ] **Step 1: Verifica `ToolsSheet` e i 4 `GroupBox`**

```bash
grep -n "struct ToolsSheet" AppBackupFoto/ContentView.swift
grep -n "GroupBox(" AppBackupFoto/ContentView.swift
```

Atteso: 4 occorrenze — `GroupBox("Cartelle Configurate") {`, `GroupBox("S3 — Cubbit") {`, `GroupBox("Sync Info") {`, `GroupBox("Revisione") {`, tutte dentro `ToolsSheet`. Se il conteggio differisce, fermati e segnala.

- [ ] **Step 2: Aggiungi `CardGroupBoxStyle` subito dopo la definizione di `StatTile` (Task 2)**

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

- [ ] **Step 3: Verifica se `.groupBoxStyle()` applicato una volta sola su `ToolsSheet.body` si propaga a tutti e 4**

```bash
grep -n "struct ToolsSheet" -A 15 AppBackupFoto/ContentView.swift
```

Trova la riga di apertura del `body` principale di `ToolsSheet` (es. `var body: some View {` seguito dal contenitore più esterno, tipicamente uno `ScrollView`/`VStack`/`Form`). Applica `.groupBoxStyle(CardGroupBoxStyle())` come modificatore su quel contenitore più esterno (non su ciascun `GroupBox` singolarmente) — in SwiftUI `.groupBoxStyle()` è un modificatore di environment, si propaga automaticamente a tutti i `GroupBox` discendenti nella gerarchia della view, quindi un'unica applicazione al contenitore radice del `body` basta per tutti e 4.

Esempio (adatta al contenitore reale che trovi — non inventare una struttura diversa da quella effettiva):
```swift
// Prima (esempio):
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // ... contenuto con i 4 GroupBox ...
            }
        }
    }
// Dopo (esempio):
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // ... contenuto con i 4 GroupBox, invariato ...
            }
        }
        .groupBoxStyle(CardGroupBoxStyle())
    }
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 6: Verifica manuale visiva**

Avvia l'app, apri hamburger → Tools (finestra "Diagnostica"), controlla che i 4 blocchi (Cartelle Configurate, S3 — Cubbit, Sync Info, Revisione) abbiano ora lo stesso sfondo/corner-radius delle altre card dell'app (non più il bordo/chrome nativo di sistema di `GroupBox`), e che le rispettive label siano ancora visibili e leggibili. Cattura uno screenshot per conferma, poi chiudi la finestra Diagnostica e l'app.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Apply CardGroupBoxStyle to ToolsSheet's 4 GroupBox (roadmap #23)

Allinea il linguaggio visivo dei GroupBox nativi (Cartelle
Configurate, S3 — Cubbit, Sync Info, Revisione) alle card usate nel
resto dell'app, riusando .cardBackground() — un solo
.groupBoxStyle(CardGroupBoxStyle()) sul contenitore radice del body
si propaga a tutti e 4, nessun cambio al contenuto interno di
ciascun blocco.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Aggiornare la documentazione e chiudere roadmap #23

**Files:**
- Modify: `Docs/ROADMAP.md`
- Modify: `.claude/rules/architecture.md`

**Interfaces:** nessuna — task di documentazione, chiude la Fase 3.

- [ ] **Step 1: In `.claude/rules/architecture.md`, aggiungi una nota sui 3 componenti unificati**

Trova la sottosezione `### Design Tokens (2026-08-12, roadmap #21, Fase 1)` (aggiunta a Fase 1) e aggiungi subito dopo il suo paragrafo:

```markdown

**Componenti unificati (2026-08-12, roadmap #23, Fase 3)**: `.cardBackground()` (ViewModifier) consolida le 9 occorrenze del pattern card in un solo punto. `StatCard`/`CStat` (duplicati, differivano solo per `frame`) uniti in `StatTile` con parametro `compact: Bool`. I 4 `GroupBox` di `ToolsSheet` usano `CardGroupBoxStyle` (applicato una volta sul contenitore radice del `body`, si propaga via environment) per lo stesso linguaggio visivo delle altre card — nessun cambio al contenuto interno dei blocchi. Nessuna resa visiva diversa da prima in nessuno dei tre casi, solo consolidamento di codice duplicato.
```

- [ ] **Step 2: In `Docs/ROADMAP.md`, marca il punto 23 come fatto**

Cerca la riga:
```
23. 🔲 **Fase 3 — Componenti**: sistema card unificato (padding/opacità/corner radius coerenti), merge `StatCard`/`CStat` duplicati, `GroupBox` vs card manuali allineati.
```

Sostituisci con:
```
23. ✅ **Fatto (2026-08-12) — Fase 3, unificazione componenti.** `.cardBackground()` consolida le 9 occorrenze del pattern card; `StatCard`/`CStat` uniti in `StatTile` (parametro `compact: Bool`); i 4 `GroupBox` di `ToolsSheet` allineati al resto dell'app con `CardGroupBoxStyle`. Nessun cambio alla resa visiva, solo consolidamento. Vedi `Docs/superpowers/specs/2026-08-12-component-unification-design.md` e `Docs/superpowers/plans/2026-08-12-component-unification.md`.
```

- [ ] **Step 3: Commit**

```bash
git add Docs/ROADMAP.md .claude/rules/architecture.md
git commit -m "$(cat <<'EOF'
Update docs: component unification (roadmap #23) shipped

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
