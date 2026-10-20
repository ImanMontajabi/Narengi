#!/usr/bin/env bash
# Publishes a release: test, build, package, tag, push, and create the GitHub release with the DMG attached.
#
# Usage: scripts/publish-release.sh vX.Y.Z [--skip-tests] [--force-tag] [--draft]
#
# Needs: a clean working tree on `main`, an `origin` remote, `gh auth login`, create-dmg, and the bundled tools
# (scripts/setup-vendor.sh and scripts/bundle-ffmpeg.sh). The version in project.yml is bumped to match the tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG=""; SKIP_TESTS=0; FORCE_TAG=0; DRAFT=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    --force-tag) FORCE_TAG=1 ;;
    --draft) DRAFT=1 ;;
    v[0-9]*) TAG="$arg" ;;
    *) echo "usage: $0 vX.Y.Z [--skip-tests] [--force-tag] [--draft]" >&2; exit 2 ;;
  esac
done
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: give a version tag such as v0.1.0" >&2; exit 2; }
VERSION="${TAG#v}"
DMG="dist/Narengi-${TAG}-arm64.dmg"

echo "==> Checking the environment"
gh auth status >/dev/null 2>&1 || { echo "error: not logged in to GitHub (run: gh auth login)" >&2; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "error: no 'origin' remote" >&2; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "error: releases are made from main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: the working tree has uncommitted changes; commit or stash them first" >&2; git status --short >&2; exit 1; }

echo "==> Setting the version to $VERSION"
CURRENT="$(sed -nE 's/^[[:space:]]*CFBundleShortVersionString:[[:space:]]*"?([0-9][^" ]*)"?.*/\1/p' project.yml | head -1)"
if [[ "$CURRENT" != "$VERSION" ]]; then
  BUILD="$(sed -nE 's/^[[:space:]]*CFBundleVersion:[[:space:]]*"?([0-9]+)"?.*/\1/p' project.yml | head -1)"
  sed -i '' -E "s/^([[:space:]]*CFBundleShortVersionString:[[:space:]]*)\"?[0-9][^\" ]*\"?/\1\"$VERSION\"/" project.yml
  sed -i '' -E "s/^([[:space:]]*CFBundleVersion:[[:space:]]*)\"?[0-9]+\"?/\1\"$(( ${BUILD:-0} + 1 ))\"/" project.yml
fi
xcodegen generate >/dev/null
if [[ -n "$(git status --porcelain)" ]]; then
  git add project.yml Narengi/Info.plist
  git commit -q -m "Bump version to $VERSION"
fi

if ((SKIP_TESTS)); then
  echo "==> Skipping tests (--skip-tests)"
else
  echo "==> Running the test suite"
  LOG="$(mktemp)"
  if ! xcodebuild -project Narengi.xcodeproj -scheme Narengi -configuration Debug -derivedDataPath build \
      -destination 'platform=macOS,arch=arm64' test >"$LOG" 2>&1; then
    tail -40 "$LOG" >&2
    echo "error: tests failed; nothing was tagged or pushed (full log: $LOG)" >&2
    exit 1
  fi
  grep -E "Executed [0-9]+ tests.*seconds$" "$LOG" | tail -1
fi

echo "==> Building and packaging"
"$ROOT/scripts/package-dmg.sh" --version "$VERSION"
[[ -f "$DMG" && -f "$DMG.sha256" ]] || { echo "error: $DMG or its checksum is missing" >&2; exit 1; }
SHA="$(cut -d' ' -f1 "$DMG.sha256")"

echo "==> Tagging $TAG"
HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/$TAG" | cut -f1)"
if [[ -n "$REMOTE_TAG" ]]; then
  REMOTE_COMMIT="$(git ls-remote --tags origin "refs/tags/$TAG^{}" | cut -f1)"
  [[ -n "$REMOTE_COMMIT" ]] || REMOTE_COMMIT="$REMOTE_TAG"
  if [[ "$REMOTE_COMMIT" != "$HEAD_SHA" && $FORCE_TAG -eq 0 ]]; then
    echo "error: $TAG already exists on origin at a different commit; re-run with --force-tag to move it" >&2
    exit 1
  fi
fi
git tag -f -a "$TAG" -m "Narengi $TAG" "$HEAD_SHA" >/dev/null

echo "==> Pushing main and $TAG"
git push origin main
if ((FORCE_TAG)); then git push origin "refs/tags/$TAG" --force; else git push origin "refs/tags/$TAG"; fi

echo "==> Publishing the GitHub release"
NOTES="$(mktemp)"
cat >"$NOTES" <<NOTES_EOF
## Install

Requires an Apple silicon Mac running macOS 14 or later.

1. Download **Narengi-${TAG}-arm64.dmg** below and open it.
2. Drag **Narengi.app** onto **Applications**.
3. The app is signed ad hoc (not notarized). Clear the quarantine flag once, then open it:

   \`\`\`sh
   xattr -cr /Applications/Narengi.app
   open /Applications/Narengi.app
   \`\`\`

SHA-256: \`${SHA}\`

The bundled FFmpeg is a GPL build; see THIRD_PARTY_NOTICES.md.

## What's changed
NOTES_EOF
FLAGS=()
((DRAFT)) && FLAGS+=(--draft)
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "release $TAG exists; replacing its assets"
  gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  gh release edit "$TAG" --title "Narengi $TAG" --notes-file "$NOTES"
else
  gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Narengi $TAG" --notes-file "$NOTES" --generate-notes ${FLAGS[@]+"${FLAGS[@]}"} --verify-tag
fi

echo
echo "Release:  $(gh release view "$TAG" --json url -q .url)"
echo "DMG:      $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA-256:  $SHA"
