# Fase 2 — Struttura e Liquid Glass (roadmap #22)

Data: 2026-08-12

## Problema

Roadmap #22 (secondo capitolo del piano "Design polish", dopo la Fase 1 — fondamenta design, roadmap #21, chiusa): la Fase 1 ha reso coerenti colori/tipografia/spacing, ma non ha cambiato nulla di strutturale — l'app usa ancora `HSplitView` (pattern pre-SwiftUI-moderno) e nessun materiale traslucido (`Docs/CLAUDE.md`/audit originale: "zero materials/vibrancy... `HSplitView` invece di `NavigationSplitView`"). È la leva con la resa visiva più alta del piano di 5 fasi (confermato durante il brainstorming di Fase 1) — l'obiettivo di questa fase è farla percepire davvero "da sistema operativo moderno" (macOS 26/Tahoe, Liquid Glass).

Durante la verifica manuale post-Fase-1 (avviando l'app per un controllo visivo) è emerso un bug reale e riproducibile, non legato ai design token: la finestra principale mostra un'ampia area vuota in alto con il contenuto (sidebar + pannello principale) ancorato in basso, quando il job è idle (nessun `StatsPanel` visibile). Causa identificata leggendo il codice: né `SidebarView` né il `VStack` del contenuto principale dentro `HSplitView` (`ContentView.swift`, struct `ContentView`) hanno `.frame(maxHeight: .infinity)` — a differenza di `HamburgerPanel`, che ce l'ha esplicitamente (riga 2921 nel codice pre-Fase-2) e infatti riempie correttamente tutta l'altezza della finestra quando aperto. Le due pane di `HSplitView` non essendo forzate a riempire l'altezza assumono la loro dimensione intrinseca (che varia in base al contenuto condizionale, es. `StatsPanel` presente/assente), e la finestra (min 620pt, spesso più alta per via del frame salvato da sessioni precedenti) lascia lo spazio in eccesso vuoto in alto invece che distribuirlo.

## Decisioni prese in brainstorming

- **Cosa diventa `NavigationSplitView`**: solo la `SidebarView` permanente (Volumi/Operazioni) — il pannello hamburger (Strumenti/Preferenze, apre da ☰) resta esattamente come oggi, un overlay separato che scorre sopra (`ZStack` + `.transition(.move(edge: .leading))`), invariato in questa fase. Motivazione: i due pattern sono concettualmente diversi (sidebar di navigazione permanente vs drawer di impostazioni che appare/scompare) — unificarli in un solo sidebar avrebbe cambiato la UX (niente più pulsante ☰), non solo l'aspetto, e non era l'obiettivo di questa fase.
- **Dove va il Liquid Glass**: sidebar (contenuto `NavigationSplitView`) + la barra in alto ("Pronto"/bottone Log/Interrompi, oggi un `HStack` con `.background(.bar)`). Il resto del contenuto principale (grafico velocità, log, stat) resta opaco per non affaticare la lettura.
- **Come si applica alla barra in alto**: solo un cambio di materiale sull'`HStack` esistente (stesso codice/struttura, nuovo `.background`) — **non** una migrazione a `.toolbar()` nativa SwiftUI. Migrare a `.toolbar()` sposterebbe la dichiarazione dei bottoni in `ToolbarItem`, un cambio più ampio, più vicino a un redesign che alla Fase 2 così come scelta da Enrico.
- **Sidebar collassabile**: sì, comportamento nativo di `NavigationSplitView` (pulsante toggle in toolbar per nascondere/mostrare il sidebar) — nessun codice per disabilitarlo, è il default gratuito della API.
- **Fix del bug finestra incluso in questa fase**: stessa area di codice (`ContentView.body`, il contenitore sidebar/contenuto principale), ha senso chiuderlo insieme al resto della Fase 2 invece di riaprire il file per un intervento separato.
- **Fuori scope**: nessun cambio ai design token introdotti in Fase 1 (`AppColor`/`AppSpacing`/`AppFont`/`AppIconSize` restano identici, riusati così come sono); nessuna unificazione di componenti duplicati (`StatCard`/`CStat`, Fase 3); nessuna micro-interazione (`onHover`, `contentTransition`, Fase 4); nessuna migrazione `NSAlert`→SwiftUI (Fase 5); nessun cambio al pannello hamburger.

## Design tecnico

### 1. `SidebarView` da `HSplitView` a `NavigationSplitView`

`ContentView.body` oggi (semplificato):
```swift
ZStack(alignment: .leading) {
    HSplitView {
        SidebarView(volumes: volumes, runner: runner, showHamburger: $showHamburger)
            .frame(minWidth: 220, maxWidth: 260)
        VStack(spacing: 0) { /* toolbar HStack, SpeedLogPanel, StatsPanel condizionale, footer Esci */ }
    }
    if showHamburger { /* overlay invariato */ }
}
```

Diventa (struttura concettuale — i numeri di riga esatti e la sintassi Swift precisa vanno verificati/decisi in fase di piano contro il file reale):
```swift
ZStack(alignment: .leading) {
    NavigationSplitView(columnVisibility: /* .automatic, default nativo */) {
        SidebarView(volumes: volumes, runner: runner, showHamburger: $showHamburger)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
    } detail: {
        VStack(spacing: 0) { /* stesso contenuto di oggi, invariato */ }
            .frame(maxHeight: .infinity)  // fix del bug finestra
    }
    if showHamburger { /* overlay invariato */ }
}
```

Il contenuto di `SidebarView` e del `VStack` di dettaglio resta **esattamente lo stesso** (stessi `VolumeRow`/`OpsButton`/bottoni, nessun componente nuovo o modificato) — cambia solo il contenitore che li ospita. `SidebarView` stessa guadagna `.frame(maxHeight: .infinity)` al suo interno (o nel call site, da decidere in fase di piano guardando dove si applica più pulitamente) per completare il fix del bug finestra su entrambe le colonne.

### 2. Liquid Glass su sidebar e barra in alto

- **Sidebar**: lo sfondo di `SidebarView` (oggi `.background(.windowBackground)`) diventa un materiale Liquid Glass — su macOS 26 SDK, `.glassEffect()` applicato allo sfondo della view, oppure (se `.glassEffect()` risultasse non applicabile così com'è a un contenitore `VStack` pieno, da verificare in fase di piano con una build reale) un materiale equivalente (`.regularMaterial`/`.thinMaterial` con backdrop) — la scelta esatta dell'API va confermata contro la disponibilità reale in SwiftUI su questo target, il principio è "sidebar traslucida che reagisce al contenuto sottostante", non un'API specifica bloccante.
- **Barra in alto**: lo stesso trattamento sostituisce l'attuale `.background(.bar)` sull'`HStack` con "Pronto"/Log/Interrompi — nessun'altra modifica alla struttura di quell'`HStack`.

### 3. Fix del bug di dimensione finestra

`SidebarView` e il `VStack` di dettaglio guadagnano entrambi `.frame(maxHeight: .infinity)` (o modificatore equivalente da confermare in piano), così riempiono sempre la piena altezza della finestra indipendentemente dal contenuto condizionale (es. `StatsPanel` presente solo quando `runner.phase != .idle`) — stesso principio già applicato con successo a `HamburgerPanel`, che non soffre di questo bug.

## Testing

Nessuna nuova logica di business — solo struttura/contenitore/materiali. Nessun nuovo XCTest sensato (stesso ragionamento delle fasi precedenti). Suite esistente (79 test) va rieseguita dopo ogni task per assicurarsi che il cambio di contenitore non rompa nulla. **Verifica manuale richiesta** (non eseguibile in ambiente headless): aprire l'app, controllare che la finestra si riempia correttamente senza area vuota sia a job idle sia a job in corso; controllare che il pulsante di collasso sidebar nativo funzioni; controllare a occhio l'effetto vetro su sidebar e barra in alto in chiaro e scuro.

## Fuori scope

- Nessun cambio al pannello hamburger (`HamburgerPanel`) — resta l'overlay separato di oggi.
- Nessuna migrazione a `.toolbar()` nativa SwiftUI per la barra in alto.
- Nessun cambio ai design token di Fase 1.
- Nessuna unificazione di componenti duplicati (`StatCard`/`CStat`) — Fase 3.
- Nessuna micro-interazione (`onHover`, `contentTransition`, `symbolEffect`, skeleton) — Fase 4.
- Nessuna migrazione `NSAlert`→SwiftUI `.alert` — Fase 5.
