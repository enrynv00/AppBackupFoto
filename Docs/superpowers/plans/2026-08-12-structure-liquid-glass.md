# Fase 2 — Struttura e Liquid Glass (roadmap #22) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sostituire `HSplitView` con `NavigationSplitView` per `SidebarView`, applicare Liquid Glass a sidebar e barra superiore, e correggere il bug di dimensione finestra trovato durante la verifica manuale di Fase 1.

**Architecture:** Nessun nuovo file, nessun nuovo componente condiviso. Si tocca solo `ContentView.body` (struct `ContentView`, il contenitore che oggi usa `HSplitView`) e `SidebarView` (contenuto invariato, solo contenitore/materiale). Il pannello hamburger (`HamburgerPanel`) non viene toccato in nessun task.

**Tech Stack:** SwiftUI, target macOS 26 (Liquid Glass). Nessuna nuova dipendenza esterna.

## Global Constraints

- Nessun nuovo file `.swift` — tutto dentro `AppBackupFoto/ContentView.swift`.
- Nessun cambio ai design token di Fase 1 (`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize`) — si riusano così come sono.
- Nessun cambio al pannello hamburger (`HamburgerPanel`, struct a riga ~3157 al momento della scrittura di questo piano) — resta l'overlay separato di oggi, invariato.
- Nessuna migrazione della barra superiore a `.toolbar()` nativa SwiftUI — resta lo stesso `HStack`, solo il materiale di sfondo cambia.
- L'API Liquid Glass esatta (`.glassEffect()` vs materiale di sistema che si attiva automaticamente col nuovo SDK) **non è garantita a priori** — i Task 4 e 5 richiedono una verifica empirica (build + occhio) prima di scegliere il codice finale, non vanno eseguiti alla cieca copiando uno snippet.
- Ogni task termina con build (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`, atteso `** BUILD SUCCEEDED **`) e test (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test`, attesi tutti verdi — se un test fallisce con un timeout ambientale tipo "test runner hung before establishing connection", è un flake noto non legato al codice, riprova una volta) prima del commit. Nessun nuovo XCTest sensato in questa fase (solo struttura/contenitore/materiali, stesso ragionamento delle fasi precedenti).
- I numeri di riga sotto sono verificati al momento della scrittura di questo piano (2026-08-12, dopo la chiusura di Fase 1) — possono slittare da un task al successivo. Localizza sempre il contenuto reale con grep/ricerca testuale prima di ogni edit; se il contenuto reale differisce sostanzialmente da quanto mostrato, fermati e segnala invece di procedere alla cieca.

---

### Task 1: Alzare il deployment target a macOS 26

**Files:**
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (4 occorrenze di `MACOSX_DEPLOYMENT_TARGET`, oggi `15.6` — verificato con `grep -n MACOSX_DEPLOYMENT_TARGET AppBackupFoto.xcodeproj/project.pbxproj` alle righe 317/341/407/465 del file a questa data)

**Interfaces:**
- Consumes: nessuna.
- Produces: SDK macOS 26 disponibile per i task successivi (prerequisito per qualunque API Liquid Glass, `.glassEffect()` incluso).

**Nota importante**: durante il brainstorming di Fase 1 (2026-08-12) era già stato deciso "target macOS alzato a 26 (Tahoe), Enrico lo usa già" — ma quella decisione non è mai stata applicata al progetto Xcode (Fase 1 ha toccato solo `ContentView.swift`, mai `project.pbxproj`). Questo task chiude quel gap, è un prerequisito reale per tutto il resto di questa fase.

- [ ] **Step 1: Verifica il valore attuale e l'SDK disponibile**

```bash
grep -n "MACOSX_DEPLOYMENT_TARGET" AppBackupFoto.xcodeproj/project.pbxproj
xcodebuild -showsdks | grep -i macos
```

Atteso: 4 righe con `MACOSX_DEPLOYMENT_TARGET = 15.6;` (Debug/Release × target app/test), e `macOS 26.5` disponibile come SDK (`-sdk macosx26.5`). Se l'SDK 26.x non risulta disponibile, fermati e segnala — questo task non può procedere senza.

- [ ] **Step 2: Sostituisci tutte e 4 le occorrenze**

In ciascuna delle 4 righe, sostituisci:
```
MACOSX_DEPLOYMENT_TARGET = 15.6;
```
con:
```
MACOSX_DEPLOYMENT_TARGET = 26.0;
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Se la build fallisce per errori di compatibilità legati a questo cambio (es. API deprecate/rimosse nel nuovo SDK), fermati e segnala i messaggi di errore esatti prima di procedere — non tentare fix improvvisati non previsti da questo piano.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Raise deployment target to macOS 26 (roadmap #22)

Decisione già presa nel brainstorming di Fase 1 (Enrico usa già
macOS 26/Tahoe) ma mai applicata al progetto Xcode — Fase 1 aveva
toccato solo ContentView.swift. Prerequisito reale per le API
Liquid Glass usate dal resto di questa fase.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Fix del bug di dimensione finestra

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `ContentView`, `body`, oggi righe 2872-2907 — verifica con `grep -n "struct ContentView"`)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia — fix di layout puro.

**Contesto**: trovato durante la verifica manuale di Fase 1 (avviando l'app: area vuota in alto, contenuto ancorato in basso quando `runner.phase == .idle`). Causa: né `SidebarView` né il `VStack` di dettaglio dentro `HSplitView` hanno `.frame(maxHeight: .infinity)` — a differenza di `HamburgerPanel` (che ce l'ha già, riga ~2921, e infatti riempie correttamente tutta l'altezza quando aperto). Fix indipendente dalla migrazione a `NavigationSplitView` del Task 3 — lo facciamo su `HSplitView` **prima** di migrare, così è verificabile isolatamente.

- [ ] **Step 1: Localizza `ContentView.body`**

```bash
grep -n "struct ContentView" AppBackupFoto/ContentView.swift
```

Il contenuto atteso (verifica che coincida, salvo numeri di riga — cerca in particolare la riga con `SidebarView(volumes: volumes, runner: runner, showHamburger: $showHamburger)` seguita da `.frame(minWidth: 220, maxWidth: 260)`, e la riga `VStack(spacing: 0) {` subito dopo che apre il contenuto di dettaglio):

```swift
        ZStack(alignment: .leading) {
            HSplitView {
                SidebarView(volumes: volumes, runner: runner, showHamburger: $showHamburger)
                    .frame(minWidth: 220, maxWidth: 260)
                VStack(spacing: 0) {
                    HStack(spacing: AppSpacing.sm) {
                        PhaseIndicator(phase: runner.phase, percent: runner.stats.percent)
                        Spacer()
                        Button {
                            activeSpeedTab = .log
                        } label: { Label("Log", systemImage: "doc.text.magnifyingglass") }
                        .buttonStyle(.bordered).controlSize(.small)
                        if runner.isRunning {
                            Button(role: .destructive) { runner.stop() } label: {
                                Label("Interrompi", systemImage: "stop.fill")
                            }.buttonStyle(.bordered).controlSize(.small).tint(AppColor.error)
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm).background(.bar)
                    Divider()
                    SpeedLogPanel(history: runner.speedHistory, output: runner.output, speedUnit: runner.speedUnit, activeTab: $activeSpeedTab)
                        .padding(.horizontal, AppSpacing.lg).padding(.top, AppSpacing.md).padding(.bottom, AppSpacing.sm)
                    if runner.phase != .idle {
                        Divider()
                        StatsPanel(stats: runner.stats, phase: runner.phase, currentStatus: runner.currentStatus, currentThumbnail: runner.currentThumbnail)
                            .padding(AppSpacing.lg)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Esci") { confirmQuit() }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, 8)
                }
            }
```

Se differisce sostanzialmente, fermati e segnala.

- [ ] **Step 2: Aggiungi `.frame(maxHeight: .infinity)` a entrambe le pane**

Sostituisci le due righe di apertura pane con:
```swift
                SidebarView(volumes: volumes, runner: runner, showHamburger: $showHamburger)
                    .frame(minWidth: 220, maxWidth: 260)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 0) {
```
e chiudi il `VStack(spacing: 0) { ... }` (dopo la sua parentesi graffa finale, subito prima della chiusura di `HSplitView {`) con:
```swift
                }
                .frame(maxHeight: .infinity)
            }
```
(l'unica differenza rispetto a oggi: un `.frame(maxHeight: .infinity)` aggiunto dopo il modificatore `.frame(minWidth:maxWidth:)` esistente su `SidebarView`, e uno aggiunto dopo la chiusura del `VStack` di dettaglio, prima della chiusura di `HSplitView`.)

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

Avvia l'app (build già fatta, apri il bundle da DerivedData con `open`, o `Cmd+R` da Xcode), controlla che la finestra si riempia correttamente senza area vuota in alto, sia a job idle (`Pronto`) sia con un job in corso (se puoi avviarne uno). Se l'area vuota persiste, fermati e segnala prima di committare — questo task non è completo finché il bug non è visivamente risolto.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Fix main window blank area bug (roadmap #22)

SidebarView e il VStack di dettaglio dentro HSplitView non avevano
.frame(maxHeight: .infinity), a differenza di HamburgerPanel (che
ce l'ha già) — quando il contenuto era corto (es. job idle, nessun
StatsPanel), la finestra lasciava un'area vuota in alto invece di
farlo riempire dalle due pane. Trovato durante la verifica manuale
di Fase 1.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `HSplitView` → `NavigationSplitView`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `ContentView`, `body` — stessa area del Task 2, già con i due `.frame(maxHeight: .infinity)` applicati)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia — cambio di contenitore, contenuto interno invariato.

- [ ] **Step 1: Localizza il blocco `HSplitView` aggiornato dal Task 2**

```bash
grep -n "HSplitView {" AppBackupFoto/ContentView.swift
```

- [ ] **Step 2: Sostituisci `HSplitView { ... }` con `NavigationSplitView { ... } detail: { ... }`**

Prima (dopo il Task 2):
```swift
            HSplitView {
                SidebarView(volumes: volumes, runner: runner, showHamburger: $showHamburger)
                    .frame(minWidth: 220, maxWidth: 260)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 0) {
                    /* ... contenuto invariato ... */
                }
                .frame(maxHeight: .infinity)
            }
```

Dopo:
```swift
            NavigationSplitView {
                SidebarView(volumes: volumes, runner: runner, showHamburger: $showHamburger)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
                    .frame(maxHeight: .infinity)
            } detail: {
                VStack(spacing: 0) {
                    /* ... contenuto invariato, NON toccare ... */
                }
                .frame(maxHeight: .infinity)
            }
```

Note sul cambio:
- `.frame(minWidth: 220, maxWidth: 260)` su `SidebarView` è sostituito da `.navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)` (l'API dedicata di `NavigationSplitView` per il range di larghezza della colonna sidebar — stesso range min/max di oggi, con un `ideal` nuovo scelto a metà).
- Il contenuto del `VStack` di dettaglio (tutto ciò che sta tra `VStack(spacing: 0) {` e la sua chiusura) **non cambia in nessun modo** — copialo/spostalo esattamente com'è, solo la sua posizione nel codice cambia (da secondo figlio di `HSplitView` a corpo della closure `detail:`).
- Se il compilatore segnala un errore sul tipo di `columnVisibility` o richiede un parametro esplicito per `NavigationSplitView` che questo snippet non mostra, usa la forma a 2 argomenti (`sidebar:`/`detail:` impliciti, senza `columnVisibility:` esplicito) che è quella mostrata sopra — non aggiungere `@State private var columnVisibility` se non richiesto dal compilatore, la spec ha scelto esplicitamente il comportamento nativo di default (nessun binding custom).

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Se il compilatore segnala errori sulla sintassi di `NavigationSplitView` (firma diversa da quella mostrata, parametri mancanti), correggi seguendo l'errore del compilatore mantenendo lo stesso range di colonna (220/240/260) e lo stesso contenuto — non stravolgere la struttura.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 5: Verifica manuale visiva**

Avvia l'app. Controlla: (a) il sidebar è ancora largo tra 220 e 260pt come prima; (b) esiste un pulsante nativo per collassare/mostrare il sidebar (di solito nell'angolo in alto a sinistra della toolbar di sistema) e funziona; (c) il pannello hamburger (☰ dentro la sidebar) continua a funzionare esattamente come prima, nessuna regressione. Se qualcosa non torna, fermati e segnala prima di committare.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Replace HSplitView with NavigationSplitView (roadmap #22)

Solo la SidebarView permanente (Volumi/Operazioni) migra al
contenitore nativo moderno — il pannello hamburger (overlay
separato) resta invariato. Stesso contenuto, stesso range di
larghezza colonna (220-260pt), guadagna gratis il pulsante nativo
di collasso sidebar (comportamento di default di NavigationSplitView,
nessun binding custom aggiunto).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Liquid Glass sulla sidebar

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `SidebarView`, oggi riga ~3039-3103 — verifica con `grep -n "struct SidebarView"`)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia — solo materiale di sfondo.

**Attenzione — questo task richiede una verifica empirica prima di scegliere il codice finale**, non va eseguito copiando ciecamente un solo snippet: su macOS 26, `NavigationSplitView` (introdotta nel Task 3) potrebbe già applicare automaticamente il nuovo materiale Liquid Glass allo sfondo della colonna sidebar tramite il chrome di sistema, senza bisogno di alcun materiale esplicito — esattamente come già oggi il semplice uso di `NavigationSplitView` dà "gratis" la vibrancy standard senza che l'app debba applicare `.background(.ultraThinMaterial)` a mano. Se è così, l'unico intervento necessario è **rimuovere** il `.background(.windowBackground)` esistente (che forza uno sfondo opaco sopra il chrome di sistema, nascondendo l'eventuale materiale automatico) — non aggiungerne uno nuovo.

- [ ] **Step 1: Localizza lo sfondo attuale di `SidebarView`**

```bash
grep -n "struct SidebarView" -A 65 AppBackupFoto/ContentView.swift | tail -5
```

Atteso, alla fine del `body` di `SidebarView`:
```swift
        }.background(.windowBackground)
    }
}
```

- [ ] **Step 2: Prova prima a rimuovere lo sfondo esplicito**

```swift
        }
    }
}
```
(rimuovi `.background(.windowBackground)`, lasciando che la view riceva lo sfondo di sistema di `NavigationSplitView`)

- [ ] **Step 3: Build ed esamina visivamente**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Poi avvia l'app e guarda la sidebar: se appare traslucida/con effetto vetro (il contenuto dietro la finestra o lo sfondo della scrivania si intravede leggermente quando muovi la finestra sopra altri elementi), il comportamento automatico funziona — vai allo Step 5 (nessun altro codice necessario). Se la sidebar appare ancora completamente opaca/piatta (indistinguibile da prima), procedi allo Step 4.

- [ ] **Step 4: Se lo sfondo automatico non basta, applica un materiale esplicito**

```swift
        }.background(.regularMaterial)
    }
}
```
(`.regularMaterial` è un materiale di sistema traslucido standard, disponibile da tempo in SwiftUI, che su macOS 26 eredita l'aspetto Liquid Glass del sistema — alternativa più sicura di un `.glassEffect()` scritto a mano se quest'ultimo non risultasse disponibile o applicabile a un contenitore di questa forma nel SDK installato. Se durante questo step scopri che `.glassEffect()` è invece disponibile e applicabile direttamente, puoi usarlo al posto di `.regularMaterial` — l'importante è il risultato visivo, non l'API specifica.)

Ribuilda e verifica di nuovo visivamente.

- [ ] **Step 5: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 6: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Apply Liquid Glass material to sidebar (roadmap #22)

EOF
)"
```
(completa il messaggio di commit con una riga che descriva quale dei due esiti dello Step 3/4 si è verificato — es. "NavigationSplitView applica il materiale di sistema automaticamente, rimosso solo il .background(.windowBackground) che lo nascondeva" oppure "aggiunto .background(.regularMaterial) esplicito, il chrome automatico non bastava" — poi aggiungi comunque la riga `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>` alla fine.)

---

### Task 5: Liquid Glass sulla barra superiore

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (struct `ContentView`, `body`, l'`HStack` con `PhaseIndicator`/bottone Log/bottone Interrompi — oggi con `.background(.bar)`)

**Interfaces:**
- Consumes: nessuna.
- Produces: nessuna nuova interfaccia.

**Stessa nota del Task 4**: `.bar` (il materiale già in uso oggi su questo `HStack`) è già un materiale di sistema per barre/toolbar — su macOS 26 potrebbe già rendersi come Liquid Glass automaticamente con il solo innalzamento del deployment target (Task 1), senza nessun cambio di codice qui. Verifica prima di modificare.

- [ ] **Step 1: Localizza la barra superiore**

```bash
grep -n 'padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm).background(.bar)' AppBackupFoto/ContentView.swift
```

- [ ] **Step 2: Verifica visivamente prima di cambiare codice**

Avvia l'app (build già presente dai task precedenti) e guarda la barra in alto ("Pronto"/bottone Log). Se ha già un aspetto vetro/traslucido coerente con la sidebar appena sistemata nel Task 4, **non modificare questo codice** — `.bar` si è già aggiornato automaticamente col nuovo SDK, questo task si chiude senza modifiche al file, salta allo Step 5 con un commit vuoto di sola documentazione (o nessun commit se preferisci non crearne uno senza modifiche — nota comunque il risultato per il Task 6). Se invece la barra appare visivamente diversa/più piatta della sidebar, procedi allo Step 3.

- [ ] **Step 3: Se necessario, allinea il materiale a quello scelto per la sidebar**

Sostituisci:
```swift
                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm).background(.bar)
```
con (usa lo stesso materiale scelto/confermato nel Task 4 — `.regularMaterial` se quello è l'esito del Task 4, o l'equivalente):
```swift
                    .padding(.horizontal, AppSpacing.lg).padding(.vertical, AppSpacing.sm).background(.regularMaterial)
```

- [ ] **Step 4: Build e verifica**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Verifica visivamente che la barra ora sia coerente con la sidebar.

- [ ] **Step 5: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i test verdi.

- [ ] **Step 6: Commit**

Se hai modificato codice allo Step 3:
```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Align top bar material with sidebar glass (roadmap #22)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

Se allo Step 2 hai verificato che `.bar` è già coerente e non hai modificato nulla, non serve un commit — annota semplicemente per il Task 6 (documentazione) che la barra superiore usa già `.bar` di sistema, già Liquid Glass su macOS 26 senza cambi di codice.

---

### Task 6: Aggiornare la documentazione e chiudere roadmap #22

**Files:**
- Modify: `Docs/ROADMAP.md`
- Modify: `.claude/rules/architecture.md`

**Interfaces:** nessuna — task di documentazione, chiude la Fase 2.

- [ ] **Step 1: In `.claude/rules/architecture.md`, aggiorna la voce sulla UI**

Trova la riga che descrive `ContentView` (nella sezione `## UI (SwiftUI views in ContentView.swift)`, oggi: `- **ContentView** — \`HSplitView\` con \`SidebarView\` a sinistra e pannello principale...`) e sostituiscila con:

```markdown
- **ContentView** — `NavigationSplitView` (roadmap #22, 2026-08-12) con `SidebarView` come colonna sidebar (range 220-260pt, collasso nativo) e il pannello principale (fase corrente, `SpeedLogPanel`, `StatsPanel`, bottone Interrompi/Esci) come `detail`. Materiale Liquid Glass su sidebar e barra superiore (macOS 26, deployment target alzato in questa fase). Il pannello hamburger resta un overlay `ZStack` separato, invariato.
```

(Se la formulazione esatta scoperta al Task 4/5 differisce — es. materiale automatico vs `.regularMaterial` esplicito — aggiusta la frase "Materiale Liquid Glass..." per riflettere cosa è stato effettivamente fatto, non copiare questa frase alla cieca se il codice reale dice altro.)

- [ ] **Step 2: In `Docs/ROADMAP.md`, marca il punto 22 come fatto**

Cerca la riga:
```
22. 🔲 **Fase 2 — Struttura**: `HSplitView` → `NavigationSplitView`, adozione material Liquid Glass (`.glassEffect()`) su sidebar/toolbar. Cambio più rischioso, da fare dopo le fondamenta.
```

Sostituisci con:
```
22. ✅ **Fatto (2026-08-12) — Fase 2, struttura e Liquid Glass.** `HSplitView` → `NavigationSplitView` per la sidebar permanente (pannello hamburger invariato), materiale Liquid Glass su sidebar e barra superiore, più il fix di un bug di dimensione finestra trovato durante la verifica manuale di Fase 1 (mancava `.frame(maxHeight: .infinity)` sulle due colonne). Vedi `Docs/superpowers/specs/2026-08-12-structure-liquid-glass-design.md` e `Docs/superpowers/plans/2026-08-12-structure-liquid-glass.md`.
```

- [ ] **Step 3: Commit**

```bash
git add Docs/ROADMAP.md .claude/rules/architecture.md
git commit -m "$(cat <<'EOF'
Update docs: structure and Liquid Glass (roadmap #22) shipped

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
