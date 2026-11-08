#!/bin/bash
# Builds ImageManager.app (release) into build/ and optionally installs it.
#
#   ./scripts/build-app.sh            # build + ad-hoc sign → build/ImageManager.app
#   ./scripts/build-app.sh --open     # ... and launch it
#   ./scripts/build-app.sh --install  # ... and copy it to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
APP_NAME="ImageManager"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

# SwiftPM needs a writable module cache / TMPDIR. Some sandboxed environments
# can't write to the default locations, so point them inside the repo.
export TMPDIR="${TMPDIR_OVERRIDE:-$ROOT/.cache/tmp}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.cache/clang"
export SWIFT_MODULECACHE_PATH="$ROOT/.cache/clang"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
# scripts/icon-build holds the intermediate iconset used to create AppIcon.icns

echo "▸ Building release binary…"
swift build -c release --disable-sandbox --product "$APP_NAME"
BIN="$(swift build -c release --disable-sandbox --show-bin-path)/$APP_NAME"

echo "▸ Assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/ImageManager/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/ImageManager/Resources/AppIcon.icns" ]; then
  cp "$ROOT/ImageManager/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - --identifier com.local.ImageManager "${APP}" 2>/dev/null


if [ "${1:-}" = "--open" ]; then
  open "${APP}"
fi
if [ "${1:-}" = "--install" ]; then
  cp -R "${APP}" /Applications/
  echo "Installed to /Applications/$APP_NAME.app"
fi

echo "Built $(du -sh "${APP}" | cut -f1) -> ${APP}"