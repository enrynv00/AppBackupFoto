# App Icon Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sostituire l'App Icon attuale di AppBackupFoto (foto+montagna generica) con un'icona "Liquid Glass" — scudo geometrico sfaccettato blu→viola — e rimuovere l'asset di brand orfano non più referenziato.

**Architecture:** Un master SVG "full detail" (gradiente + luce dall'alto + facce in vetro con bordo + ombra) copre i 5 formati grandi (1024/512/256/128/64), renderizzato via Chrome headless direttamente alla risoluzione target (rendering vettoriale nativo, non downscale raster — niente perdita di dettaglio). Due varianti SVG semplificate (senza gradiente/bordo/ombra, solo forma piatta ad alta opacità) coprono i formati piccoli (32/16), dove il dettaglio fine smetterebbe di leggersi. Tutti i sorgenti SVG e lo script di rendering restano nel repo come fonte di verità riusabile.

**Tech Stack:** SVG statico, Chrome headless (`/Applications/Google Chrome.app`) per il rendering, `sips` per l'ispezione dei PNG generati (dimensioni/alpha), bash per lo script di rendering, Xcode/`xcodebuild` per la verifica finale.

## Global Constraints

- Solo asset (`Assets.xcassets`) e file di design sorgente — nessuna modifica a `ContentView.swift` o alla logica applicativa.
- `Contents.json` di `AppIcon.appiconset` resta invariato — stessi 7 nomi file (`icon_16.png` … `icon_1024.png`), nessuna entry aggiunta/rimossa.
- Build Xcode (`xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build`) deve restare verde dopo ogni task che tocca l'appiconset.
- I file sorgente di design (SVG, script di rendering) vanno committati insieme ai PNG generati — sono la fonte di verità riusabile per futuri aggiustamenti, non solo un artefatto temporaneo.
- Rendering verificato fattibile prima di questo piano: Chrome headless con `--default-background-color=00000000` produce PNG con alpha reale (confermato con un test manuale, non un'ipotesi).

---

## Task 1: Sorgenti SVG del design e script di rendering

**Files:**
- Create: `Docs/design/appicon/master-full.svg`
- Create: `Docs/design/appicon/master-small.svg`
- Create: `Docs/design/appicon/master-tiny.svg`
- Create: `Script/render-appicon.sh`

**Interfaces:**
- Consumes: nessuno (primo task, indipendente).
- Produces: `Script/render-appicon.sh <nessun argomento>` — quando eseguito, legge i 3 SVG e scrive 7 PNG dentro `AppBackupFoto/Assets.xcassets/AppIcon.appiconset/` (`icon_16.png` … `icon_1024.png`), sovrascrivendo quelli esistenti. Usato dal Task 2.

- [ ] **Step 1: Creare `Docs/design/appicon/master-full.svg`** (usato per 1024/512/256/128/64 — gradiente, luce dall'alto, facce in vetro con bordo, ombra morbida)

```bash
mkdir -p /Users/enriconannivicenzi/Desktop/AppBackupFoto/Docs/design/appicon
```

Contenuto esatto del file:

```xml
<svg width="100%" height="100%" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bgGrad" x1="0" y1="0" x2="0.3" y2="1">
      <stop offset="0%" stop-color="#4a6bff"/>
      <stop offset="55%" stop-color="#6d3bff"/>
      <stop offset="100%" stop-color="#3a1f8f"/>
    </linearGradient>
    <radialGradient id="topLight" cx="50%" cy="8%" r="70%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.35"/>
      <stop offset="45%" stop-color="#ffffff" stop-opacity="0.08"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="glassFill" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.55"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0.18"/>
    </linearGradient>
    <linearGradient id="glassFillDim" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.28"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0.08"/>
    </linearGradient>
    <filter id="softShadow" x="-50%" y="-50%" width="200%" height="200%">
      <feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#1a0d4d" flood-opacity="0.45"/>
    </filter>
  </defs>
  <rect x="4" y="4" width="172" height="172" rx="40" fill="url(#bgGrad)"/>
  <rect x="4" y="4" width="172" height="172" rx="40" fill="url(#topLight)"/>
  <g filter="url(#softShadow)">
    <path d="M90 32 L140 51 V97 C140 130 119 152 90 162 C61 152 40 130 40 97 V51 Z" fill="url(#glassFillDim)" stroke="#ffffff" stroke-opacity="0.35" stroke-width="1.3"/>
    <path d="M90 32 L140 51 L90 98 L40 51 Z" fill="url(#glassFill)" stroke="#ffffff" stroke-opacity="0.5" stroke-width="1"/>
    <path d="M90 32 V162 C119 152 140 130 140 97 V51 Z" fill="#ffffff" opacity="0.12"/>
  </g>
</svg>
```

- [ ] **Step 2: Creare `Docs/design/appicon/master-small.svg`** (usato solo per 32px — niente gradiente/bordo/ombra, due facce piatte a diversa opacità: a quella dimensione i dettagli fini smettono di leggersi, validato nel companion di brainstorming)

```xml
<svg width="100%" height="100%" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bgGrad" x1="0" y1="0" x2="0.3" y2="1">
      <stop offset="0%" stop-color="#4a6bff"/>
      <stop offset="55%" stop-color="#6d3bff"/>
      <stop offset="100%" stop-color="#3a1f8f"/>
    </linearGradient>
  </defs>
  <rect x="4" y="4" width="172" height="172" rx="40" fill="url(#bgGrad)"/>
  <path d="M90 32 L140 51 V97 C140 130 119 152 90 162 C61 152 40 130 40 97 V51 Z" fill="#ffffff" opacity="0.35"/>
  <path d="M90 32 L140 51 L90 98 L40 51 Z" fill="#ffffff" opacity="0.75"/>
</svg>
```

- [ ] **Step 3: Creare `Docs/design/appicon/master-tiny.svg`** (usato solo per 16px — un'unica forma piena, nessuna suddivisione in facce: a 16px anche due facce si fondono in una macchia indistinta)

```xml
<svg width="100%" height="100%" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bgGrad" x1="0" y1="0" x2="0.3" y2="1">
      <stop offset="0%" stop-color="#4a6bff"/>
      <stop offset="55%" stop-color="#6d3bff"/>
      <stop offset="100%" stop-color="#3a1f8f"/>
    </linearGradient>
  </defs>
  <rect x="4" y="4" width="172" height="172" rx="40" fill="url(#bgGrad)"/>
  <path d="M90 32 L140 51 V97 C140 130 119 152 90 162 C61 152 40 130 40 97 V51 Z" fill="#ffffff" opacity="0.9"/>
</svg>
```

- [ ] **Step 4: Creare `Script/render-appicon.sh`**

```bash
#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESIGN_DIR="$REPO_DIR/Docs/design/appicon"
ICONSET_DIR="$REPO_DIR/AppBackupFoto/Assets.xcassets/AppIcon.appiconset"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

render_size() {
  local svg_file="$1"
  local size="$2"
  local out_name="$3"
  local html_file="$TMP_DIR/wrap-${out_name%.png}.html"
  {
    printf '<!DOCTYPE html><html><head><style>html,body{margin:0;padding:0;background:transparent;width:%dpx;height:%dpx;overflow:hidden}</style></head><body>' "$size" "$size"
    cat "$svg_file"
    printf '</body></html>'
  } > "$html_file"

  "$CHROME" --headless --disable-gpu --force-device-scale-factor=1 \
    --default-background-color=00000000 --hide-scrollbars \
    --window-size="${size},${size}" \
    --screenshot="$ICONSET_DIR/$out_name" \
    "file://$html_file" >/dev/null 2>&1
}

render_size "$DESIGN_DIR/master-full.svg"  1024 icon_1024.png
render_size "$DESIGN_DIR/master-full.svg"  512  icon_512.png
render_size "$DESIGN_DIR/master-full.svg"  256  icon_256.png
render_size "$DESIGN_DIR/master-full.svg"  128  icon_128.png
render_size "$DESIGN_DIR/master-full.svg"  64   icon_64.png
render_size "$DESIGN_DIR/master-small.svg" 32   icon_32.png
render_size "$DESIGN_DIR/master-tiny.svg"  16   icon_16.png

echo "Rendered 7 icon sizes into $ICONSET_DIR"
```

```bash
chmod +x /Users/enriconannivicenzi/Desktop/AppBackupFoto/Script/render-appicon.sh
```

- [ ] **Step 5: Verificare che i 4 file esistano e lo script sia eseguibile**

```bash
ls -la /Users/enriconannivicenzi/Desktop/AppBackupFoto/Docs/design/appicon/ /Users/enriconannivicenzi/Desktop/AppBackupFoto/Script/render-appicon.sh
```

Expected: 3 file `.svg` elencati, e `render-appicon.sh` con permessi `-rwxr-xr-x` (o equivalente eseguibile).

- [ ] **Step 6: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add Docs/design/appicon/master-full.svg Docs/design/appicon/master-small.svg Docs/design/appicon/master-tiny.svg Script/render-appicon.sh
git commit -m "Add App Icon Liquid Glass design source + render script"
```

---

## Task 2: Generare i 7 PNG e verificarli

**Files:**
- Modify (sovrascritti dallo script): `AppBackupFoto/Assets.xcassets/AppIcon.appiconset/icon_16.png`, `icon_32.png`, `icon_64.png`, `icon_128.png`, `icon_256.png`, `icon_512.png`, `icon_1024.png`

**Interfaces:**
- Consumes: `Script/render-appicon.sh` e i 3 SVG dal Task 1.
- Produces: i 7 PNG rigenerati sono il file di input per la build Xcode nel Task 4 (nessuna funzione/API coinvolta, solo asset binari).

- [ ] **Step 1: Eseguire lo script di rendering**

```bash
/Users/enriconannivicenzi/Desktop/AppBackupFoto/Script/render-appicon.sh
```

Expected: `Rendered 7 icon sizes into /Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/Assets.xcassets/AppIcon.appiconset`

- [ ] **Step 2: Verificare dimensioni e canale alpha di tutti e 7 i PNG**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/Assets.xcassets/AppIcon.appiconset
for f in icon_16.png icon_32.png icon_64.png icon_128.png icon_256.png icon_512.png icon_1024.png; do
  echo "== $f =="
  sips -g hasAlpha -g pixelWidth -g pixelHeight "$f"
done
```

Expected: per ciascun file, `hasAlpha: yes` e `pixelWidth`/`pixelHeight` uguali al numero nel nome file (es. `icon_128.png` → 128/128).

- [ ] **Step 3: Ispezione visiva — leggere i PNG generati con il tool Read a 1024, 128 e 16px**

Aprire in sequenza con il tool Read:
- `/Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/Assets.xcassets/AppIcon.appiconset/icon_1024.png`
- `/Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/Assets.xcassets/AppIcon.appiconset/icon_128.png`
- `/Users/enriconannivicenzi/Desktop/AppBackupFoto/AppBackupFoto/Assets.xcassets/AppIcon.appiconset/icon_16.png`

Expected: a 1024px si vede lo scudo sfaccettato con gradiente blu→viola, luce dall'alto, bordo in vetro sulle due facce, ombra morbida sotto — coerente con la variante B approvata nel companion di brainstorming (`polish-v3.html`). A 128px stesso disegno, nitido. A 16px una forma piena bianca su sfondo blu/viola, ancora riconoscibile come scudo, nessun dettaglio illeggibile o "macchia" indistinta. Se una qualunque di queste condizioni non è soddisfatta, il task NON è completo — tornare al Task 1 e correggere l'SVG pertinente prima di proseguire.

- [ ] **Step 4: Commit**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
git add AppBackupFoto/Assets.xcassets/AppIcon.appiconset/
git commit -m "Regenerate AppIcon PNGs with Liquid Glass shield design"
```

---

## Task 3: Rimuovere l'asset orfano `appbackupfoto_icon.imageset`

**Files:**
- Delete: `AppBackupFoto/Assets.xcassets/appbackupfoto_icon.imageset/` (cartella intera: `Contents.json` + PNG)

**Interfaces:**
- Consumes: nessuno (indipendente dai Task 1/2).
- Produces: nessuna interfaccia consumata da altri task — verificato dal Task 4 (la build deve restare verde dopo la rimozione).

- [ ] **Step 1: Confermare che l'asset non sia referenziato da nessuna parte prima di cancellare**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
grep -rn "appbackupfoto_icon" --include="*.swift" --include="*.plist" --include="*.pbxproj" .
```

Expected: nessun risultato (già verificato in fase di ricerca durante il brainstorming, questo step è la riconferma immediatamente prima della cancellazione).

- [ ] **Step 2: Rimuovere la cartella**

```bash
git rm -r AppBackupFoto/Assets.xcassets/appbackupfoto_icon.imageset
```

- [ ] **Step 3: Verificare che sia sparita dal working tree**

```bash
ls AppBackupFoto/Assets.xcassets/ | grep appbackupfoto_icon || echo "RIMOSSO"
```

Expected: `RIMOSSO`

- [ ] **Step 4: Commit**

```bash
git commit -m "Remove orphaned appbackupfoto_icon.imageset asset (unreferenced)"
```

---

## Task 4: Build finale e verifica end-to-end

**Files:** nessuno creato/modificato — solo verifica.

**Interfaces:**
- Consumes: output dei Task 1, 2, 3 (PNG rigenerati + asset orfano rimosso).
- Produces: nessuno (task terminale del piano).

- [ ] **Step 1: Build Xcode pulita**

```bash
cd /Users/enriconannivicenzi/Desktop/AppBackupFoto
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug clean build 2>&1 | tail -20
```

Expected: ultima riga `** BUILD SUCCEEDED **`, nessun errore relativo a `AppIcon` o asset mancanti.

- [ ] **Step 2: Verificare che `Contents.json` di AppIcon.appiconset referenzi ancora esattamente i 7 filename attesi**

```bash
grep -o '"filename" *: *"[^"]*"' AppBackupFoto/Assets.xcassets/AppIcon.appiconset/Contents.json | sort -u
```

Expected: esattamente queste 7 righe (nessuna aggiunta/rimossa rispetto a prima del redesign):
```
"filename": "icon_1024.png"
"filename": "icon_128.png"
"filename": "icon_16.png"
"filename": "icon_256.png"
"filename": "icon_32.png"
"filename": "icon_512.png"
"filename": "icon_64.png"
```

- [ ] **Step 3: Verifica finale `git status`**

```bash
git status --short
```

Expected: working tree pulito (nessun file modificato non committato).

- [ ] **Step 4: Nota per la verifica manuale (non automatizzabile da qui)**

Non eseguire questo step via tool — è una richiesta esplicita per Enrico, da riportare a fine piano: dopo aver installato la build su `/Applications` (Product → Archive → Distribute → Custom → Copy App, come da `Docs/CLAUDE.md` → "Build e distribuzione"), controllare a occhio l'icona reale nel Dock e in Launchpad (sfondo scuro/chiaro del sistema), non solo l'anteprima in Xcode/Assets.xcassets.
