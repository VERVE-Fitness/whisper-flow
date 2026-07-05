#!/bin/bash
# Build Whisper Flow and assemble a signed WhisperFlow.app bundle.
# Scratch path lives OUTSIDE the repo because the repo is on OneDrive.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$HOME/.cache/whisperflow-build"
APP_DIR="$REPO_DIR/WhisperFlow.app"

echo "==> Building (release)…"
swift build -c release --package-path "$REPO_DIR" --scratch-path "$SCRATCH"

BIN="$SCRATCH/release/WhisperFlow"
if [[ ! -f "$BIN" ]]; then
  BIN="$(find "$SCRATCH" -type f -name WhisperFlow -path '*release*' | head -1)"
fi
if [[ -z "${BIN:-}" || ! -f "$BIN" ]]; then
  echo "error: built binary not found under $SCRATCH" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN" "$APP_DIR/Contents/MacOS/WhisperFlow"
cp "$REPO_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> Codesigning (ad-hoc)…"
codesign --force --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
