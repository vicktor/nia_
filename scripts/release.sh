#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Publish a signed development build to GitHub Releases.
# Example: ./scripts/release.sh 0.8.0 --prerelease
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'HELP'
Usage: ./scripts/release.sh VERSION [--prerelease | --stable | --draft]

Example: ./scripts/release.sh 0.8.0 --prerelease
Requirements: macOS, cargo, Swift toolchain, ditto, git, gh, authenticated gh CLI.
Commit all files and push the branch before running this script.
Set NIA_GITHUB_REPO=owner/repository to override the default vicktor/nia_.
Set NIA_RELEASE_NOTES_FILE to use an external description file (optional).

The script checks source cleanliness, compiled version, signature, target
architecture and remote Git state before creating and pushing a version tag.
HELP
}

if [[ $# -lt 1 || $# -gt 2 ]]; then usage >&2; exit 2; fi
VERSION="$1"
case "$VERSION" in
  *[!0-9.]* | .* | *..* | *.) echo "Invalid version: $VERSION" >&2; exit 2 ;;
esac
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected a three-part version such as 0.6.1" >&2; exit 2
fi
RELEASE_MODE="${2:---prerelease}"
case "$RELEASE_MODE" in
  --prerelease | --stable | --draft) ;;
  *) usage >&2; exit 2 ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || { echo 'Run releases on macOS.' >&2; exit 1; }
for tool in git gh cargo swiftc ditto plutil codesign shasum file; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
[[ -d .git ]] || git rev-parse --is-inside-work-tree >/dev/null
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo 'Working tree is not clean. Commit changes first.' >&2
  git status --short >&2
  exit 1
}
[[ "$(git branch --show-current)" != "" ]] || { echo 'Cannot release from detached HEAD.' >&2; exit 1; }

git remote get-url origin >/dev/null
REPO="${NIA_GITHUB_REPO:-vicktor/nia_}"
gh auth status >/dev/null
ACTUAL_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[[ "$(printf %s "$ACTUAL_REPO" | tr '[:upper:]' '[:lower:]')" == "$(printf %s "$REPO" | tr '[:upper:]' '[:lower:]')" ]] || {
  echo "Expected GitHub repository $REPO, got $ACTUAL_REPO" >&2
  exit 1
}

TAG="v${VERSION}"
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG already exists locally" >&2; exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists on origin" >&2; exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists" >&2; exit 1
fi

MANIFEST_VERSION="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' Cargo.toml | head -1)"
[[ "$MANIFEST_VERSION" == "$VERSION" ]] || {
  echo "Cargo.toml is $MANIFEST_VERSION, expected $VERSION" >&2; exit 1
}
if [[ -n "${NIA_RELEASE_NOTES_FILE:-}" && ! -f "$NIA_RELEASE_NOTES_FILE" ]]; then
  echo 'NIA_RELEASE_NOTES_FILE does not point to a file' >&2; exit 1
fi

# Do not publish a tag whose commit has not reached the server.
BRANCH="$(git branch --show-current)"
git fetch --quiet origin "$BRANCH"
if ! git merge-base --is-ancestor HEAD "origin/$BRANCH"; then
  echo "Current commit is not pushed to origin/$BRANCH. Push it first." >&2
  exit 1
fi

./scripts/build-native-macos.sh
APP="$ROOT/dist/nia_.app"
[[ -x "$APP/Contents/MacOS/nia" ]] || { echo 'Missing nia executable' >&2; exit 1; }
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_VERSION" == "$VERSION" ]] || {
  echo "Bundle is $BUNDLE_VERSION, expected $VERSION" >&2; exit 1
}
ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" || "$ARCH" == "x86_64" ]] || { echo "Unknown arch: $ARCH" >&2; exit 1; }
file "$APP/Contents/MacOS/nia" | grep -q "$ARCH" || {
  echo "Bundle executable does not contain architecture $ARCH" >&2; exit 1
}
codesign --verify --deep --strict "$APP"

ZIP="$ROOT/dist/nia_-${TAG}-macos-${ARCH}.zip"
SHA="$ZIP.sha256"
rm -f "$ZIP" "$SHA"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
[[ -s "$ZIP" ]] || { echo 'Archive is empty' >&2; exit 1; }
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")") > "$SHA"

# All local validations completed: create the tag and the GitHub release.
git tag -a "$TAG" -m "nia_ $TAG"
git push origin "$TAG"
FLAGS=(--verify-tag --title "nia_ $TAG" --repo "$REPO")
if [[ -n "${NIA_RELEASE_NOTES_FILE:-}" ]]; then
  FLAGS+=(--notes-file "$NIA_RELEASE_NOTES_FILE")
else
  FLAGS+=(--notes "nia_ $TAG for macOS 14+. Native SwiftUI, Metal and Rust terminal. Beta build with an ad-hoc signature; see README and STATUS for setup and current limits.")
fi
case "$RELEASE_MODE" in
  --prerelease) FLAGS+=(--prerelease) ;;
  --draft) FLAGS+=(--draft) ;;
esac

gh release create "$TAG" "$ZIP" "$SHA" "${FLAGS[@]}"
echo "Published https://github.com/$REPO/releases/tag/$TAG"
echo 'Note: ad-hoc signed builds are not Apple-notarized.'
