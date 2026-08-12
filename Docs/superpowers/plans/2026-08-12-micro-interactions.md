# Fase 4 — Micro-interazioni (roadmap #24) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere hover feedback alle righe cliccabili, transizioni animate ai numeri che cambiano, e una transizione morph all'icona di stato — nessun cambio a design token/componenti/logica di business.

**Architecture:** Nessun nuovo file, nessun nuovo componente condiviso. Ogni riga cliccabile guadagna il proprio stato di hover locale (`@State` sulla struct se è una view indipendente, o uno `@State` condiviso su `RestoreView` per le righe che sono funzioni/proprietà interne, non struct a sé). I numeri e l'icona di stato guadagnano modificatori SwiftUI nativi (`contentTransition`, `symbolEffect`), nessuna nuova logica di calcolo.

**Tech Stack:** SwiftUI. Nessuna nuova dipendenza.

## Global Constraints

- Nessun nuovo file `.swift` — tutto dentro `AppBackupFoto/ContentView.swift`.
- Nessun cambio ai design token/componenti di Fase 1-3 (`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize`, `.cardBackground()`, `StatTile`, `CardGroupBoxStyle`) — riusati così come sono.
- Nessun cambio al comportamento di click/azione esistente — solo un layer di feedback visivo aggiuntivo su hover, transizioni sui numeri/icone, mai una modifica alla logica.
- **Correzione rispetto alla spec approvata**: la spec (`Docs/superpowers/specs/2026-08-12-micro-interactions-design.md`) elencava `LocationRow` tra le righe da dotare di hover — verificato durante la scrittura di questo piano che `LocationRow` **non** è in realtà una riga "cliccabile a tutta larghezza" in stile `buttonStyle(.plain)`: è un `HStack` con un `Button(...).buttonStyle(.bordered)` solo sul lato destro (già con hover nativo di sistema, essendo un bottone standard). Applicare un tint hover a tutta la riga sarebbe fuorviante (implicherebbe che l'intera riga sia cliccabile quando non lo è). `LocationRow` è quindi **esclusa** da questo piano. Al suo posto, `restoreSourceRow` (funzione privata di `RestoreView`, anch'essa un'intera riga `Button.buttonStyle(.plain)`, già descritta genericamente dalla spec come "riga cliccabile del wizard Ripristina") è inclusa esplicitamente.
- Ogni task termina con build (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`, atteso `** BUILD SUCCEEDED **`) e test (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test`, attesi tutti verdi — se un test fallisce con un timeout ambientale tipo "test runner hung before establishing connection", è un flake noto, riprova una volta) prima del commit. Nessun nuovo XCTest sensato in questa fase (solo styling/animazioni, stesso ragionamento delle fasi precedenti).
- I numeri di riga sotto sono verificati al momento della scrittura di questo piano (2026-08-12, dopo la chiusura di Fase 1-3) — possono slittare da un task al successivo. Localizza sempre il contenuto reale con grep/ricerca testuale prima di ogni edit; se il contenuto reale differisce sostanzialmente da quanto mostrato, fermati e segnala invece di procedere alla cieca.

---

### Task 1: Hover su `HamburgerRow`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `HamburgerRow`, oggi riga ~3327-3368 — verifica con `grep -n "struct HamburgerRow"`)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia — solo hover interno alla struct.

- [ ] **Step 1: Verifica il contenuto attuale**

```bash
grep -n "struct HamburgerRow" -A 42 AppBackupFoto/ContentView.swift
```

Contenuto atteso (verifica che coincida, salvo numeri di riga):
```swift
struct HamburgerRow: View {
    let icon: String
    let label: String
    let iconColor: Color
    var badge: String? = nil
    var alert: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(label)
                    .font(AppFont.body)
                    .foregroundStyle(Color.primary)

                Spacer()

                if alert {
                    Circle().fill(AppColor.error).frame(width: 7, height: 7)
                }
                if let badge {
                    Text(badge)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

Se differisce sostanzialmente, fermati e segnala.

- [ ] **Step 2: Aggiungi hover state e tint di sfondo**

Sostituisci l'intera struct con:
```swift
struct HamburgerRow: View {
    let icon: String
    let label: String
    let iconColor: Color
    var badge: String? = nil
    var alert: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(label)
                    .font(AppFont.body)
                    .foregroundStyle(Color.primary)

                Spacer()

                if alert {
                    Circle().fill(AppColor.error).frame(width: 7, height: 7)
                }
                if let badge {
                    Text(badge)
                        .font(AppFont.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isHovering ? 0.05 : 0))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovering = hovering }
        }
    }
}
```

(unica differenza: `@State private var isHovering = false` aggiunto, `.background(Color.primary.opacity(isHovering ? 0.05 : 0))` aggiunto dentro il `Button`'s label prima della sua chiusura, e `.onHover { ... }` aggiunto dopo `.buttonStyle(.plain)`)

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add hover feedback to HamburgerRow (roadmap #24)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Hover su `OpsButton`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `OpsButton`, oggi riga ~3151-3183 — verifica con `grep -n "struct OpsButton"`)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia.

**Nota di scope**: `OpsButton` ha 2 bottoni interni — il bottone principale (titolo+sottotitolo, azione primaria) e il bottone "occhio" per l'anteprima (`onPreview`, opzionale). Solo il bottone principale guadagna hover in questo task — il bottone anteprima resta invariato (elemento più piccolo, meno centrale, fuori scope della spec che parla di "righe cliccabili" al plurale riferendosi alle righe principali, non ai controlli secondari annidati).

- [ ] **Step 1: Verifica il contenuto attuale**

```bash
grep -n "struct OpsButton" -A 32 AppBackupFoto/ContentView.swift
```

Contenuto atteso (verifica che coincida):
```swift
struct OpsButton: View {
    let title: String; let subtitle: String; let icon: String
    let color: Color; let enabled: Bool; let action: () -> Void
    var onPreview: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: icon).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(enabled ? color : Color.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(title).font(AppFont.body)
                            .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        Text(subtitle).font(AppFont.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            if let onPreview {
                Button(action: onPreview) {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                        .padding(.trailing, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help("Anteprima: mostra quanti file verranno copiati senza avviare il backup")
            }
        }
    }
}
```

- [ ] **Step 2: Aggiungi hover state al bottone principale**

Sostituisci l'intera struct con:
```swift
struct OpsButton: View {
    let title: String; let subtitle: String; let icon: String
    let color: Color; let enabled: Bool; let action: () -> Void
    var onPreview: (() -> Void)? = nil
    @State private var isHovering = false
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: icon).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(enabled ? color : Color.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(title).font(AppFont.body)
                            .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        Text(subtitle).font(AppFont.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                .background(Color.primary.opacity(isHovering && enabled ? 0.05 : 0))
            }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) { isHovering = hovering }
            }
            if let onPreview {
                Button(action: onPreview) {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                        .padding(.trailing, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help("Anteprima: mostra quanti file verranno copiati senza avviare il backup")
            }
        }
    }
}
```

(`isHovering && enabled` evita il tint quando il bottone è disabilitato — coerente con l'opacità ridotta già applicata in quel caso; il bottone "occhio" resta invariato)

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add hover feedback to OpsButton main action (roadmap #24)

Solo il bottone principale (titolo+sottotitolo) guadagna hover —
il bottone "occhio" di anteprima resta invariato, controllo
secondario più piccolo fuori dallo scope delle "righe cliccabili"
della spec.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Hover sulle righe del wizard Ripristina

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `RestoreView`, oggi riga ~2532 — verifica con `grep -n "struct RestoreView"`; funzione `restoreSourceRow` riga ~2589, proprietà `s3SourceRow` riga ~2621, proprietà `chooseFoldersStep` riga ~2685)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia.

**Nota tecnica**: a differenza di `HamburgerRow`/`OpsButton` (struct `View` indipendenti), `restoreSourceRow`/`s3SourceRow`/`chooseFoldersStep` sono funzioni/proprietà calcolate **dentro** `RestoreView` — non possono avere un proprio `@State` locale (lo stato appartiene sempre alla struct `View` che lo dichiara, non a un frammento di view restituito da una funzione). Usiamo quindi un solo `@State` condiviso su `RestoreView`, con un identificatore stringa per distinguere quale riga è sotto hover in un dato momento.

- [ ] **Step 1: Verifica `RestoreView` e le 3 zone da modificare**

```bash
grep -n "struct RestoreView" -A 10 AppBackupFoto/ContentView.swift
grep -n "private func restoreSourceRow" -A 20 AppBackupFoto/ContentView.swift
grep -n "private var s3SourceRow" -A 20 AppBackupFoto/ContentView.swift
grep -n "private var chooseFoldersStep" -A 15 AppBackupFoto/ContentView.swift
```

Conferma che `restoreSourceRow` sia un `Button { ... } label: { HStack { ... } }.buttonStyle(.plain)`, che il ramo `.available` di `s3SourceRow` sia analogamente un `Button`, e che `chooseFoldersStep` contenga un `ForEach` su `folder: String` con un `Button { ... }.buttonStyle(.plain)` per riga. Se la struttura reale differisce sostanzialmente, fermati e segnala.

- [ ] **Step 2: Aggiungi lo `@State` condiviso a `RestoreView`**

Trova la dichiarazione delle proprietà `@State` esistenti di `RestoreView` (subito dopo `struct RestoreView: View {`) e aggiungi:
```swift
    @State private var hoveredRow: String? = nil
```
(una riga in più tra le altre `@State` esistenti — non toccare le altre proprietà)

- [ ] **Step 3: Applica hover a `restoreSourceRow`**

Nel `label:` del `Button` dentro `restoreSourceRow` (l'`HStack` col contenuto della riga, prima di `.padding(AppSpacing.md).cardBackground()`), aggiungi un `.background(...)` condizionato dall'identificatore univoco della riga (usa `source.rawValue` o una stringa che distingua `.ssd`/`.hdd` — verifica con `grep -n "enum RestoreSource"` quale proprietà usare per un identificatore stringa stabile; se `RestoreSource` non ha già un `rawValue` String, usa `"\(source)"` che su un enum Swift produce comunque una stringa stabile per case):

```swift
                }
                .padding(AppSpacing.md).cardBackground()
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                        .fill(Color.primary.opacity(hoveredRow == "\(source)" ? 0.05 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { hoveredRow = hovering ? "\(source)" : nil }
        }
```

(applica questo pattern esatto — `.overlay` con `RoundedRectangle` invece di un semplice `.background`, così il tint rispetta gli angoli arrotondati di `.cardBackground()` invece di formare un rettangolo squadrato sopra una card arrotondata — subito dopo `.padding(AppSpacing.md).cardBackground()`, e `.onHover` subito dopo `.buttonStyle(.plain)`. Adatta l'indentazione esatta al contesto reale del file.)

- [ ] **Step 4: Applica hover al ramo `.available` di `s3SourceRow`**

Stesso pattern, identificatore `"s3"` invece di `"\(source)"`:
```swift
                .padding(AppSpacing.md).cardBackground()
                .overlay(
                    RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                        .fill(Color.primary.opacity(hoveredRow == "s3" ? 0.05 : 0))
                )
                }.buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) { hoveredRow = hovering ? "s3" : nil }
                }
```

(adatta l'indentazione/posizionamento esatto delle graffe al contenuto reale — il principio è lo stesso overlay+onHover del Task precedente, applicato solo al ramo `.available`, non ai rami `.checking`/`.unavailable` che non sono cliccabili)

- [ ] **Step 5: Applica hover alle righe di `chooseFoldersStep`**

Nel `Button { ... }.buttonStyle(.plain)` dentro il `ForEach` di `chooseFoldersStep`, usa il valore `folder: String` stesso (già univoco, è la chiave del `ForEach`) come identificatore:
```swift
                            .padding(AppSpacing.md).cardBackground()
                            .overlay(
                                RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                                    .fill(Color.primary.opacity(hoveredRow == folder ? 0.05 : 0))
                            )
                        }.buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.1)) { hoveredRow = hovering ? folder : nil }
                        }
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Se `RestoreSource` non espone una rappresentazione stringa stabile per `"\(source)"` (es. se è una struct complessa invece di un semplice enum), il compilatore comunque produce QUALCHE stringa per l'interpolazione di default — non bloccante per la compilazione, ma se visivamente l'hover non si comporta bene per via di collisioni di identificatore, usa invece un identificatore esplicito come `source == .ssd ? "ssd" : "hdd"`.

- [ ] **Step 7: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 8: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add hover feedback to RestoreView wizard rows (roadmap #24)

restoreSourceRow, s3SourceRow (ramo .available), e le righe di
chooseFoldersStep guadagnano un tint hover — condividono un solo
@State private var hoveredRow: String? su RestoreView, dato che
sono funzioni/proprietà calcolate (non struct View indipendenti)
e non possono avere @State proprio.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `contentTransition(.numericText())` sui numeri

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `StatTile` oggi riga ~3042; struct `StatsPanel` oggi riga ~3421-3453 — verifica con `grep -n "struct StatTile\|struct StatsPanel"`)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica `StatTile` e `StatsPanel`**

```bash
grep -n "struct StatTile" -A 16 AppBackupFoto/ContentView.swift
grep -n "struct StatsPanel" -A 32 AppBackupFoto/ContentView.swift
```

- [ ] **Step 2: Applica la transizione al valore di `StatTile`**

```swift
// Prima:
            Text(value).font(AppFont.heroNumber)
                .foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
// Dopo:
            Text(value).font(AppFont.heroNumber)
                .foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
                .contentTransition(.numericText())
                .animation(.default, value: value)
```

- [ ] **Step 3: Applica la transizione a percentuale e velocità in `StatsPanel`**

```swift
// Prima:
                    Text("\(stats.percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
// Dopo:
                    Text("\(stats.percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: stats.percent)
```

```swift
// Prima:
                    Text("velocita \(stats.speed)").font(AppFont.caption).monospacedDigit().foregroundStyle(.secondary)
// Dopo:
                    Text("velocita \(stats.speed)").font(AppFont.caption).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: stats.speed)
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

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add numericText content transition to counters (roadmap #24)

StatTile.value, percentuale e velocità in StatsPanel animano il
cambio cifre invece di aggiornarsi istantaneamente.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `symbolEffect` sull'icona di stato in `PhaseIndicator`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `PhaseIndicator`, oggi riga ~3371-3385 — verifica con `grep -n "struct PhaseIndicator"`)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica il contenuto attuale**

```bash
grep -n "struct PhaseIndicator" -A 14 AppBackupFoto/ContentView.swift
```

Contenuto atteso:
```swift
struct PhaseIndicator: View {
    let phase: JobPhase; let percent: Int
    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if case .running = phase {
                ProgressView().controlSize(.small)
                Text(percent >= 100 ? "Finalizzando..." : phase.label)
                    .font(AppFont.body).foregroundStyle(phase.color)
            } else {
                Image(systemName: phase.icon).foregroundStyle(phase.color)
                Text(phase.label).font(AppFont.body).foregroundStyle(phase.color)
            }
        }
    }
}
```

- [ ] **Step 2: Applica la transizione all'icona**

```swift
// Prima:
                Image(systemName: phase.icon).foregroundStyle(phase.color)
// Dopo:
                Image(systemName: phase.icon).foregroundStyle(phase.color)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.default, value: phase)
```

(`JobPhase` deve essere `Equatable` perché `.animation(value:)` lo richieda — verifica con `grep -n "enum JobPhase"` che sia già dichiarato `Equatable`; se non lo fosse, il compilatore lo segnalerà e va aggiunta la conformità, ma è già così nel codice esistente per via di `.onChange(of: runner.completionSnapshot?.phase)` altrove nel file che richiede la stessa conformità)

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 5: Verifica manuale visiva**

Avvia l'app (bundle in `~/Library/Developer/Xcode/DerivedData`, trova con `find ~/Library/Developer/Xcode/DerivedData -iname "AppBackupFoto.app" -maxdepth 6`), controlla che l'app si avvii senza crash e che l'icona di stato "Pronto" sia visibile normalmente (la transizione si vede solo con un cambio di fase reale, non verificabile staticamente — un controllo "non è rotto nulla" è sufficiente qui). Chiudi l'app dopo la verifica.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add symbolEffect transition to PhaseIndicator icon (roadmap #24)

L'icona di stato (idle/successo/errore) fa un morph invece di un
cambio istantaneo quando la fase cambia. Il caso "running" non è
toccato (mostra uno spinner, non l'icona).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Aggiornare la documentazione e chiudere roadmap #24

**Files:**
- Modify: `Docs/ROADMAP.md`
- Modify: `.claude/rules/architecture.md`

**Interfaces:** nessuna — task di documentazione, chiude la Fase 4.

- [ ] **Step 1: In `.claude/rules/architecture.md`, aggiungi una nota sulle micro-interazioni**

Trova il paragrafo "**Componenti unificati (2026-08-12, roadmap #23, Fase 3)**" e aggiungi subito dopo:

```markdown

**Micro-interazioni (2026-08-12, roadmap #24, Fase 4)**: hover feedback (tint di sfondo leggero) su `HamburgerRow`, `OpsButton` (bottone principale), e le righe del wizard Ripristina (`restoreSourceRow`, `s3SourceRow`, `chooseFoldersStep` — condividono un `@State` su `RestoreView` dato che non sono struct `View` indipendenti). `contentTransition(.numericText())` su `StatTile.value` e sui contatori percentuale/velocità di `StatsPanel`. `contentTransition(.symbolEffect(.replace))` sull'icona di stato in `PhaseIndicator`. `LocationRow` esclusa deliberatamente (non è una riga cliccabile a tutta larghezza, solo il bottone interno lo è, già con hover nativo). Nessuno skeleton/`.redacted` — nessun caso reale identificato nel codice attuale.
```

- [ ] **Step 2: In `Docs/ROADMAP.md`, marca il punto 24 come fatto**

Cerca la riga:
```
24. 🔲 **Fase 4 — Micro-interazioni**: `onHover` su righe/liste, `contentTransition(.numericText())` sui contatori (MB/s, percentuali), `symbolEffect` su icone di stato, skeleton/`.redacted(reason: .placeholder)` al posto di spinner nudi.
```

Sostituisci con:
```
24. ✅ **Fatto (2026-08-12) — Fase 4, micro-interazioni.** Hover su righe cliccabili (`HamburgerRow`, `OpsButton`, wizard Ripristina), `contentTransition(.numericText())` sui contatori, `contentTransition(.symbolEffect(.replace))` sull'icona di stato. Skeleton/`.redacted` deliberatamente escluso — nessun caso reale nel codice attuale abbastanza rilevante. Vedi `Docs/superpowers/specs/2026-08-12-micro-interactions-design.md` e `Docs/superpowers/plans/2026-08-12-micro-interactions.md`.
```

- [ ] **Step 3: Commit**

```bash
git add Docs/ROADMAP.md .claude/rules/architecture.md
git commit -m "$(cat <<'EOF'
Update docs: micro-interactions (roadmap #24) shipped

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
