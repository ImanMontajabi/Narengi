#!/usr/bin/env bash
# Copies the local ffmpeg (Homebrew) into Narengi/Resources/Vendor/bin/ together with every non-system
# dylib it needs (Vendor/lib/), rewrites the load paths to @loader_path so nothing points at /opt/homebrew,
# re-signs everything ad-hoc, and checks that the bundled copy runs on its own.
#
# The result is a self-contained arm64 ffmpeg for *this Mac*. The Homebrew build is GPL (x264, x265), so
# do not redistribute the app with it unless you also comply with the GPL (see THIRD_PARTY_NOTICES.md).
#
# Usage: scripts/bundle-ffmpeg.sh [path-to-ffmpeg]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Narengi/Resources/Vendor"
BIN="$VENDOR/bin"
LIB="$VENDOR/lib"
SRC="$(readlink -f "${1:-$(command -v ffmpeg)}")"

[[ -x "$SRC" ]] || { echo "error: ffmpeg not found (install it with: brew install ffmpeg)" >&2; exit 1; }
[[ "$(file -b "$SRC")" == *arm64* ]] || { echo "error: $SRC is not an arm64 binary" >&2; exit 1; }

rm -rf "$BIN" "$LIB"
mkdir -p "$BIN" "$LIB"
cp "$SRC" "$BIN/ffmpeg"
chmod u+w "$BIN/ffmpeg"

is_system() { [[ "$1" == /usr/lib/* || "$1" == /System/* ]]; }

# Resolves a dependency named in a Mach-O header to a real file, or prints nothing.
resolve() { # dep parent-dir
  local dep="$1" parent="$2" name
  name="$(basename "$dep")"
  if [[ "$dep" == /* && -f "$dep" ]]; then readlink -f "$dep"; return; fi
  for dir in "$parent" "$(dirname "$SRC")/../lib" /opt/homebrew/lib /opt/homebrew/opt/*/lib; do
    if [[ -f "$dir/$name" ]]; then readlink -f "$dir/$name"; return; fi
  done
}

deps_of() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }

queue=("$SRC")
declare -a done_list=()
seen() { local x; for x in "${done_list[@]:-}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

# Pass 1: find and copy every non-system dependency, recursively.
while ((${#queue[@]})); do
  current="${queue[0]}"; queue=("${queue[@]:1}")
  seen "$current" && continue
  done_list+=("$current")
  for dep in $(deps_of "$current"); do
    is_system "$dep" && continue
    real="$(resolve "$dep" "$(dirname "$current")")"
    if [[ -z "$real" ]]; then echo "error: cannot find $dep (needed by $current)" >&2; exit 1; fi
    dest="$LIB/$(basename "$real")"
    if [[ ! -f "$dest" ]]; then cp "$real" "$dest"; chmod u+w "$dest"; fi
    seen "$real" || queue+=("$real")
  done
done

# Pass 2: rewrite install names. Binary -> ../lib, libraries -> next to each other.
rewrite() { # file prefix
  local file="$1" prefix="$2" dep real
  for dep in $(deps_of "$file"); do
    is_system "$dep" && continue
    [[ "$dep" == "$file" ]] && continue
    real="$(resolve "$dep" "$(dirname "$SRC")/../lib")"
    [[ -n "$real" ]] || real="$dep"
    install_name_tool -change "$dep" "$prefix/$(basename "$real")" "$file" 2>/dev/null || true
  done
}

rewrite "$BIN/ffmpeg" "@loader_path/../lib"
for lib in "$LIB"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$lib")" "$lib" 2>/dev/null
  rewrite "$lib" "@loader_path"
  # Drop any absolute rpaths that still point into Homebrew.
  for rp in $(otool -l "$lib" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}'); do
    [[ "$rp" == /opt/homebrew* || "$rp" == /usr/local* ]] && install_name_tool -delete_rpath "$rp" "$lib" 2>/dev/null || true
  done
done
for rp in $(otool -l "$BIN/ffmpeg" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}'); do
  [[ "$rp" == /opt/homebrew* || "$rp" == /usr/local* ]] && install_name_tool -delete_rpath "$rp" "$BIN/ffmpeg" 2>/dev/null || true
done

# Pass 3: install_name_tool invalidates signatures, and arm64 refuses unsigned code.
for f in "$LIB"/*.dylib "$BIN/ffmpeg"; do codesign --force --sign - "$f" >/dev/null 2>&1; done

# Verify: nothing may point outside the bundle or the system.
bad=0
for f in "$LIB"/*.dylib "$BIN/ffmpeg"; do
  while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|@loader_path/*) ;;
      *) echo "error: $(basename "$f") still references $dep" >&2; bad=1 ;;
    esac
  done < <(deps_of "$f")
done
((bad == 0)) || exit 1

# Run it with a scrubbed environment, as the app would.
out="$(env -i "$BIN/ffmpeg" -hide_banner -encoders 2>&1)"
for enc in libx264 aac libmp3lame; do
  grep -q " $enc " <<<"$out" || { echo "error: bundled ffmpeg lacks encoder $enc" >&2; exit 1; }
done

mkdir -p "$VENDOR/licenses"
{
  echo "ffmpeg bundled from: $SRC"
  env -i "$BIN/ffmpeg" -version | sed -n '1,3p'
  echo
  echo "This build is licensed GPL (version 3 or later) because of x264/x265. FFmpeg source: https://ffmpeg.org/"
  echo "Bundled libraries:"
  ls "$LIB" | sed 's/^/  /'
} > "$VENDOR/licenses/ffmpeg-NOTICE.txt"

echo "ok: bundled ffmpeg + $(ls "$LIB" | wc -l | tr -d ' ') libraries ($(du -sh "$VENDOR/bin" "$LIB" | awk '{s=s" "$1} END{print s}'))"
