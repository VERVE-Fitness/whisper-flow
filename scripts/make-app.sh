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

# Embed the ollama runtime so WhisperFlow owns its own local-LLM process
# (EmbeddedOllama.swift) instead of depending on a separately-registered
# background service. This is the whole libexec/ directory, not just the
# top-level `ollama` binary: ollama shells out to a sibling `llama-server`
# binary (relative to its own path, e.g. "lib/ollama/llama-server") to do
# the actual GPU/Metal-accelerated inference -- embedding only the
# dispatcher binary silently works but falls back to slow CPU-only
# inference, which is worse than it looks (no error, just quietly slower and
# more likely to hit CleanupRouter's 10s timeout guard). Total ~46MB, still
# NOT the multi-GB model store, which stays wherever it already lives on
# disk (see EmbeddedOllama's doc comment) so rebuilding this OneDrive-synced
# repo never has to push gigabytes of model weights.
OLLAMA_LINK="${OLLAMA_BIN:-$(command -v ollama || true)}"
OLLAMA_REAL="$( [[ -n "$OLLAMA_LINK" ]] && readlink -f "$OLLAMA_LINK" || true )"
# Homebrew's ollama binary lives at .../Cellar/ollama/<version>/libexec/ollama,
# with llama-server/llama-quantize alongside it under libexec/lib/ollama/ --
# that whole libexec/ directory is the runtime unit to copy.
OLLAMA_RUNTIME_DIR="$( [[ -n "$OLLAMA_REAL" ]] && dirname "$OLLAMA_REAL" || true )"
if [[ -n "$OLLAMA_RUNTIME_DIR" && -f "$OLLAMA_RUNTIME_DIR/ollama" ]]; then
  echo "==> Embedding ollama runtime from $OLLAMA_RUNTIME_DIR…"
  mkdir -p "$APP_DIR/Contents/Resources/ollama-bin"
  cp -R "$OLLAMA_RUNTIME_DIR/." "$APP_DIR/Contents/Resources/ollama-bin/"
  chmod +x "$APP_DIR/Contents/Resources/ollama-bin/ollama"
  find "$APP_DIR/Contents/Resources/ollama-bin" -type f -perm -u+x -exec chmod +x {} \;
else
  echo "==> WARNING: no ollama runtime found (checked \$OLLAMA_BIN and PATH) -- shipping without embedded Ollama; cleanup will fall back to Foundation Models or passthrough" >&2
fi

echo "==> Codesigning…"
# Stable identity keeps TCC (Accessibility/Microphone) grants valid across
# rebuilds. Falls back to ad-hoc when the cert isn't present (other machines).
CODESIGN_ID="${CODESIGN_ID:-A289D6D61201940E4DA8BC484D7B2935A23558B4}"
# Nested executables must be signed before the outer bundle -- codesign on
# the .app only seals what's already validly signed underneath it. Sign
# every embedded Mach-O binary individually (ollama, llama-server,
# llama-quantize), not just the top-level one.
if [[ -d "$APP_DIR/Contents/Resources/ollama-bin" ]]; then
  while IFS= read -r -d '' bin; do
    codesign --force --sign "$CODESIGN_ID" "$bin" || codesign --force --sign - "$bin"
  done < <(find "$APP_DIR/Contents/Resources/ollama-bin" -type f -perm -u+x -print0)
fi
codesign --force --sign "$CODESIGN_ID" "$APP_DIR" || codesign --force --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
