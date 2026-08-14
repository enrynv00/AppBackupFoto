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
