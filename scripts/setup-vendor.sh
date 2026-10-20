#!/usr/bin/env bash
# Fetches the standalone helper tools Narengi bundles into Narengi/Resources/Vendor/.
#   cwebp    libwebp arm64 prebuilt from the WebM project   (BSD-3-Clause)
#   exiftool Phil Harvey's ExifTool (Perl, official GitHub tag) (Artistic/GPL)
# Downloads are checked against pinned SHA-256 hashes before anything is extracted.
# ffmpeg is not fetched here yet; BundledToolLocator falls back to Homebrew for it.
#
# Usage: scripts/setup-vendor.sh [--force]
set -euo pipefail

WEBP_VERSION="1.6.0"
WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}-mac-arm64.tar.gz"
WEBP_SHA256="bc6bf84cc70f3f8574fba797d1e4a7dea4feebe9fa4be919f202413ea2b3b8f2"

EXIFTOOL_VERSION="13.59"
EXIFTOOL_URL="https://github.com/exiftool/exiftool/archive/refs/tags/${EXIFTOOL_VERSION}.tar.gz"
EXIFTOOL_SHA256="87d3317882fdae9cb4dcfe57a96a378d0132ffc02c731315bf128b19ddcf7aac"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Narengi/Resources/Vendor"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "warning: this script fetches arm64 binaries; you are on $(uname -m)" >&2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # url sha256 dest
  curl -fsSL --retry 3 -o "$3" "$1"
  local actual
  actual="$(shasum -a 256 "$3" | cut -d' ' -f1)"
  if [[ "$actual" != "$2" ]]; then
    echo "error: checksum mismatch for $1" >&2
    echo "  expected $2" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
}

mkdir -p "$VENDOR"

if [[ $FORCE -eq 1 || ! -x "$VENDOR/cwebp" ]]; then
  echo "==> cwebp $WEBP_VERSION"
  mkdir -p "$WORK/webp"
  fetch "$WEBP_URL" "$WEBP_SHA256" "$WORK/webp.tar.gz"
  tar -xzf "$WORK/webp.tar.gz" -C "$WORK/webp"
  install -m 755 "$WORK/webp/libwebp-${WEBP_VERSION}-mac-arm64/bin/cwebp" "$VENDOR/cwebp"
  mkdir -p "$VENDOR/licenses"
  cp "$WORK/webp/libwebp-${WEBP_VERSION}-mac-arm64/COPYING" "$VENDOR/licenses/libwebp-COPYING" 2>/dev/null || true
  # Hardened-runtime apps may only spawn signed binaries; ad-hoc signing is enough locally.
  codesign --force --sign - "$VENDOR/cwebp" >/dev/null 2>&1 || true
else
  echo "==> cwebp already present (use --force to refetch)"
fi

if [[ $FORCE -eq 1 || ! -x "$VENDOR/exiftool/exiftool" ]]; then
  echo "==> exiftool $EXIFTOOL_VERSION"
  mkdir -p "$WORK/exif"
  fetch "$EXIFTOOL_URL" "$EXIFTOOL_SHA256" "$WORK/exif.tar.gz"
  tar -xzf "$WORK/exif.tar.gz" -C "$WORK/exif"
  SRC="$WORK/exif/exiftool-${EXIFTOOL_VERSION}"
  rm -rf "$VENDOR/exiftool"
  mkdir -p "$VENDOR/exiftool"
  cp -R "$SRC/exiftool" "$SRC/lib" "$SRC/LICENSE" "$VENDOR/exiftool/"
  chmod 755 "$VENDOR/exiftool/exiftool"
else
  echo "==> exiftool already present (use --force to refetch)"
fi

echo "Vendor tools ready in $VENDOR"
"$VENDOR/cwebp" -version | head -1
"$VENDOR/exiftool/exiftool" -ver
