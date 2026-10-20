#!/usr/bin/env bash
# Builds the Release app, signs the bundled tools and the app (ad-hoc), verifies the result and installs it into
# /Applications. Run scripts/setup-vendor.sh and scripts/bundle-ffmpeg.sh first if Resources/Vendor is empty.
#
# Usage: scripts/release.sh [--no-install]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/Build/Products/Release/Narengi.app"
DEST="/Applications/Narengi.app"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

echo "==> Building Release"
xcodegen generate >/dev/null
xcodebuild -project Narengi.xcodeproj -scheme Narengi -configuration Release -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' build | tail -1

VENDOR="$APP/Contents/Resources/Vendor"
for f in "$VENDOR/bin/ffmpeg" "$VENDOR/cwebp" "$VENDOR/exiftool/exiftool"; do
  [[ -e "$f" ]] || { echo "error: $f is missing from the bundle" >&2; exit 1; }
done

echo "==> Signing bundled tools"
for f in "$VENDOR"/lib/*.dylib "$VENDOR/bin/ffmpeg" "$VENDOR/cwebp"; do
  codesign --force --sign - "$f" >/dev/null
done

echo "==> Signing the app"
codesign --force --deep --sign - "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=1 "$APP"
for f in "$VENDOR"/lib/*.dylib "$VENDOR/bin/ffmpeg" "$VENDOR/cwebp"; do codesign --verify --strict "$f"; done
env -i "$VENDOR/bin/ffmpeg" -version | head -1

((INSTALL)) || { echo "ok: $APP"; exit 0; }

echo "==> Quitting any running Narengi"
if pgrep -x Narengi >/dev/null; then
  osascript -e 'tell application id "app.narengi.Narengi" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x Narengi >/dev/null || break; sleep 0.25; done
  pgrep -x Narengi >/dev/null && { pkill -TERM -x Narengi || true; sleep 1; }
fi

echo "==> Installing to $DEST"
rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST"
open "$DEST"
echo "ok: installed $DEST"
