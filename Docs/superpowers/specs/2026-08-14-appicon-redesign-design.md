# Redesign App Icon

Data: 2026-08-14

## Problema

L'App Icon attuale (`Assets.xcassets/AppIcon.appiconset`) è l'icona generica "foto con montagna in cornice" in stile Photos.app, con un piccolo badge viola in alto a destra pensato per rappresentare il cloud (Cubbit S3) ma che si legge più come un disco volante/cappello che come una nuvola. Enrico l'ha definita outdated e non più rappresentativa di cosa fa davvero l'app oggi: un sistema di backup su 3 destinazioni (Mac→SSD, SSD→HDD, SSD→Cubbit S3) con restore guidato — non una semplice galleria foto.

Coincide temporalmente con la Fase 2 del piano di design polish dell'app (`2026-08-12-structure-liquid-glass-design.md`, roadmap #22), che introduce materiali Liquid Glass reali (`.glassEffect()`) nella UI. Il redesign dell'icona riusa lo stesso linguaggio visivo per coerenza con il resto dell'app, non per moda.

## Decisioni prese in brainstorming

Esplorati due round di direzioni visive nel companion browser (`.superpowers/brainstorm/`):

- **Round 1 (concetto)**: scartata l'idea di restare centrati sulle foto — l'icona deve comunicare **protezione/backup**, non più "galleria immagini". Tra le metafore visive proposte (scudo, strati/copie, cassaforte, nodi collegati), scelta **nodi collegati** in prima battuta, poi superata nel round successivo quando è emerso che il vero problema era il livello di finitura, non il concetto.
- **Round 2 (finitura)**: le prime bozze (forme piatte, cerchietti bianchi con icone dentro) sono state respinte come non abbastanza curate ("non ci siamo ancora, il design è sommario"). Rifatte in stile **Liquid Glass** (pannelli traslucidi, luce dall'alto, bordo con highlight, ombra morbida) — stesso linguaggio della Fase 2 UI. Tra due varianti Liquid Glass proposte (A: copie a strati con spunta di verifica, B: scudo geometrico sfaccettato), **scelta la B**: uno scudo con facce diverse come un diamante, senza simboli/icone interne — la scelta più minimale e "premium" delle due, il concetto di protezione comunicato dalla forma stessa invece che da un'icona dentro.
- **Colore**: confermato il gradiente blu→viola già usato nei mockup (continuità con l'identità cromatica attuale dell'app, eseguito con maggiore raffinatezza — gradiente multi-stop + luce radiale dall'alto invece di un gradiente lineare piatto).
- **Verifica leggibilità**: testato a 128/64/32/16px nel companion — lo scudo B, non avendo dettagli interni, resta un simbolo pulito e riconoscibile anche al minimo formato (a differenza della variante A, dove i 3 strati si fondono in una massa bianca a 16px).
- **Scope**: verificato con un agente di ricerca che l'unico punto del codice/asset che usa davvero il logo è `AppIcon.appiconset` — il menu bar (`MenuBarIcon`, `ContentView.swift:136-142`) usa un SF Symbol di sistema (`photo.stack`), non un asset custom, e non serve toccarlo. Nessun logo referenziato nello script di build/DMG/notarizzazione.
- **Asset orfano**: trovato `Assets.xcassets/appbackupfoto_icon.imageset` (PNG 512×512), non referenziato da nessuna parte nel codice, plist o build settings. Enrico ha confermato: è residuo, va rimosso insieme a questo lavoro.

## Design tecnico

### Forma e composizione

Scudo geometrico a 3 facce (come un diamante/gemma), non un contorno con simboli dentro:

- Contorno scudo: punta in alto, base arrotondata in basso (stessa proporzione dei mockup approvati: apice a ~18% dall'alto del canvas, base a ~90%)
- Faccia superiore (la "punta" del diamante, dal apice fino a circa metà altezza): riempimento vetro più chiaro/opaco (`glassFill`, opacity 0.5–0.55), il punto di massima luce
- Faccia laterale destra (dalla metà alla base): riempimento vetro più scuro/trasparente (`glassFillDim`, opacity 0.18–0.28), effetto di ombra propria che dà volume 3D senza bisogno di un vero renderer 3D
- Overlay verticale sinistro (opacity ~0.12): striscia di luce che separa le due facce, rinforza la sensazione di sfaccettatura
- Bordo: stroke bianco sottile (1–1.3px a scala 180, opacity 0.35–0.5) su ogni faccia, per il caratteristico "edge highlight" del vetro
- Ombra: drop shadow morbida sotto lo scudo (blur ~8, offset y ~6, colore viola scuro `#1a0d4d` opacity 0.45) per staccarlo dallo sfondo

### Sfondo (squircle)

- Rounded rect con `rx` ≈ 22% del lato (stesso rapporto delle icone macOS post-Big Sur, coerente con l'icona attuale)
- Gradiente lineare 3-stop: `#4a6bff` (0%) → `#6d3bff` (55%) → `#3a1f8f` (100%), diagonale dall'alto verso il basso
- Overlay radiale di luce dall'alto (`topLight`, centro al 50%/8%, raggio 70%, bianco da 0.35 a 0 di opacity) per simulare la luce che colpisce un'icona macOS reale, non un gradiente piatto

### File da produrre

Stesso `Contents.json` esistente (nessuna modifica strutturale), rigenerati i 7 PNG sorgente da un unico file vettoriale master ad alta fedeltà:

| File | Dimensione |
|---|---|
| icon_16.png | 16×16 |
| icon_32.png | 32×32 |
| icon_64.png | 64×64 |
| icon_128.png | 128×128 |
| icon_256.png | 256×256 |
| icon_512.png | 512×512 |
| icon_1024.png | 1024×1024 |

Il master vettoriale useprà gli stessi elementi già validati nel companion (gradienti, blur, drop shadow) — il piano di implementazione dovrà verificare quale strumento disponibile sulla macchina rasterizza l'SVG preservando fedelmente questi filtri (es. Chrome headless, che ha supporto completo delle SVG filter primitives usate; da evitare tool con supporto filtri parziale/assente come `cairosvg`). Ai formati più piccoli (16/32px) potrebbe servire un aggiustamento manuale di opacity/contrasto per restare leggibili — verificato nel companion che la forma stessa (senza dettagli interni) regge bene la riduzione, ma la resa esatta va confermata sui PNG reali, non solo sul preview browser.

### Rimozione asset orfano

Cancellare `AppBackupFoto/Assets.xcassets/appbackupfoto_icon.imageset/` (cartella intera, PNG + Contents.json) — non referenziato da codice, plist o `.pbxproj`.

## Testing

Nessuna logica applicativa toccata, solo asset. Verifica:

- Build Xcode verde dopo la sostituzione (`xcodebuild ... build`)
- Icona corretta in Finder (Assets.xcassets preview), Dock, Launchpad dopo rebuild + reinstallazione
- Controllo visivo diretto dei 7 PNG generati a ciascuna dimensione (non solo il preview 1024px), sia in chiaro sia in scuro (lo sfondo scuro del Dock/Launchpad è il contesto reale, testato anche nel companion)
- Verifica che la rimozione di `appbackupfoto_icon.imageset` non rompa la build (già confermato che non è referenziato, ma va ri-verificato con una build reale dopo la cancellazione)

## Fuori scope

- Menu bar icon (`MenuBarIcon`, SF Symbol `photo.stack`) — resta invariata, non è un asset brandizzato
- Qualsiasi altro elemento UI dell'app (pulsanti, header, ecc.) — questo lavoro riguarda solo l'App Icon
- Variante "A" (copie a strati con spunta), scartata in brainstorming a favore della B
- Direzione "nodi collegati" del Round 1, superata dal Round 2
