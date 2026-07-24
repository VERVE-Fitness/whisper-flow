#!/bin/bash
# Regenerate Resources/AppIcon.svg and Resources/AppIcon.icns from the
# anatomical key points in scripts/gen-icon.py.
#
# Run this after editing gen-icon.py, then re-run scripts/make-app.sh to get
# the new icon into WhisperFlow.app. Finder and the Dock aggressively cache
# icons, so a rebuilt app may still show the old one until the icon services
# cache is cleared (the script does that at the end).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$REPO_DIR/Resources/AppIcon.svg"
ICNS="$REPO_DIR/Resources/AppIcon.icns"
# Build the iconset outside the repo: OneDrive syncs this directory, and a
# transient 10-file iconset churning through it on every icon tweak is pure
# noise (same reasoning as make-app.sh keeping its scratch path in ~/.cache).
ICONSET="${TMPDIR:-/tmp}/WhisperFlowAppIcon.iconset"

echo "==> Generating $SVG…"
python3 "$REPO_DIR/scripts/gen-icon.py" "$SVG"

echo "==> Rendering iconset…"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
python3 - "$SVG" "$ICONSET" <<'PY'
import sys
import cairosvg

svg, iconset = sys.argv[1], sys.argv[2]
# The 10 representations `iconutil` expects for a complete .icns.
for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = base * scale
        suffix = "" if scale == 1 else "@2x"
        out = f"{iconset}/icon_{base}x{base}{suffix}.png"
        cairosvg.svg2png(url=svg, write_to=out, output_width=px, output_height=px)
print("rendered 10 sizes")
PY

echo "==> Building $ICNS…"
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

# Without this, a rebuilt .app keeps showing the previous icon in Finder and
# the Dock for an unpredictable amount of time.
echo "==> Flushing icon caches…"
touch "$REPO_DIR/WhisperFlow.app" 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "==> Done: $ICNS"
