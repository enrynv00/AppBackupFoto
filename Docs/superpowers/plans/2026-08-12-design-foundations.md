# Fase 1 — Fondamenta design (roadmap #21) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introdurre 4 enum di design token (`AppColor`, `AppSpacing`, `AppFont`, `AppIconSize`) in `AppBackupFoto/ContentView.swift` e migrare tutti i valori hardcoded esistenti (colori/font/spacing/padding/corner-radius/opacity del pattern "card") verso questi token, senza toccare la struttura delle view.

**Architecture:** 4 nuovi enum con sole `static let`, inseriti in una nuova sezione `// MARK: - Design Tokens` subito dopo gli import, prima di `UpdaterViewModel`. Ogni task successivo migra una categoria di valori (colori di stato, colori destinazione, tipografia, spacing, padding, card) sostituendo l'occorrenza hardcoded con il token corrispondente — nessun nuovo componente condiviso, nessun refactor strutturale.

**Tech Stack:** SwiftUI, nessuna nuova dipendenza.

## Global Constraints

- Nessun nuovo file `.swift` — tutto dentro `AppBackupFoto/ContentView.swift`, per convenzione esplicita del progetto.
- Nessun cambio strutturale alle view (niente `NavigationSplitView`, niente materials, niente merge di `StatCard`/`CStat`) — solo valori. Quello è fuori scope, fasi successive (roadmap #22-25).
- Accent color: resta il default di sistema, nessuna modifica.
- Ogni task termina con build (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`, atteso `** BUILD SUCCEEDED **`) e test (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test`, attesi tutti verdi) prima del commit. Nessun nuovo XCTest sensato in questa fase (solo valori statici/styling, stesso ragionamento già applicato a #11/#15/#16/#20).
- I numeri di riga sotto sono verificati al momento della scrittura di questo piano (2026-08-12) — dato che i task successivi modificano il file, i numeri **slittano da un task al successivo**: ogni step chiede di rilocalizzare il contenuto con `grep`/ricerca testuale sul contenuto esatto mostrato, non di fidarsi ciecamente del numero di riga. Se il contenuto reale a quella riga non corrisponde a quanto mostrato, fermati e segnala la differenza invece di procedere alla cieca (stessa regola già seguita nel piano di roadmap #20).

---

### Task 1: Aggiungere i 4 enum di design token

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (subito dopo gli `import`, riga ~9-10 — verifica con `grep -n "^import Sparkle"`)

**Interfaces:**
- Consumes: nessuna.
- Produces: `AppColor.{success,error,warning,inProgress,macToSSD,ssdToHDD,ssdToCubbit,utility}: Color`, `AppSpacing.{xs,sm,md,lg,xl,xxl}: CGFloat`, `AppSpacing.{cardCornerRadius: CGFloat, cardOpacity: Double}`, `AppFont.{title,sectionHeader,body,caption,heroNumber}: Font`, `AppIconSize.{heroSmall,heroLarge}: CGFloat` — usati da tutti i task successivi.

- [ ] **Step 1: Verifica il punto di inserimento**

```bash
grep -n "^import Sparkle" AppBackupFoto/ContentView.swift
grep -n "// MARK: - App entry" AppBackupFoto/ContentView.swift
```

Atteso: `import Sparkle` all'ultima riga degli import (riga 9), seguita da una riga vuota e poi `// MARK: - App entry` (riga 11). Se differisce, fermati e segnala.

- [ ] **Step 2: Inserisci i 4 enum subito prima di `// MARK: - App entry`**

```swift
// MARK: - Design Tokens

/// Palette semantica: ogni colore ha un solo significato in tutta l'app.
/// Stato (successo/errore/warning/in corso) e identità di destinazione (Mac→SSD/SSD→HDD/SSD→Cubbit)
/// non si sovrappongono mai — vedi Docs/superpowers/specs/2026-08-12-design-foundations-design.md.
enum AppColor {
    // Stato
    static let success = Color.green
    static let error = Color.red
    static let warning = Color.orange
    /// Job in corso o conteggio "positivo" generico (es. "Copiati") — usa l'accent di sistema
    /// invece di un colore hardcoded, così segue l'accent scelto dall'utente in Preferenze di Sistema.
    static let inProgress = Color.accentColor

    // Identità destinazione — un hue per destinazione, riusato SOLO per quella destinazione.
    static let macToSSD = Color.blue
    static let ssdToHDD = Color.teal
    static let ssdToCubbit = Color.purple

    // Utility (Tools, Configurazione) — nessuna destinazione, nessuno stato.
    static let utility = Color(NSColor.systemGray)
}

/// Griglia di spacing/padding a 6 valori (base 4pt) + valori del pattern "card".
enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    static let cardCornerRadius: CGFloat = 8
    static let cardOpacity: Double = 0.4
}

/// 5 ruoli di testo con nome — una sola combinazione size/weight per ruolo, riusata ovunque.
enum AppFont {
    static let title = Font.title2.weight(.semibold)
    static let sectionHeader = Font.system(size: 10, weight: .semibold)
    static let body = Font.system(size: 13, weight: .medium)
    static let caption = Font.caption
    static let heroNumber = Font.system(size: 20, weight: .semibold, design: .monospaced)
}

/// 2 taglie per le icone SF Symbols "hero" (grandi, in sheet/empty state).
enum AppIconSize {
    static let heroSmall: CGFloat = 36
    static let heroLarge: CGFloat = 48
}

```

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **` (i 4 enum non sono ancora usati da nessuno — nessun warning "unused" atteso per `static let` in un enum pubblico a livello file).

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi (nessuna logica toccata).

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add design token enums (roadmap #21, Fase 1)

AppColor/AppSpacing/AppFont/AppIconSize, non ancora usati da
nessun call site — solo le definizioni. I task successivi
migrano i valori hardcoded esistenti verso questi token.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Migrare i colori di stato (successo/errore/warning/in corso)

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (~25 righe sparse, elenco sotto)

**Interfaces:**
- Consumes: `AppColor.{success,error,warning,inProgress}` (Task 1).
- Produces: nessuna nuova interfaccia.

**Nota di scope**: `AppColor.inProgress` non era esplicitamente nella palette approvata in brainstorming (che parlava di "3 colori di stato"), ma `JobPhase.color` (riga 300-313) ha già oggi un 4° caso implicito (`.running: return .blue`) che è un vero colore di stato distinto da successo/errore/warning — lasciarlo hardcoded a `.blue` lo farebbe collidere col nuovo `AppColor.macToSSD` (Task 3). Usare l'accent di sistema invece di `.blue` hardcoded è coerente con la decisione già presa "l'accent resta quello di sistema" ed elimina la collisione. Se non sei d'accordo con questa estensione, fermati prima di procedere e chiedi conferma — non è nella spec originale alla lettera.

- [ ] **Step 1: Verifica le occorrenze**

```bash
grep -n "\.blue\b\|\.red\b\|\.green\b\|\.orange\b" AppBackupFoto/ContentView.swift | grep -v "AppColor\."
```

Confronta l'elenco con la tabella sotto — se mancano righe o ce ne sono di più rispetto a quelle elencate (perché il file è cambiato da quando questo piano è stato scritto), fermati e segnala la differenza prima di procedere.

- [ ] **Step 2: Applica le sostituzioni**

`JobPhase.color` (righe 308-313):
```swift
    var color: Color {
        switch self {
        case .idle: return .secondary; case .running: return AppColor.inProgress
        case .success: return AppColor.success; case .failed: return AppColor.error
        }
    }
```

Riga 162 — `Text(message).foregroundStyle(.red)` → `Text(message).foregroundStyle(AppColor.error)`

Riga 2704 — `Button("Interrompi") { engine.stop() }.buttonStyle(.bordered).tint(.red)` → `.tint(AppColor.error)`

Riga 2706 — `Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)` → `.foregroundStyle(AppColor.success)`

Riga 2714 — `.font(.caption).foregroundStyle(.orange)` → `.foregroundStyle(AppColor.warning)`

Riga 2718 — `Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)` → `.foregroundStyle(AppColor.warning)`

Riga 2792 — `.foregroundStyle(bm.urls[location] != nil ? .green : .secondary).font(.system(size: 18))` → `bm.urls[location] != nil ? AppColor.success : .secondary`

Riga 2837 — `}.buttonStyle(.bordered).controlSize(.small).tint(.red)` → `.tint(AppColor.error)`

Riga 2837 — `}.buttonStyle(.bordered).controlSize(.small).tint(.red)` → `.tint(AppColor.error)`

Riga 2941 — `.font(.system(size: 60)).foregroundStyle(ok ? .green : .red).symbolRenderingMode(.hierarchical)` → `ok ? AppColor.success : AppColor.error`

Riga 2947 — `CStat(label: "Errori",   value: "\(stats.errors)",  color: stats.errors > 0 ? .red : .secondary)` → `stats.errors > 0 ? AppColor.error : .secondary`

Riga 2953 — `.font(.caption).foregroundStyle(.green).multilineTextAlignment(.center)` → `.foregroundStyle(AppColor.success)`

Righe 2958, 2963, 2967 — `.font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)` (×3) → `.foregroundStyle(AppColor.warning)`

Riga 2970 — `.buttonStyle(.borderedProminent).tint(ok ? .green : .red).keyboardShortcut(.defaultAction)` → `.tint(ok ? AppColor.success : AppColor.error)`

Riga 3356 — `.tint(phase == .idle ? .secondary : (stats.errors > 0 ? .red : .blue))` → `.tint(phase == .idle ? .secondary : (stats.errors > 0 ? AppColor.error : AppColor.inProgress))`

Riga 3367 — `StatCard(label: "Errori",    value: "\(stats.errors)",  accent: stats.errors > 0 ? .red : .secondary)` → `stats.errors > 0 ? AppColor.error : .secondary`

Riga 3471 — `.foregroundStyle(Color.blue)` (linea del grafico velocità) → `.foregroundStyle(AppColor.inProgress)`

Riga 3481 — `colors: [Color.blue.opacity(0.22), Color.blue.opacity(0.0)],` → `colors: [AppColor.inProgress.opacity(0.22), AppColor.inProgress.opacity(0.0)],`

Riga 3626 — `.foregroundStyle(bm.urls[loc] != nil ? Color.green : Color.red)` → `bm.urls[loc] != nil ? AppColor.success : AppColor.error`

Riga 3631 — `.foregroundStyle(bm.urls[loc] != nil ? Color.secondary : Color.red)` → `bm.urls[loc] != nil ? Color.secondary : AppColor.error`

Riga 3705 — `systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)` → `.foregroundStyle(AppColor.warning)`

Riga 3722 — `.foregroundStyle(finding.ok ? Color.green : Color.orange)` → `finding.ok ? AppColor.success : AppColor.warning`

Riga 3736 — `.foregroundStyle(lastJob.isClean ? Color.green : Color.orange)` → `lastJob.isClean ? AppColor.success : AppColor.warning`

Riga 3774 — `.font(.caption2).foregroundStyle(.orange)` → `.foregroundStyle(AppColor.warning)`

Riga 3777 — `.font(.caption2).foregroundStyle(.green)` → `.foregroundStyle(AppColor.success)`

Riga 3780 — `.font(.caption2).foregroundStyle(.red)` → `.foregroundStyle(AppColor.error)`

Riga 2945 — `CStat(label: "Copiati",  value: "\(stats.copied)",  color: .blue)` → `color: AppColor.inProgress`

Riga 3365 — `StatCard(label: "Copiati",   value: "\(stats.copied)",  accent: .blue)` → `accent: AppColor.inProgress`

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
Migrate status colors to AppColor tokens (roadmap #21)

successo/errore/warning/in-corso ora passano da AppColor invece
di .green/.red/.orange/.blue hardcoded sparsi. AppColor.inProgress
usa l'accent di sistema invece di .blue hardcoded, eliminando la
collisione con AppColor.macToSSD introdotto nel prossimo task.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Migrare i colori identità-destinazione e il colore utility

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (righe elencate sotto, area `OpsButton`/`VolumeRow`/`HamburgerRow`)

**Interfaces:**
- Consumes: `AppColor.{macToSSD,ssdToHDD,ssdToCubbit,utility}` (Task 1).
- Produces: nessuna nuova interfaccia.

**Nota di scope**: `HamburgerRow` ha 8 call site con 8 colori diversi (Report Log blu, Ripristina verde, Configurazione grigio, Tools viola, Catalogo indigo, Controlla aggiornamenti ciano, Aspetto arancione, Lingua teal) — l'audit li aveva segnalati come "senza semantica" (priorità Medio, non Alto). La spec approvata risolve **solo** il conflitto viola (Tools vs Cubbit S3) esplicitamente citato nel design; gli altri 6 colori di riga (Report Log/Ripristina/Catalogo/Controlla aggiornamenti/Aspetto/Lingua) restano fuori scope in questa fase — non fanno parte della palette a 7 token approvata e cambiarli sarebbe uno scope creep rispetto a quanto discusso in brainstorming. Tocchiamo solo Configurazione (già corretto, diventa solo un token) e Tools (il conflitto reale).

- [ ] **Step 1: Verifica le occorrenze**

```bash
grep -n "OpsButton(title:\|color: \.blue\|color: \.teal\|color: \.purple\|Color\.purple\|iconColor: \.purple\|NSColor\.systemGray" AppBackupFoto/ContentView.swift
```

Confronta con la tabella sotto — se differisce, fermati e segnala.

- [ ] **Step 2: Applica le sostituzioni**

Righe 3025-3039 (`OpsButton` per le 3 operazioni):
```swift
                OpsButton(title: "MAC -> SSD", subtitle: "Photos originals → SSD",
                          icon: "photo.on.rectangle.angled", color: AppColor.macToSSD,
                          enabled: !runner.isRunning && volumes.ssdMounted,
                          action: { runner.runMacToSSD() },
                          onPreview: { runner.previewMacToSSD() })
                OpsButton(title: "SSD -> HDD", subtitle: "Mirror locale (deep ogni 30gg)",
                          icon: "externaldrive.badge.plus", color: AppColor.ssdToHDD,
                          enabled: !runner.isRunning && volumes.ssdMounted && volumes.hddMounted,
                          action: { runner.runSSDToHDD() },
                          onPreview: { runner.previewSSDToHDD() })
                OpsButton(title: "SSD -> Cubbit S3", subtitle: "Cloud backup nativo Swift",
                          icon: "icloud.and.arrow.up", color: AppColor.ssdToCubbit,
                          enabled: !runner.isRunning && volumes.ssdMounted,
                          action: { runner.runSyncS3() },
                          onPreview: { runner.previewSyncS3() })
```

Righe 3061 e 3065 (`VolumeRow`, mischia identità Cubbit + stato "mounted"):
```swift
            Image(systemName: icon).font(.system(size: 13))
                .foregroundStyle(mounted ? (alwaysOn ? AppColor.ssdToCubbit : Color.primary) : Color.secondary.opacity(0.4))
                .frame(width: 20)
            Text(name).font(.system(size: 13)).foregroundStyle(mounted ? Color.primary : Color.secondary)
            Spacer()
            Circle().fill(mounted ? (alwaysOn ? AppColor.ssdToCubbit : AppColor.success) : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
```

Riga 3165 (`HamburgerRow` "Configurazione") — `HamburgerRow(icon: "gearshape.fill", label: "Configurazione", iconColor: Color(NSColor.systemGray)) {` → `iconColor: AppColor.utility) {`

Riga 3168 (`HamburgerRow` "Tools") — `HamburgerRow(icon: "wrench.and.screwdriver.fill", label: "Tools", iconColor: .purple,` → `iconColor: AppColor.utility,`

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
Migrate destination/utility colors to AppColor tokens (roadmap #21)

Mac→SSD/SSD→HDD/SSD→Cubbit ora usano AppColor.macToSSD/.ssdToHDD/
.ssdToCubbit invece di .blue/.teal/.purple hardcoded. Il viola di
Tools (che collideva con l'identità Cubbit S3) diventa
AppColor.utility (grigio) — libera il viola per il solo significato
"Cubbit S3" in tutta l'app.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Tipografia — ruolo Titolo e Intestazione sezione

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (11 righe titolo + `HamburgerSectionLabel` + 2 righe `SidebarView`)

**Interfaces:**
- Consumes: `AppFont.{title,sectionHeader}` (Task 1).
- Produces: nessuna nuova interfaccia.

**Nota di scope — Intestazione sezione**: esistono oggi due trattamenti diversi per lo stesso ruolo logico ("etichetta di sezione in un pannello laterale"): `HamburgerSectionLabel` (righe 3236-3245: 10pt semibold, MAIUSCOLO) usato in `HamburgerPanel`, e uno stile inline in `SidebarView` (righe 3014-3015, 3022-3023: `.caption`/12pt medium, non maiuscolo). Decisione presa in fase di piano: unificare sullo stile di `HamburgerSectionLabel`, che è già un componente riusabile — riusarlo dentro `SidebarView` al posto della Text inline è un cambio di valore (stessa resa visiva ovunque), non l'introduzione di una nuova astrazione (il componente esiste già).

**Nota di scope — riga 3006**: `Text("Backup Foto")` in `SidebarView` usa già `.font(.title2).fontWeight(.semibold)` ma è il branding persistente della sidebar, non un titolo di sheet dismissibile. La includiamo comunque nel ruolo Titolo (stessa resa visiva, nessun impatto) per coerenza totale — puoi escluderla se preferisci lasciarla come caso a parte, ma non richiede alcuna modifica visiva in nessuno dei due casi dato che il valore risultante è identico a quello attuale.

- [ ] **Step 1: Verifica le occorrenze del ruolo Titolo**

```bash
grep -n "\.font(\.title2)\.fontWeight(\.semibold)\|\.font(\.title3)\.fontWeight(\.semibold)" AppBackupFoto/ContentView.swift
```

Atteso: 10 righe `.title2` (141, 2508, 2625, 2661, 2766, 2917, 2942, 3006, 3548, 3619) + 1 riga `.title3` (2707). Se differisce, fermati e segnala.

- [ ] **Step 2: Sostituisci tutte le 11 occorrenze**

In ciascuna delle 11 righe, sostituisci `.font(.title2).fontWeight(.semibold)` (o `.font(.title3).fontWeight(.semibold)` per la riga 2707) con `.font(AppFont.title)`. Esempio (riga 2508):

```swift
                Text("Da dove vuoi ripristinare?").font(AppFont.title)
```

Applica lo stesso pattern (rimpiazzare i due modificatori con `.font(AppFont.title)`) a tutte le righe: 141, 2508, 2625, 2661, 2766, 2707 (che oggi è `.title3`, diventa lo stesso `AppFont.title`), 2917, 2942, 3006, 3548, 3619.

- [ ] **Step 3: Verifica `HamburgerSectionLabel` e aggiornala per usare il token**

```bash
grep -n "struct HamburgerSectionLabel" -A 8 AppBackupFoto/ContentView.swift
```

Sostituisci il corpo:
```swift
struct HamburgerSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(AppFont.sectionHeader)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
    }
}
```
(unica differenza: `.font(.system(size: 10, weight: .semibold))` → `.font(AppFont.sectionHeader)`)

- [ ] **Step 4: Sostituisci le due etichette inline in `SidebarView` con `HamburgerSectionLabel`**

```bash
grep -n 'Text("Volumi")\|Text("Operazioni")' AppBackupFoto/ContentView.swift
```

Contenuto attuale atteso (righe 3014-3016 e 3022-3024):
```swift
            VStack(alignment: .leading, spacing: 4) {
                Text("Volumi").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 10)
```
e
```swift
            VStack(alignment: .leading, spacing: 4) {
                Text("Operazioni").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 10)
```

Sostituisci ciascuna delle due righe `Text(...)` (comprese le due righe di modificatori che le seguono) con una singola riga:
```swift
                HamburgerSectionLabel("Volumi")
```
e
```swift
                HamburgerSectionLabel("Operazioni")
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Migrate title/section-header text to AppFont tokens (roadmap #21)

Le 11 occorrenze di titolo sheet/pannello (incluso l'unico
.title3, ora .title2 come tutti gli altri) passano da
AppFont.title. HamburgerSectionLabel usa AppFont.sectionHeader;
SidebarView riusa lo stesso componente per "Volumi"/"Operazioni"
invece di uno stile inline diverso (10pt semibold uppercase
invece di caption/12pt medium non-uppercase).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Tipografia — ruolo Corpo e Didascalia

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (~35 righe: cluster 13/14/15pt → Corpo, promozione `.caption2` generico → Didascalia)

**Interfaces:**
- Consumes: `AppFont.{body,caption}` (Task 1).
- Produces: nessuna nuova interfaccia.

**Nota di scope**: 2 occorrenze di `.caption2` (righe 2980 in `CStat`, 3381 in `StatCard` — l'etichetta sotto il numero grande) **non** vengono promosse a `AppFont.caption`: restano più piccole perché il contesto (dentro una card compatta, sotto un numero hero) giustifica l'eccezione — la spec lo segnala esplicitamente come caso da confermare. Se preferisci l'uniformità totale, promuovile anche tu allo stesso modo delle altre.

- [ ] **Step 1: Verifica le occorrenze del ruolo Corpo (cluster 13/14/15pt)**

```bash
grep -n "\.font(\.system(size: 13\|\.font(\.system(size: 14\|\.font(\.system(size: 15" AppBackupFoto/ContentView.swift
```

Confronta con l'elenco sotto (10 righe testo, esclusa la riga 3084 che è un sottotitolo → Didascalia, esclusa qualunque riga il cui `.font` sia su un'`Image`, non su un `Text`):
righe 2699 (15pt→13), 2794 (13pt, resta 13 ma aggiungi/conferma `.medium`), 3063 (13pt regular→13pt medium), 3082 (13pt, già medium), 3142 (13pt semibold→13pt medium), 3266 (13pt regular→13pt medium), 3298 (13pt, già medium), 3301 (13pt, già medium), 2542 (14pt medium→13), 2563 (14pt regular→13, mantieni regular↔medium come nell'originale: qui diventa comunque `.medium` per il ruolo unico), 2572 (14pt medium→13), 2581 (14pt medium→13), 2639 (14pt regular→13), 2719 (14pt regular→13).

Se trovi righe in più o in meno rispetto a questo elenco, fermati e segnala.

- [ ] **Step 2: Applica `AppFont.body` a tutte le righe del cluster Corpo**

Per ciascuna delle righe elencate allo Step 1, sostituisci il modificatore font (qualunque combinazione size/weight fosse: `.font(.system(size: 13))`, `.font(.system(size: 13, weight: .medium))`, `.font(.system(size: 14))`, `.font(.system(size: 14, weight: .medium))`, `.font(.system(size: 15, weight: .medium))`, `.font(.system(size: 13, weight: .semibold))`) con `.font(AppFont.body)`. Il weight risultante (`.medium`) è definito una sola volta dentro il token — non serve più un `.fontWeight()` separato dopo, se presente rimuovilo.

Esempio (riga 2542, contesto `restoreSourceRow`):
```swift
// Prima:
Text(title).font(.system(size: 14, weight: .medium))
// Dopo:
Text(title).font(AppFont.body)
```

Esempio (riga 3063, `VolumeRow`, oggi senza weight):
```swift
// Prima:
Text(name).font(.system(size: 13)).foregroundStyle(mounted ? Color.primary : Color.secondary)
// Dopo:
Text(name).font(AppFont.body).foregroundStyle(mounted ? Color.primary : Color.secondary)
```

- [ ] **Step 3: Riclassifica la riga 3084 (`OpsButton` sottotitolo, 11pt) come Didascalia**

```bash
grep -n 'Text(subtitle).font(.system(size: 11))' AppBackupFoto/ContentView.swift
```

```swift
// Prima:
Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.secondary)
// Dopo:
Text(subtitle).font(AppFont.caption).foregroundStyle(Color.secondary)
```

- [ ] **Step 4: Promuovi le 21 occorrenze "generiche" di `.caption2` ad `AppFont.caption`**

```bash
grep -n "\.caption2\b" AppBackupFoto/ContentView.swift
```

Atteso 23 occorrenze totali. **Escludi** le 2 alla riga 2980 (`CStat`) e 3381 (`StatCard`) — quelle restano `.caption2` (vedi nota di scope sopra). Per tutte le altre 21 (righe: 2796, 2799, 3046, 3143, 3219, 3220, 3276, 3359, 3361, 3460, 3527, 3630, 3643, 3726, 3741, 3767, 3774, 3777, 3780, 3795, 3797), sostituisci `.font(.caption2)` con `.font(AppFont.caption)`. Se una riga usa `.font(.system(.caption2, design: .monospaced))`, sostituisci con `.font(AppFont.caption)` e aggiungi `.monospacedDigit()` subito dopo se il valore è numerico (per non perdere l'allineamento cifre — verifica il contesto di quella riga specifica prima di decidere).

Le 38 occorrenze già `.caption` restano invariate — sono già il valore target del ruolo Didascalia, opzionalmente puoi sostituirle con `AppFont.caption` per pura coerenza nominale (stesso identico rendering, zero rischio) ma non è obbligatorio in questo task.

- [ ] **Step 5: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 7: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Migrate body/caption text to AppFont tokens (roadmap #21)

Cluster 13/14/15pt (righe/liste) consolidato su AppFont.body
(13pt medium). 21 occorrenze generiche di .caption2 promosse ad
AppFont.caption (12pt), unificate con le 38 già .caption — restano
.caption2 solo le 2 etichette sotto il numero hero in CStat/StatCard
(eccezione documentata, contesto card compatta).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Tipografia — Numero Hero e icone hero

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (`CStat`/`StatCard` struct + 7 righe icone)

**Interfaces:**
- Consumes: `AppFont.heroNumber`, `AppIconSize.{heroSmall,heroLarge}` (Task 1).
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica `CStat` e `StatCard`**

```bash
grep -n "struct CStat" -A 10 AppBackupFoto/ContentView.swift
grep -n "struct StatCard" -A 10 AppBackupFoto/ContentView.swift
```

- [ ] **Step 2: Applica `AppFont.heroNumber` a entrambe**

`CStat` (riga 2979) — già 20pt semibold monospaced, diventa solo un cambio di token (nessuna resa visiva diversa):
```swift
            Text(value).font(AppFont.heroNumber).foregroundStyle(color)
```

`StatCard` (riga 3379) — oggi 18pt, sale a 20pt (valore unico del ruolo):
```swift
            Text(value).font(AppFont.heroNumber)
                .foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled)
```

- [ ] **Step 3: Verifica le 7 icone hero**

```bash
grep -n "\.font(\.system(size: 36))\|\.font(\.system(size: 40))\|\.font(\.system(size: 48))\|\.font(\.system(size: 52))\|\.font(\.system(size: 60))" AppBackupFoto/ContentView.swift
```

Atteso: righe 2507(40), 2624(36), 2660(36), 2706(48), 2718(48), 2764(52), 2941(60). Se differisce, fermati e segnala.

- [ ] **Step 4: Applica `AppIconSize.heroSmall` (36pt) alle 3 icone del wizard `RestoreView`**

Righe 2624 e 2660 (già 36, solo cambio token) e riga 2507 (da 40 a 36):
```swift
// Riga 2507, prima:
Image(systemName: "arrow.down.doc").font(.system(size: 40)).foregroundStyle(.blue)
// Dopo:
Image(systemName: "arrow.down.doc").font(.system(size: AppIconSize.heroSmall)).foregroundStyle(AppColor.macToSSD)
```
(nota: questa riga aveva già `.blue` da migrare — se il Task 3 è già stato eseguito sarà già `AppColor.macToSSD` o simile; verifica il contenuto reale prima di applicare, qui assumiamo Task 2/3 già fatti in ordine. Se questa riga usa ancora `.blue` letterale, lascia il colore invariato in questo task — tocca solo la size — il colore non è nella lista delle sostituzioni Task 2/3 per questa riga specifica, verifica con grep che non sia stata dimenticata prima)

```swift
// Riga 2624, prima:
Image(systemName: "folder").font(.system(size: 36)).foregroundStyle(.blue)
// Dopo:
Image(systemName: "folder").font(.system(size: AppIconSize.heroSmall)).foregroundStyle(.blue)
```
```swift
// Riga 2660, prima:
Image(systemName: "tray.and.arrow.down").font(.system(size: 36)).foregroundStyle(.blue)
// Dopo:
Image(systemName: "tray.and.arrow.down").font(.system(size: AppIconSize.heroSmall)).foregroundStyle(.blue)
```

- [ ] **Step 5: Applica `AppIconSize.heroLarge` (48pt) alle 4 icone rimanenti**

```swift
// Riga 2706 (già 48, solo cambio token), prima:
Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(AppColor.success)
// Dopo:
Image(systemName: "checkmark.circle.fill").font(.system(size: AppIconSize.heroLarge)).foregroundStyle(AppColor.success)
```
```swift
// Riga 2718 (già 48, solo cambio token), prima:
Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(AppColor.warning)
// Dopo:
Image(systemName: "exclamationmark.triangle.fill").font(.system(size: AppIconSize.heroLarge)).foregroundStyle(AppColor.warning)
```
```swift
// Riga 2764 (da 52 a 48), prima:
    .font(.system(size: 52)).foregroundStyle(.blue)
// Dopo:
    .font(.system(size: AppIconSize.heroLarge)).foregroundStyle(.blue)
```
```swift
// Riga 2941 (da 60 a 48), prima:
.font(.system(size: 60)).foregroundStyle(ok ? AppColor.success : AppColor.error).symbolRenderingMode(.hierarchical)
// Dopo:
.font(.system(size: AppIconSize.heroLarge)).foregroundStyle(ok ? AppColor.success : AppColor.error).symbolRenderingMode(.hierarchical)
```

(Le righe 2706/2718/2941 mostrano già `AppColor.success`/`AppColor.warning`/`AppColor.error` perché Task 2 le ha già migrate — se stai eseguendo questo task fuori ordine, applica solo il cambio di size, il colore letterale `.green`/`.orange`/(`ok ? .green : .red`) resta quello che trovi.)

- [ ] **Step 6: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 8: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Migrate hero numbers/icons to AppFont/AppIconSize tokens (roadmap #21)

CStat/StatCard unificati a AppFont.heroNumber (20pt, StatCard
saliva da 18). Le 7 icone hero (36-60px sparsi) diventano 2
taglie: AppIconSize.heroSmall (36, step wizard RestoreView),
AppIconSize.heroLarge (48, esiti/onboarding/completamento).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Griglia di spacing — arrotondamento HStack/VStack `spacing:`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (~55 righe con `spacing:` fuori griglia)

**Interfaces:**
- Consumes: `AppSpacing.{xs,sm,md,lg,xl,xxl}` (Task 1).
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica la distribuzione attuale**

```bash
grep -on "spacing: [0-9]*" AppBackupFoto/ContentView.swift | sed 's/.*spacing: //' | sort -n | uniq -c
```

Atteso: stessa distribuzione della tabella sotto (0:5, 1:5, 2:6, 3:1, 4:5, 6:10, 8:9, 10:10, 12:5, 14:2, 18:4, 20:3, 22:1, 24:1, 28:1). Se differisce, fermati e segnala — la tabella sotto assume questa distribuzione esatta.

- [ ] **Step 2: Applica la tabella di arrotondamento**

Per ogni riga con `spacing: N`, sostituisci il numero letterale con la costante indicata. **Escludi le righe con `spacing: 0`** (5 occorrenze, tutte struttura di layout con `Divider()` a fare la separazione — non toccarle, restano `spacing: 0` letterale).

| Valore oggi | → Token | Righe |
|---|---|---|
| 1 | `AppSpacing.xs` | 3081, 3724, 3738, 3771, 3794 |
| 2 | `AppSpacing.xs` | 2541, 2580, 2793, 3045, 3141, 3157 |
| 3 | `AppSpacing.xs` | 3005 |
| 4 | `AppSpacing.xs` | 2919, 2978, 3014, 3022, 3378 |
| 6 | `AppSpacing.sm` | 2506, 2623, 2659, 3218, 3294, 3349, 3455, 3549, 3640, 3711 |
| 8 | `AppSpacing.sm` | 2630, 2762, 3327, 3400, 3622, 3624, 3720, 3734, 3793 |
| 10 (contenitori liste) | `AppSpacing.md` | 2510, 2770, 2924 |
| 10 (righe icona+testo) | `AppSpacing.sm` | 2827, 2995, 3059, 3078, 3345, 3718 |
| 10 (riga `StatCard`) | `AppSpacing.md` | 3364 |
| 12 | `AppSpacing.md` | 140, 2790, 3136, 3257, 3554 |
| 14 (`StatsPanel` esterno) | `AppSpacing.lg` | 3344 |
| 14 (riga `CStat`) | `AppSpacing.md` | 2944 |
| 18 | `AppSpacing.lg` | 2505, 2622, 2658, 3618 |
| 20 | `AppSpacing.xl` | 2491, 2693, 2916 |
| 22 | `AppSpacing.xl` | 2939 |
| 24 | `AppSpacing.xl` | 3547 |
| 28 | `AppSpacing.xxl` | 2761 |

Esempio (riga 2505):
```swift
// Prima:
        VStack(spacing: 18) {
// Dopo:
        VStack(spacing: AppSpacing.lg) {
```

Applica lo stesso pattern (sostituzione diretta del numero con la costante) a tutte le righe della tabella.

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
Migrate HStack/VStack spacing to AppSpacing grid (roadmap #21)

15 valori sparsi (1-28) arrotondati alla griglia 4/8/12/16/24/32.
spacing: 0 lasciato invariato (separazione già affidata a Divider(),
non è spacing decorativo).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Griglia di spacing — arrotondamento `.padding(...)`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (~50 righe con valori di padding fuori griglia)

**Interfaces:**
- Consumes: `AppSpacing.{xs,sm,md,lg,xl,xxl}` (Task 1).
- Produces: nessuna nuova interfaccia.

- [ ] **Step 1: Verifica la distribuzione attuale**

```bash
grep -on "padding([a-zA-Z.]*, *[0-9]*)" AppBackupFoto/ContentView.swift | sed -E 's/.*, *([0-9]+)\)/\1/' | sort -n | uniq -c
grep -on "padding([0-9]*)" AppBackupFoto/ContentView.swift | sed -E 's/padding\(([0-9]+)\)/\1/' | sort -n | uniq -c
```

Se la distribuzione differisce sostanzialmente da quella implicita nella tabella sotto, fermati e segnala prima di procedere — questo task ha la superficie di modifica più ampia del piano, meglio verificare bene prima di partire alla cieca.

- [ ] **Step 2: Applica la tabella di arrotondamento**

| Valore oggi | → Token | Righe (contesto) |
|---|---|---|
| 5 | `AppSpacing.xs` | 3067 (`VolumeRow` vertical) |
| 6 | `AppSpacing.xs` | 3203, 3243 (sopra `HamburgerSectionLabel`/riga hamburger) |
| 10 (riga-card `chooseFoldersStep`) | `AppSpacing.md` | 2642 |
| 10 (chrome/inset `StatCard`/`CStat`) | `AppSpacing.sm` | 2840, 2982, 3016, 3020, 3024, 3050, 3222, 3382, 3528 |
| 14 (pattern riga-card `restoreSourceRow`/`s3SourceRow`) | `AppSpacing.md` | 2550, 2565, 2576, 2586 |
| 14 (header asimmetrico main window) | `AppSpacing.md` | 2843 (`.padding(.top, 14)`) |
| 14 (header asimmetrico hamburger) | `AppSpacing.md` | 3152 (`.padding(.bottom, 14)`) |
| 18 | `AppSpacing.lg` | 2843 (`.horizontal, 18`), 2847 |
| 20 (edge inset chrome) | `AppSpacing.lg` | 2840 (`.top`), 2854, 3011 (`.top`), 3152 (`.top`) |
| 20 (inset `SettingsSheet`) | `AppSpacing.xl` | 2923, 2928 |
| 20 (inset `SetupView`) | `AppSpacing.xl` | 2774 |
| 20 (`CatalogView`) | `AppSpacing.lg` | 184 |
| 36 | `AppSpacing.xxl` | 2930 (`SettingsSheet` frame) |
| 38 | `AppSpacing.xxl` | 2971 (`CompletionSheet` frame) |
| 40 | `AppSpacing.xxl` | 2780 (`SetupView` outer, il valore più alto del file — scende a 32, il massimo della griglia approvata) |

Nota: alcune righe compaiono con più `.padding(...)` incatenati sulla stessa riga (es. `.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 16)`) — modifica solo il numero indicato nella tabella per quella riga, lasciando gli altri valori della stessa riga (già in griglia, es. 16) invariati.

Esempio (riga 2930):
```swift
// Prima:
            .padding(36)
// Dopo:
            .padding(AppSpacing.xxl)
```

Esempio (riga 2843, due valori sulla stessa riga):
```swift
// Prima:
            .padding(.horizontal, 18).padding(.top, 14)
// Dopo:
            .padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md)
```
(verifica il contenuto esatto di questa riga con grep prima di applicare — potrebbe avere anche un terzo `.padding(.bottom, ...)` sulla stessa riga logica, in tal caso applica la tabella anche a quello se il suo valore compare sopra, altrimenti lascialo invariato)

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
Migrate padding values to AppSpacing grid (roadmap #21)

16 valori sparsi (5-40) arrotondati alla griglia 4/8/12/16/24/32.
I 5 padding contenitore sheet oggi diversi (28/32/36/38/40)
convergono tutti su AppSpacing.xxl (32), come da spec.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Unificare corner radius e opacità del pattern "card"

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (4 righe: 2642, 2983, 3383, 3569)

**Interfaces:**
- Consumes: `AppSpacing.{cardCornerRadius,cardOpacity}` (Task 1).
- Produces: nessuna nuova interfaccia.

**Nota di scope**: normalizza solo i *valori* del pattern "card" (`.background(.quaternary.opacity(N)).clipShape(RoundedRectangle(cornerRadius: M))`), non fonde `StatCard`/`CStat` in un unico componente (quello è fuori scope, fase successiva). La riga 3263 (`HamburgerRow`, badge icona colorato — non usa `.quaternary`) e le righe 3514/3533 (`.stroke(.quaternary, ...)`, bordo non sfondo) **non** fanno parte di questo pattern e non vanno toccate.

- [ ] **Step 1: Verifica le 4 righe da normalizzare**

```bash
grep -n "\.quaternary\.opacity" AppBackupFoto/ContentView.swift
```

Atteso 11 occorrenze totali; 7 già corrette a `cornerRadius: 8`/`opacity(0.4)` (righe 2550, 2565, 2576, 2586, 2807, e le due appena migrate da Task 8 se già eseguito). Le 4 da correggere:

- [ ] **Step 2: Applica le 4 correzioni**

Riga 2642 (`chooseFoldersStep`, riga cartella):
```swift
// Prima:
                            .padding(10).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 6))
// Dopo:
                            .padding(AppSpacing.md).background(.quaternary.opacity(AppSpacing.cardOpacity)).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
```
(questa riga ha anche il padding 10→12 già gestito da Task 8 — se Task 8 non è ancora stato eseguito, applica qui solo `background`/`clipShape`, lasciando `.padding(10)` invariato)

Riga 2983 (`CStat`):
```swift
// Prima:
        .background(.quaternary.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 10))
// Dopo:
        .background(.quaternary.opacity(AppSpacing.cardOpacity)).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
```

Riga 3383 (`StatCard`) — stessa sostituzione di riga 2983.

Riga 3569 (`AppearanceSheet`, box delle 3 righe modalità):
```swift
// Prima:
            .padding(8).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
// Dopo:
            .padding(AppSpacing.sm).background(.quaternary.opacity(AppSpacing.cardOpacity)).clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
```

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
Unify card corner-radius/opacity values (roadmap #21)

Le 4 righe fuori standard (cornerRadius 6/10, opacity 0.3/0.5)
convergono su AppSpacing.cardCornerRadius (8) e .cardOpacity (0.4),
il valore già maggioritario nel file. StatCard/CStat restano
struct separate — solo i valori sono unificati, nessun merge.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Aggiornare la documentazione e chiudere roadmap #21

**Files:**
- Modify: `Docs/ROADMAP.md`
- Modify: `.claude/rules/architecture.md`

**Interfaces:** nessuna — task di documentazione, chiude la Fase 1.

- [ ] **Step 1: In `.claude/rules/architecture.md`, documenta i nuovi design token**

Aggiungi una nuova sottosezione subito dopo la sezione UI esistente (o in un punto stilisticamente coerente — verifica la struttura reale del file prima di scegliere dove):

```markdown
### Design Tokens (2026-08-12, roadmap #21, Fase 1)

`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize` (inizio `ContentView.swift`, subito dopo gli import): palette semantica (stato: successo/errore/warning/in-corso; identità destinazione: Mac→SSD/SSD→HDD/SSD→Cubbit; utility: Tools/Configurazione), griglia di spacing 4/8/12/16/24/32, 5 ruoli di testo (titolo/intestazione/corpo/didascalia/numero-hero), 2 taglie icona hero (36/48). Migrazione completa dei valori hardcoded preesistenti — nessun colore/font/spacing arbitrario rimasto fuori dai token, salvo 2 eccezioni documentate nel codice: l'etichetta `.caption2` sotto il numero in `CStat`/`StatCard` (contesto card compatta) e i 6 colori decorativi delle voci `HamburgerRow` diverse da Tools (fuori scope, non fanno parte della palette semantica a 7 token). Nessun cambio strutturale alle view — solo valori. Vedi `Docs/superpowers/specs/2026-08-12-design-foundations-design.md`.
```

- [ ] **Step 2: In `Docs/ROADMAP.md`, marca il punto 21 come fatto**

Cerca la riga:
```
21. 🔲 **Fase 1 — Fondamenta design**: palette semantica (successo/errore/warning + accent blu di sistema), scala tipografica coerente, griglia di spacing 4/8/12/16. Nessun rischio strutturale. *In corso — prima fase scelta da Enrico.*
```

Sostituisci con:
```
21. ✅ **Fatto (2026-08-12) — Fase 1, fondamenta design.** 4 enum di design token (`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize`) in `ContentView.swift`, migrazione completa di colori/tipografia/spacing/padding/corner-radius del pattern "card" verso i token. Vedi `Docs/superpowers/specs/2026-08-12-design-foundations-design.md` e `Docs/superpowers/plans/2026-08-12-design-foundations.md`.
```

- [ ] **Step 3: Commit**

```bash
git add Docs/ROADMAP.md .claude/rules/architecture.md
git commit -m "$(cat <<'EOF'
Update docs: design foundations (roadmap #21, Fase 1) shipped

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
