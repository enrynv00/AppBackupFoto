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
