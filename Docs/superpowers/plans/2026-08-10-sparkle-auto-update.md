# Auto-update con Sparkle (roadmap #18) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggiungere l'auto-update via Sparkle 2.x (SPM) ad AppBackupFoto: check automatico in background + voce manuale, firma EdDSA, appcast/release ospitati su un futuro repo GitHub pubblico, script di release che automatizza build→firma→pubblicazione.

**Architecture:** `SPUStandardUpdaterController` di Sparkle, wrappato in un piccolo `ObservableObject` (`UpdaterViewModel`) per poter essere iniettato nell'ambiente SwiftUI come `runner`. Nessuna UI custom: l'alert di aggiornamento è quello standard di Sparkle. Configurazione via `Info.plist` fisico (il target passa da `GENERATE_INFOPLIST_FILE = YES` a un file reale, necessario per avere `SUEnableAutomaticChecks`/`SUScheduledCheckInterval` tipizzati correttamente come booleano/intero). Pubblicazione automatizzata da `Script/release.sh`, che firma con `sign_update` e inserisce a mano il nuovo `<item>` in `appcast.xml` (non si usa `generate_appcast` in modalità batch: richiederebbe un unico `--download-url-prefix` uniforme, incompatibile con gli URL per-tag di GitHub Releases).

**Tech Stack:** SwiftUI, Sparkle 2.x (Swift Package Manager), bash, `gh` CLI, Python 3 (solo per l'edit chirurgico di `project.pbxproj` e `appcast.xml`, non aggiunto come dipendenza runtime).

## Global Constraints

- Zero delete, zero overwrite, read-only sulla sorgente — questa feature non tocca mai file di foto; vale comunque come vincolo di progetto per ogni file toccato (mai sovrascrivere silenziosamente `appcast.xml` invece di fare append).
- Mai committare segreti: `eddsa-private-key-backup.txt` (nuovo), `Script/sparkle-tools/` (tool scaricati), `build/` (archivi/zip locali) vanno in `.gitignore` — accanto a `Log/`, `Script/*.log`, `Script/*.csv` già esistenti.
- Repo GitHub **pubblico** (deciso in brainstorming) — nessun dato personale nel codice, già garantito da quanto sopra.
- L'installazione di un update richiede sempre un click esplicito dell'utente sull'alert standard di Sparkle — mai silenziosa (coerente con le altre regole "mai azioni automatiche senza conferma" del progetto).
- Il file principale del target app resta `ContentView.swift` (convenzione assoluta del progetto) — nessun nuovo file `.swift` va creato per questa feature, solo modifiche dentro `ContentView.swift`.
- L'unico punto che cambierà quando arriverà #19 (notarization/Developer ID) è il metodo di esportazione dentro `Script/release.sh` (oggi: copia diretta dall'archivio, firma ad-hoc) — non introdurre altre dipendenze dalla firma ad-hoc attuale altrove.
- `<github-username>` è un placeholder noto e accettato (l'utente non ha ancora un account GitHub) — usare letteralmente la stringa `PLACEHOLDER-github-username` ovunque serva l'URL reale; verrà sostituita in un secondo momento, vedi Task 8.
- Nota tecnica per manutenzione futura di questo piano: il target `AppBackupFotoTests` non ha un gruppo file-system-synchronized — un nuovo file di test aggiunto senza registrarlo a mano in `project.pbxproj` (PBXBuildFile/PBXFileReference/gruppo/Sources build phase) resta silenziosamente escluso dalla suite. Questo piano non aggiunge nuovi file di test (nessuna logica pura isolabile in questa feature, stesso ragionamento già applicato a #11/#15/#16), ma la suite esistente (79 test) va comunque rieseguita dopo ogni task che tocca build settings o l'entry point dell'app, per assicurarsi che nulla si sia rotto.

---

### Task 1: Aggiungere Sparkle come dipendenza SPM al progetto Xcode

**Files:**
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: il modulo `Sparkle` linkato e importabile (`import Sparkle`) dal target `AppBackupFoto`. Nessuna API pubblica nostra ancora — solo la dipendenza risolta.

- [ ] **Step 1: Verifica lo stato pulito del repo prima di modificare il file di progetto**

```bash
git status
```
Expected: working tree pulito (nessuna modifica in sospeso) — se non lo è, fermati e chiedi prima di continuare.

- [ ] **Step 2: Esegui lo script Python che aggiunge il riferimento al pacchetto Sparkle**

Crea ed esegui questo script (una tantum, non va committato):

```bash
python3 - <<'PYEOF'
import re, uuid, pathlib

path = pathlib.Path("AppBackupFoto.xcodeproj/project.pbxproj")
text = path.read_text()

def new_id():
    return uuid.uuid4().hex[:24].upper()

pkg_ref_id = new_id()
product_dep_id = new_id()
build_file_id = new_id()

# 1. PBXBuildFile per il prodotto Sparkle
anchor1 = '\t\t3CF547AB089EA250EFD3FC89 /* Cocoa.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = 52AB12F7AD7661DE5D3BEC12 /* Cocoa.framework */; };\n'
assert anchor1 in text, "anchor1 non trovato"
text = text.replace(
    anchor1,
    anchor1 + f'\t\t{build_file_id} /* Sparkle in Frameworks */ = {{isa = PBXBuildFile; productRef = {product_dep_id} /* Sparkle */; }};\n'
)

# 2. Frameworks build phase del target app: aggiungi il build file
anchor2 = '\t\t695F43342EB019B300509478 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n'
assert anchor2 in text, "anchor2 non trovato"
text = text.replace(
    anchor2,
    '\t\t695F43342EB019B300509478 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n'
    f'\t\t\t\t{build_file_id} /* Sparkle in Frameworks */,\n\t\t\t);\n'
)

# 3. PBXNativeTarget app: aggiungi packageProductDependencies
anchor3 = '\t\t\tname = AppBackupFoto;\n\t\t\tproductName = AppBackupFoto;\n'
assert anchor3 in text, "anchor3 non trovato"
text = text.replace(
    anchor3,
    f'\t\t\tname = AppBackupFoto;\n\t\t\tpackageProductDependencies = (\n\t\t\t\t{product_dep_id} /* Sparkle */,\n\t\t\t);\n\t\t\tproductName = AppBackupFoto;\n'
)

# 4. PBXProject: aggiungi packageReferences
anchor4 = '\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpreferredProjectObjectVersion = 77;\n'
assert anchor4 in text, "anchor4 non trovato"
text = text.replace(
    anchor4,
    f'\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpackageReferences = (\n\t\t\t\t{pkg_ref_id} /* XCRemoteSwiftPackageReference "Sparkle" */,\n\t\t\t);\n\t\t\tpreferredProjectObjectVersion = 77;\n'
)

# 5. Nuove sezioni XCRemoteSwiftPackageReference / XCSwiftPackageProductDependency in coda al file
anchor5 = '/* End XCConfigurationList section */\n\t};\n\trootObject = 695F432F2EB019B300509478 /* Project object */;\n}\n'
assert anchor5 in text, "anchor5 non trovato"
new_tail = (
    '/* End XCConfigurationList section */\n\n'
    '/* Begin XCRemoteSwiftPackageReference section */\n'
    f'\t\t{pkg_ref_id} /* XCRemoteSwiftPackageReference "Sparkle" */ = {{\n'
    '\t\t\tisa = XCRemoteSwiftPackageReference;\n'
    '\t\t\trepositoryURL = "https://github.com/sparkle-project/Sparkle";\n'
    '\t\t\trequirement = {\n'
    '\t\t\t\tkind = upToNextMajorVersion;\n'
    '\t\t\t\tminimumVersion = 2.0.0;\n'
    '\t\t\t};\n'
    '\t\t};\n'
    '/* End XCRemoteSwiftPackageReference section */\n\n'
    '/* Begin XCSwiftPackageProductDependency section */\n'
    f'\t\t{product_dep_id} /* Sparkle */ = {{\n'
    '\t\t\tisa = XCSwiftPackageProductDependency;\n'
    f'\t\t\tpackage = {pkg_ref_id} /* XCRemoteSwiftPackageReference "Sparkle" */;\n'
    '\t\t\tproductName = Sparkle;\n'
    '\t\t};\n'
    '/* End XCSwiftPackageProductDependency section */\n'
    '\t};\n'
    '\trootObject = 695F432F2EB019B300509478 /* Project object */;\n'
    '}\n'
)
text = text.replace(anchor5, new_tail)

path.write_text(text)
print("OK — pkg_ref_id:", pkg_ref_id, "product_dep_id:", product_dep_id, "build_file_id:", build_file_id)
PYEOF
```

Expected: stampa `OK — pkg_ref_id: ... product_dep_id: ... build_file_id: ...` senza errori di `assert`. Se un `assert` fallisce, il file non è stato toccato (fallisce prima del write) — non serve rollback, ma va indagato perché l'anchor non corrisponde più prima di riprovare.

- [ ] **Step 3: Risolvi il pacchetto**

```bash
xcodebuild -resolvePackageDependencies -project AppBackupFoto.xcodeproj -scheme AppBackupFoto
```
Expected: termina con `Resolved source packages:` seguito da una riga `Sparkle - Version ...` (2.x). Richiede rete raggiungibile verso github.com.

- [ ] **Step 4: Verifica che il progetto compili con la dipendenza linkata (nessun uso nel codice ancora)**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

Se il build fallisce in modo non banale (non un semplice errore di sintassi Swift altrove): `git checkout -- AppBackupFoto.xcodeproj/project.pbxproj`, poi aggiungi Sparkle manualmente da Xcode (File → Add Package Dependencies → `https://github.com/sparkle-project/Sparkle`) prima di continuare — non insistere oltre un secondo tentativo con l'editing testuale.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add Sparkle as SPM dependency (roadmap #18)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Chiave EdDSA + Info.plist fisico con le chiavi Sparkle

**Files:**
- Create: `AppBackupFoto/Info.plist`
- Create: `Script/ensure-sparkle-tools.sh`
- Create: `eddsa-private-key-backup.txt` (generato, non committato)
- Modify: `AppBackupFoto.xcodeproj/project.pbxproj` (Debug + Release build settings del target app)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nessuna (primo task che tocca la configurazione Sparkle).
- Produces: `SUPublicEDKey` reale in `Info.plist`; chiave privata nel Keychain di questa macchina (voce standard di Sparkle); `Script/sparkle-tools/bin/{generate_keys,sign_update,generate_appcast}` disponibili localmente per i task successivi e per `Script/release.sh`.

- [ ] **Step 1: Aggiorna `.gitignore` PRIMA di generare qualunque file sensibile**

```
# Auto-update (roadmap #18): chiave privata EdDSA, tool CLI Sparkle scaricati, output di release — mai in git
eddsa-private-key-backup.txt
Script/sparkle-tools/
build/
```

Aggiungi queste tre righe in fondo a `.gitignore` (che oggi termina con `Script/*.csv`).

- [ ] **Step 2: Crea `Script/ensure-sparkle-tools.sh`**

```bash
#!/usr/bin/env bash
# Scarica i tool CLI ufficiali di Sparkle (generate_keys, sign_update, generate_appcast)
# se non sono già presenti. Idempotente: non ri-scarica se già presenti.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/Script/sparkle-tools"
BIN_DIR="$TOOLS_DIR/bin"

if [ -x "$BIN_DIR/sign_update" ] && [ -x "$BIN_DIR/generate_keys" ] && [ -x "$BIN_DIR/generate_appcast" ]; then
  exit 0
fi

echo "==> Scarico i tool CLI di Sparkle..."
mkdir -p "$TOOLS_DIR"
DOWNLOAD_URL="$(curl -s https://api.github.com/repos/sparkle-project/Sparkle/releases/latest \
  | grep browser_download_url | grep -o 'https://[^"]*\.tar\.xz' | head -1)"
if [ -z "$DOWNLOAD_URL" ]; then
  echo "ERRORE: non ho trovato l'asset .tar.xz nell'ultima release di Sparkle su GitHub." >&2
  exit 1
fi
curl -L "$DOWNLOAD_URL" -o "$TOOLS_DIR/sparkle.tar.xz"
tar -xf "$TOOLS_DIR/sparkle.tar.xz" -C "$TOOLS_DIR"
rm "$TOOLS_DIR/sparkle.tar.xz"

if [ ! -x "$BIN_DIR/sign_update" ] || [ ! -x "$BIN_DIR/generate_keys" ]; then
  echo "ERRORE: tool attesi non trovati dopo l'estrazione in $TOOLS_DIR" >&2
  exit 1
fi
echo "==> Tool Sparkle pronti in $BIN_DIR"
```

```bash
chmod +x Script/ensure-sparkle-tools.sh
Script/ensure-sparkle-tools.sh
```
Expected: alla prima esecuzione, stampa `==> Scarico i tool CLI di Sparkle...` poi `==> Tool Sparkle pronti in .../Script/sparkle-tools/bin`. Rieseguendolo subito dopo: nessun output, uscita silenziosa (già presenti).

- [ ] **Step 3: Genera la coppia di chiavi EdDSA e cattura la chiave pubblica**

```bash
Script/sparkle-tools/bin/generate_keys | tee /tmp/sparkle-generate-keys-output.txt
PUBLIC_KEY="$(grep -o '<string>[A-Za-z0-9+/=]\{40,\}</string>' /tmp/sparkle-generate-keys-output.txt | sed -E 's#</?string>##g' | head -1)"
echo "Chiave pubblica catturata: $PUBLIC_KEY"
```
Expected: `generate_keys` stampa conferma che la chiave è stata salvata nel Keychain, con un blocco XML pronto da incollare contenente `<key>SUPublicEDKey</key>` seguito da `<string>...</string>`. La variabile `$PUBLIC_KEY` deve risultare non vuota (una stringa base64 lunga). Se `PUBLIC_KEY` è vuota, apri `/tmp/sparkle-generate-keys-output.txt` e individua manualmente la chiave: il formato esatto dell'output può differire leggermente tra versioni di Sparkle, ma la chiave pubblica è sempre il valore da mettere nel tag `<string>` accanto a `SUPublicEDKey`.

- [ ] **Step 4: Backup esplicito della chiave privata (passo obbligatorio, non opzionale — vedi spec)**

```bash
Script/sparkle-tools/bin/generate_keys -x eddsa-private-key-backup.txt
cat eddsa-private-key-backup.txt
```
Expected: il file viene creato nella root del repo e contiene la chiave privata in chiaro (base64). Verifica che `git status` lo mostri come ignorato (non compare in `git status` di default perché matcha `.gitignore` aggiunto allo Step 1) — se compare come untracked, **fermati**: significa che `.gitignore` non è stato applicato correttamente, non procedere a committare nulla finché non è risolto.

**Dì esplicitamente all'utente, a fine task**: questo file va copiato ora in un posto sicuro fuori dal repo (password manager, backup cifrato) — se questo Mac si perde senza quella copia, le versioni dell'app già distribuite non potranno più fidarsi di aggiornamenti futuri.

- [ ] **Step 5: Crea `AppBackupFoto/Info.plist`**

Sostituisci `PUBLIC_KEY_QUI` con il valore reale catturato allo Step 3.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>it</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSMinimumSystemVersion</key>
	<string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>NSHumanReadableCopyright</key>
	<string></string>
	<key>SUFeedURL</key>
	<string>https://raw.githubusercontent.com/PLACEHOLDER-github-username/AppBackupFoto/main/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>PUBLIC_KEY_QUI</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
</dict>
</plist>
```

Questo elenco di chiavi replica esattamente quanto oggi genera automaticamente Xcode per questo target (verificato ispezionando l'`Info.plist` già buildato in DerivedData: `CFBundleDevelopmentRegion=it`, `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleInfoDictionaryVersion=6.0`, `CFBundleName`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString`, `CFBundleVersion`, `LSMinimumSystemVersion`), più le 4 chiavi nuove di Sparkle. `CFBundleIconFile`/`CFBundleIconName` non vanno aggiunti a mano: li inietta automaticamente il compilatore di asset catalog (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, già impostato) indipendentemente da come è generato l'Info.plist.

- [ ] **Step 6: Passa il target da Info.plist generato a Info.plist fisico**

In `AppBackupFoto.xcodeproj/project.pbxproj` sostituisci (compare due volte, identica, in Debug e Release — sostituisci **entrambe** le occorrenze):

Testo da cercare:
```
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
```

Testo sostitutivo:
```
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = AppBackupFoto/Info.plist;
```

- [ ] **Step 7: Build e verifica che l'Info.plist generato nell'app finale sia corretto**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
BUILT_APP="$(xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/AppBackupFoto.app"
plutil -p "$BUILT_APP/Contents/Info.plist"
```
Expected: `** BUILD SUCCEEDED **`, e l'output di `plutil -p` mostra tutte le chiavi originali (`CFBundleIdentifier => "enri.AppBackupFoto"`, `CFBundleShortVersionString => "1.0"`, `CFBundleIconName => "AppIcon"`, ecc.) più le 4 nuove: `SUFeedURL`, `SUPublicEDKey` (con il valore reale, non `PUBLIC_KEY_QUI`), `SUEnableAutomaticChecks => 1` (booleano, non stringa `"YES"`), `SUScheduledCheckInterval => 86400` (numero, non stringa).

Se `SUEnableAutomaticChecks`/`SUScheduledCheckInterval` compaiono come stringhe invece che come booleano/numero: il problema è nel file `Info.plist` scritto allo Step 5 (verifica che `<true/>` e `<integer>86400</integer>` non siano stati scritti per errore come `<string>`).

- [ ] **Step 8: Rilancia l'intera suite di test per verificare che il cambio di Info.plist non abbia rotto nulla**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: tutti i 79 test esistenti passano (nessuna regressione — questo task non ne aggiunge di nuovi).

- [ ] **Step 9: Verifica che nessun segreto sia stato messo in stage per errore, poi commit**

```bash
git status
```
Expected: `eddsa-private-key-backup.txt` NON compare (ignorato); `Script/sparkle-tools/` NON compare; compaiono come modificati/nuovi solo `.gitignore`, `AppBackupFoto.xcodeproj/project.pbxproj`, `AppBackupFoto/Info.plist`, `Script/ensure-sparkle-tools.sh`.

```bash
git add .gitignore AppBackupFoto.xcodeproj/project.pbxproj AppBackupFoto/Info.plist Script/ensure-sparkle-tools.sh
git commit -m "$(cat <<'EOF'
Add EdDSA public key and physical Info.plist for Sparkle (roadmap #18)

Switched from GENERATE_INFOPLIST_FILE to a physical Info.plist so
SUEnableAutomaticChecks/SUScheduledCheckInterval get correct
Boolean/Number types. SUFeedURL uses a placeholder GitHub username
until the user creates the account (see plan Task 8).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Istanziare l'updater Sparkle in `BackupFotoEnricoApp`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift:1-44`

**Interfaces:**
- Consumes: `import Sparkle` (Task 1), `SUFeedURL`/`SUPublicEDKey` in Info.plist (Task 2).
- Produces: `final class UpdaterViewModel: ObservableObject { let controller: SPUStandardUpdaterController }`, iniettato come `environmentObject` sulla `WindowGroup(id: "main")` — consumato da `HamburgerPanel` in Task 4.

`SPUStandardUpdaterController` non è esso stesso un `ObservableObject` (è una classe Sparkle pensata per AppKit/generica) — per poterlo iniettare con `.environmentObject` serve un piccolo wrapper nostro, non un dettaglio opzionale.

- [ ] **Step 1: Aggiungi l'import in cima al file**

In `ContentView.swift`, riga 1-8, aggiungi `import Sparkle` accanto agli import esistenti:

```swift
import SwiftUI
import Combine
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import CryptoKit
import Charts
import ImageIO
import Sparkle
```

- [ ] **Step 2: Aggiungi `UpdaterViewModel` e collegalo all'App**

Sostituisci il blocco attuale (righe 10-44):

```swift
// MARK: - App entry
@main
struct BackupFotoEnricoApp: App {
    @StateObject private var runner = BackupRunner()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(runner)
                .frame(minWidth: 960, minHeight: 620)
        }
        Window("Diagnostica", id: "tools") {
            ToolsSheet()
                .environmentObject(runner)
        }
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentSize)

        Window("Catalogo", id: "catalog") {
            CatalogView()
                .environmentObject(runner)
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(runner)
        } label: {
            MenuBarIcon()
                .environmentObject(runner)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

con:

```swift
// MARK: - App entry
final class UpdaterViewModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}

@main
struct BackupFotoEnricoApp: App {
    @StateObject private var runner = BackupRunner()
    @StateObject private var updater = UpdaterViewModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(runner)
                .environmentObject(updater)
                .frame(minWidth: 960, minHeight: 620)
        }
        Window("Diagnostica", id: "tools") {
            ToolsSheet()
                .environmentObject(runner)
        }
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentSize)

        Window("Catalogo", id: "catalog") {
            CatalogView()
                .environmentObject(runner)
        }
        .defaultSize(width: 720, height: 520)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(runner)
        } label: {
            MenuBarIcon()
                .environmentObject(runner)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

`startingUpdater: true` fa sì che Sparkle avvii da solo il ciclo di check automatico (`SUEnableAutomaticChecks`/`SUScheduledCheckInterval` da Info.plist) non appena l'app parte — nessun altro codice nostro deve orchestrarlo. Solo `WindowGroup(id: "main")` riceve `.environmentObject(updater)`: le finestre Diagnostica/Catalogo/menu bar non ne hanno bisogno per questo task.

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. Se fallisce con un errore su `SPUStandardUpdaterController` non trovato, verifica che Task 1 sia stato completato (pacchetto risolto) e che il modulo si chiami esattamente `Sparkle`.

- [ ] **Step 4: Rilancia la suite di test (l'entry point dell'app è cambiato)**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: 79 test verdi, nessuna regressione.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Wire SPUStandardUpdaterController into app entry point (roadmap #18)

UpdaterViewModel wraps Sparkle's controller as an ObservableObject
so it can be injected via .environmentObject like the existing
runner — SPUStandardUpdaterController itself doesn't conform to
ObservableObject. startingUpdater: true lets Sparkle drive its own
background check schedule from Info.plist, no orchestration needed
here.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Voce "Controlla aggiornamenti" in `HamburgerPanel`

**Files:**
- Modify: `AppBackupFoto/ContentView.swift` (`HamburgerPanel`, intorno alla riga 3169-3176, dopo la riga "Catalogo")

**Interfaces:**
- Consumes: `UpdaterViewModel` (Task 3) via `@EnvironmentObject`.
- Produces: nessuna nuova interfaccia — foglia della catena.

- [ ] **Step 1: Aggiungi la dichiarazione dell'environment object**

In `HamburgerPanel` (dopo `@EnvironmentObject private var runner: BackupRunner` alla riga 3095):

```swift
    @EnvironmentObject private var runner: BackupRunner
    @EnvironmentObject private var updater: UpdaterViewModel
```

- [ ] **Step 2: Aggiungi la riga di menu, subito dopo "Catalogo" e prima della sezione "Preferenze"**

Codice attuale (righe 3169-3176):

```swift
                        HamburgerRow(icon: "magnifyingglass", label: "Catalogo", iconColor: .indigo) {
                            Task {
                                await runner.loadS3ConfigIfNeeded()
                                await MainActor.run { openWindow(id: "catalog") }
                            }
                        }

                        HamburgerSectionLabel("Preferenze").padding(.top, 6)
```

Sostituisci con:

```swift
                        HamburgerRow(icon: "magnifyingglass", label: "Catalogo", iconColor: .indigo) {
                            Task {
                                await runner.loadS3ConfigIfNeeded()
                                await MainActor.run { openWindow(id: "catalog") }
                            }
                        }
                        HamburgerRow(icon: "arrow.triangle.2.circlepath", label: "Controlla aggiornamenti", iconColor: .cyan) {
                            updater.controller.checkForUpdates(nil)
                        }

                        HamburgerSectionLabel("Preferenze").padding(.top, 6)
```

(`.cyan` non è ancora usato da nessun'altra `HamburgerRow` — colori già in uso: `.blue`, `.green`, `Color(NSColor.systemGray)`, `.purple`, `.indigo`, `.orange`, `.teal`.)

- [ ] **Step 3: Build**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Rilancia la suite di test**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: 79 test verdi.

- [ ] **Step 5: Commit**

```bash
git add AppBackupFoto/ContentView.swift
git commit -m "$(cat <<'EOF'
Add manual "Controlla aggiornamenti" entry to HamburgerPanel (roadmap #18)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Skeleton iniziale di `appcast.xml`

**Files:**
- Create: `appcast.xml` (root del repo)

**Interfaces:**
- Consumes: nessuna.
- Produces: file con un anchor testuale stabile (`<language>it</language>`) che `Script/release.sh` (Task 6) userà per inserire nuovi `<item>`.

- [ ] **Step 1: Crea `appcast.xml` nella root del repo**

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>AppBackupFoto</title>
        <link>https://raw.githubusercontent.com/PLACEHOLDER-github-username/AppBackupFoto/main/appcast.xml</link>
        <description>Aggiornamenti di AppBackupFoto</description>
        <language>it</language>
    </channel>
</rss>
```

- [ ] **Step 2: Verifica che sia XML valido**

```bash
xmllint --noout appcast.xml && echo "XML valido"
```
Expected: `XML valido`. Se `xmllint` non è installato, salta questo step (non blocca il resto del task).

- [ ] **Step 3: Commit**

```bash
git add appcast.xml
git commit -m "$(cat <<'EOF'
Add initial appcast.xml skeleton (roadmap #18)

Empty channel with a stable <language>it</language> anchor line —
Script/release.sh inserts new <item> entries right after it on
each release.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `Script/release.sh` — script di release automatizzato

**Files:**
- Create: `Script/release.sh`

**Interfaces:**
- Consumes: `Script/ensure-sparkle-tools.sh` (Task 2), `appcast.xml` con l'anchor `<language>it</language>` (Task 5), `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.pbxproj`.
- Produces: nessuna interfaccia consumata da altri task — è il punto di ingresso finale per l'utente (`Script/release.sh 1.1.0`).

- [ ] **Step 1: Crea `Script/release.sh`**

```bash
#!/usr/bin/env bash
# Uso: Script/release.sh <versione, es. 1.1.0>
# Build → archive → firma EdDSA → pubblica su GitHub Releases → aggiorna appcast.xml.
# Richiede: repo GitHub pubblico già esistente (vedi Docs/superpowers/plans/2026-08-10-sparkle-auto-update.md Task 8),
# `gh` autenticato, PLACEHOLDER-github-username già sostituito con lo username reale in Info.plist/appcast.xml/questo script.
set -euo pipefail

VERSION="${1:?Uso: Script/release.sh <versione, es. 1.1.0>}"
GITHUB_REPO="PLACEHOLDER-github-username/AppBackupFoto"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$GITHUB_REPO" == PLACEHOLDER-* ]]; then
  echo "ERRORE: sostituisci PLACEHOLDER-github-username in Script/release.sh con lo username GitHub reale prima di rilasciare." >&2
  exit 1
fi

echo "==> Verifico i tool Sparkle..."
"$ROOT_DIR/Script/ensure-sparkle-tools.sh"
BIN_DIR="$ROOT_DIR/Script/sparkle-tools/bin"

echo "==> Verifico che il working tree sia pulito..."
if [ -n "$(git status --porcelain)" ]; then
  echo "ERRORE: ci sono modifiche non committate. Fai commit o stash prima di rilasciare." >&2
  exit 1
fi

echo "==> Aggiorno la versione a $VERSION nel progetto Xcode..."
/usr/bin/sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $VERSION;/g" AppBackupFoto.xcodeproj/project.pbxproj
PREV_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' AppBackupFoto.xcodeproj/project.pbxproj | grep -o '[0-9]\+')"
NEXT_BUILD=$((PREV_BUILD + 1))
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" AppBackupFoto.xcodeproj/project.pbxproj

echo "==> Archivio la build (Release, firma ad-hoc automatica come oggi)..."
rm -rf "$ROOT_DIR/build"
mkdir -p "$ROOT_DIR/build"
ARCHIVE_PATH="$ROOT_DIR/build/AppBackupFoto-$VERSION.xcarchive"
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Release \
  -archivePath "$ARCHIVE_PATH" archive

# NOTA PER #19 (notarization/Developer ID): quando arriverà, questo blocco (archive + copia
# diretta dall'archivio) andrà sostituito con `xcodebuild -exportArchive` con un
# exportOptionsPlist method=developer-id + notarytool. Nessun'altra parte di questo script
# o dell'architettura Sparkle/EdDSA/GitHub cambia.
APP_PATH="$ARCHIVE_PATH/Products/Applications/AppBackupFoto.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERRORE: non trovo $APP_PATH dopo l'archive." >&2
  exit 1
fi

echo "==> Preparo lo zip..."
ZIP_PATH="$ROOT_DIR/build/AppBackupFoto-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
ZIP_LENGTH="$(stat -f%z "$ZIP_PATH")"

echo "==> Firmo l'update con EdDSA..."
SIGN_OUTPUT="$("$BIN_DIR/sign_update" "$ZIP_PATH")"
SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]*)".*/\1/p')"
if [ -z "$SIGNATURE" ]; then
  echo "ERRORE: non sono riuscito a estrarre la firma EdDSA dall'output di sign_update:" >&2
  echo "$SIGN_OUTPUT" >&2
  exit 1
fi

echo "==> Pubblico la release su GitHub..."
gh release create "v$VERSION" "$ZIP_PATH" --repo "$GITHUB_REPO" --title "v$VERSION" --generate-notes

echo "==> Aggiorno appcast.xml..."
ENCLOSURE_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/AppBackupFoto-$VERSION.zip"
PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S %z")"
python3 - "$ROOT_DIR/appcast.xml" "$VERSION" "$NEXT_BUILD" "$ZIP_LENGTH" "$SIGNATURE" "$ENCLOSURE_URL" "$PUBDATE" <<'PYEOF'
import sys
path, version, build, length, signature, url, pubdate = sys.argv[1:8]
with open(path) as f:
    text = f.read()
item = f'''        <item>
            <title>Versione {version}</title>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.6</sparkle:minimumSystemVersion>
            <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
        </item>
'''
anchor = "<language>it</language>\n"
assert anchor in text, "Anchor <language>it</language> non trovato in appcast.xml"
text = text.replace(anchor, anchor + item, 1)
with open(path, "w") as f:
    f.write(text)
PYEOF

echo "==> Commit di versione + appcast..."
git add AppBackupFoto.xcodeproj/project.pbxproj appcast.xml
git commit -m "Release v$VERSION"
git push

echo "==> Fatto. Versione $VERSION pubblicata su https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
```

```bash
chmod +x Script/release.sh
```

- [ ] **Step 2: Verifica la sintassi bash (non un'esecuzione reale — il repo GitHub non esiste ancora)**

```bash
bash -n Script/release.sh && echo "Sintassi OK"
```
Expected: `Sintassi OK`.

- [ ] **Step 3: Verifica che il blocco Python embedded sia sintatticamente valido, isolatamente**

```bash
python3 -c "
import ast
with open('Script/release.sh') as f:
    content = f.read()
start = content.index(\"<<'PYEOF'\") + len(\"<<'PYEOF'\")
end = content.index('PYEOF', start)
snippet = content[start:end]
ast.parse(snippet)
print('Python embedded OK')
"
```
Expected: `Python embedded OK`.

- [ ] **Step 4: Commit**

```bash
git add Script/release.sh
git commit -m "$(cat <<'EOF'
Add Script/release.sh for automated releases (roadmap #18)

Archives, zips, signs with sign_update, publishes to GitHub
Releases, and inserts the new <item> into appcast.xml directly
(not via generate_appcast's batch mode, which assumes one uniform
--download-url-prefix — incompatible with GitHub's per-tag release
URLs). Not yet runnable end to end: requires the GitHub repo to
exist and PLACEHOLDER-github-username replaced (see plan Task 8).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Aggiornare `Docs/CLAUDE.md` e `Docs/ROADMAP.md`

**Files:**
- Modify: `Docs/CLAUDE.md`
- Modify: `Docs/ROADMAP.md`

**Interfaces:** nessuna — task di documentazione, chiude la feature.

- [ ] **Step 1: In `Docs/CLAUDE.md`, sezione `BackupRunner` o una nuova sotto-sezione dedicata, documenta la feature**

Aggiungi (dopo il paragrafo su "Miniatura live dell'ultimo file", stesso stile delle voci esistenti):

```markdown
- **Auto-update (2026-08-10, roadmap #18)**: `UpdaterViewModel` (wrapper `ObservableObject` attorno a `SPUStandardUpdaterController` di Sparkle 2.x, aggiunto via SPM — prima dipendenza esterna del progetto) avvia un check automatico in background (1 volta/giorno, `SUScheduledCheckInterval` in `AppBackupFoto/Info.plist`); l'installazione richiede sempre un click esplicito dell'utente sull'alert standard di Sparkle, mai automatica. Voce "Controlla aggiornamenti" in `HamburgerPanel` per il check manuale. Il target è passato da Info.plist generato a un `Info.plist` fisico (necessario per tipizzare correttamente `SUEnableAutomaticChecks`/`SUScheduledCheckInterval` come booleano/intero). Chiave privata EdDSA nel Keychain di questo Mac (mai in git), backup esplicito in un posto sicuro fuori dal repo. Pubblicazione automatizzata da `Script/release.sh` (archive → firma con `sign_update` → GitHub Release → nuovo `<item>` inserito in `appcast.xml`). Repo GitHub pubblico ancora da creare — `PLACEHOLDER-github-username` in `Info.plist`/`appcast.xml`/`Script/release.sh` va sostituito appena disponibile. Vedi `Docs/superpowers/specs/2026-08-10-sparkle-auto-update-design.md`.
```

- [ ] **Step 2: In `Docs/CLAUDE.md`, sezione "Obiettivi futuri", registra cosa resta manuale**

Sostituisci `Nessun obiettivo futuro aperto al momento.` con:

```markdown
**Verifica manuale ancora da fare** (roadmap #18, auto-update): dopo aver creato il repo GitHub pubblico e sostituito `PLACEHOLDER-github-username` in `Info.plist`/`appcast.xml`/`Script/release.sh`, pubblicare una prima release reale con `Script/release.sh` e verificare che una build precedente installata trovi/scarichi/installi correttamente l'update, con la firma EdDSA verificata da Sparkle.
```

(Se nel frattempo la sezione contiene già altre voci di "verifica manuale", aggiungi questa come punto elenco aggiuntivo invece di sostituire tutto il paragrafo — non perdere le voci esistenti.)

- [ ] **Step 3: In `Docs/ROADMAP.md`, marca il punto 18 come fatto**

Cerca la riga (punto 18 nella sezione "Valore aggiunto"):

```
18. **Nessun auto-update** — ogni build richiede Archive→Distribute→Copy a mano. Sparkle è lo standard open-source, con verifica EdDSA integrata.
    *Fonte: ricerca su Sparkle, documentazione ufficiale e best practice code signing 2026*
```

Sostituisci con:

```
18. ✅ **Fatto (2026-08-10) — Nessun auto-update.** `SPUStandardUpdaterController` (Sparkle 2.x via SPM), check automatico in background + voce manuale, installazione sempre dietro click esplicito. `Script/release.sh` automatizza build→firma EdDSA→GitHub Release→appcast.xml. Repo GitHub pubblico da creare (placeholder username ancora da sostituire) prima della prima release reale. Vedi `Docs/superpowers/specs/2026-08-10-sparkle-auto-update-design.md`.
    *Fonte: ricerca su Sparkle, documentazione ufficiale e best practice code signing 2026*
```

- [ ] **Step 4: Controllo incrociato sulle righe riassuntive di `ROADMAP.md` — NON fermarti al primo grep**

Questo è il passo che nelle ultime 3 sessioni ha sempre trovato un disallineamento dimenticato. Cerca **tutte** le righe che elencano i punti fatti, non solo la prima:

```bash
grep -n "restano solo i punti\|Nessun punto critico\|punti \"valore aggiunto\"\|18, 20\|18-20\|Fatti:" Docs/ROADMAP.md
```

Per ogni riga trovata che menziona ancora "18" come aperto/non fatto (es. "Il resto dei punti \"valore aggiunto\" (18, 20) resta..." o l'elenco in fondo a "Da dove partire"), aggiornala per riflettere che #18 è fatto — lascia #19/#20 come aperti se non sono stati toccati in questa sessione.

- [ ] **Step 5: Commit**

```bash
git add Docs/CLAUDE.md Docs/ROADMAP.md
git commit -m "$(cat <<'EOF'
Update Docs/CLAUDE.md and ROADMAP.md: auto-update (#18) shipped

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Collegare il repo GitHub reale (bloccato su input dell'utente)

Questo task **non è automatizzabile** dall'agente: richiede che l'utente crei l'account/repo GitHub e comunichi lo username (già previsto e concordato in fase di brainstorming). Non eseguire i suoi step finché lo username non arriva.

**Files:**
- Modify: `AppBackupFoto/Info.plist` (`SUFeedURL`)
- Modify: `appcast.xml` (`<link>`)
- Modify: `Script/release.sh` (`GITHUB_REPO`)

- [ ] **Step 1: Sostituisci `PLACEHOLDER-github-username` con lo username reale nei 3 file sopra** (stessa stringa letterale in tutti e tre — un find/replace semplice basta)

```bash
USERNAME="<username-reale-fornito-dall'utente>"
/usr/bin/sed -i '' "s/PLACEHOLDER-github-username/$USERNAME/g" AppBackupFoto/Info.plist appcast.xml Script/release.sh
```

- [ ] **Step 2: Build + test per confermare che il cambio di stringa in Info.plist non abbia rotto nulla**

```bash
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug build
xcodebuild -project AppBackupFoto.xcodeproj -scheme AppBackupFoto -configuration Debug -destination 'platform=macOS' test
```
Expected: build verde, 79 test verdi.

- [ ] **Step 3: Commit**

```bash
git add AppBackupFoto/Info.plist appcast.xml Script/release.sh
git commit -m "$(cat <<'EOF'
Wire real GitHub username into Sparkle feed URLs (roadmap #18)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

**Dopo questo task**, il repo GitHub va creato manualmente dall'utente (pubblico, nome `AppBackupFoto`) e il codice pushato — solo allora `Script/release.sh` sarà eseguibile end-to-end per la prima volta.
