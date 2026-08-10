#!/usr/bin/env bash
# Uso: Script/release.sh <versione, es. 1.1.0>
# Build → archive → firma EdDSA → pubblica su GitHub Releases → aggiorna appcast.xml.
# Richiede: repo GitHub pubblico già esistente (vedi Docs/superpowers/plans/2026-08-10-sparkle-auto-update.md Task 8),
# `gh` autenticato, enrynv00 già sostituito con lo username reale in Info.plist/appcast.xml/questo script.
set -euo pipefail

VERSION="${1:?Uso: Script/release.sh <versione, es. 1.1.0>}"
GITHUB_REPO="enrynv00/AppBackupFoto"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "$GITHUB_REPO" == PLACEHOLDER-* ]]; then
  echo "ERRORE: sostituisci enrynv00 in Script/release.sh con lo username GitHub reale prima di rilasciare." >&2
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
