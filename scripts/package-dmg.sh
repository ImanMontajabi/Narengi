#!/usr/bin/env bash
# Builds the installer disk image: dist/Narengi-v<version>-arm64.dmg plus its .sha256.
#
# The app comes from scripts/release.sh (fresh Release build, bundled tools, ad-hoc signed). The image is styled
# with create-dmg (Finder scripting); if that fails, for example on a headless machine, a plain image is made
# with hdiutil instead, with the same contents.
#
# Usage: scripts/package-dmg.sh [--version X.Y.Z] [--skip-build]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=""
BUILD=1
while (($#)); do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --skip-build) BUILD=0; shift ;;
    *) echo "usage: $0 [--version X.Y.Z] [--skip-build]" >&2; exit 2 ;;
  esac
done

# Version: the argument, else project.yml, else Info.plist, else 0.1.0.
if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -nE 's/^[[:space:]]*CFBundleShortVersionString:[[:space:]]*"?([0-9][^" ]*)"?.*/\1/p' project.yml | head -1)"
fi
if [[ -z "$VERSION" && -f Narengi/Info.plist ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Narengi/Info.plist 2>/dev/null || true)"
fi
VERSION="${VERSION:-0.1.0}"

APP="$ROOT/build/Build/Products/Release/Narengi.app"
DIST="$ROOT/dist"
NAME="Narengi-v${VERSION}-arm64"
DMG="$DIST/$NAME.dmg"

if ((BUILD)); then
  "$ROOT/scripts/release.sh" --no-install
fi
[[ -d "$APP" ]] || { echo "error: $APP not found; run scripts/release.sh first" >&2; exit 1; }

# The bundled tools must be in the app, or the installer would ship a Narengi that can't convert media.
for f in Vendor/bin/ffmpeg Vendor/cwebp Vendor/exiftool/exiftool; do
  [[ -e "$APP/Contents/Resources/$f" ]] || { echo "error: $f is missing from the app" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP"

command -v create-dmg >/dev/null || { echo "==> Installing create-dmg"; brew install create-dmg; }

mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Narengi.app"

# Volume icon: the app's own icon, built from the asset catalog with iconutil (nothing binary is committed).
ICONSET="$STAGE-icon/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$ROOT"/Narengi/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
VOLICON=()
if iconutil -c icns "$ICONSET" -o "$STAGE-icon/AppIcon.icns" 2>/dev/null; then VOLICON=(--volicon "$STAGE-icon/AppIcon.icns"); fi
trap 'rm -rf "$STAGE" "$STAGE-icon"' EXIT

echo "==> Building $NAME.dmg"
if create-dmg \
    --volname "Narengi" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 120 \
    --icon "Narengi.app" 160 185 \
    --hide-extension "Narengi.app" \
    --app-drop-link 440 185 \
    --no-internet-enable \
    ${VOLICON[@]+"${VOLICON[@]}"} \
    "$DMG" "$STAGE"; then
  echo "==> Styled image created"
else
  echo "warning: create-dmg failed; falling back to a plain hdiutil image" >&2
  rm -f "$DMG"
  # Detach anything create-dmg left mounted.
  for d in /Volumes/Narengi*; do [[ -d "$d" ]] && hdiutil detach "$d" -force >/dev/null 2>&1 || true; done
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Narengi" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
fi

hdiutil verify "$DMG" >/dev/null
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")

echo "ok: $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
