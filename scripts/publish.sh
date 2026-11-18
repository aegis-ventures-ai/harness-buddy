#!/bin/bash
# Publishes what scripts/release.sh built as the GitHub release for its tag.
#
#   scripts/publish.sh
#
# Releases on this repo are immutable once published: assets can't be added afterwards and the
# tag can't be reused. So the release is created as a draft with every asset attached, checked,
# and only then published. The installed apps read the appcast from the latest release.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="aegis-ventures-ai/harness-buddy"
VERSION="$(awk '/MARKETING_VERSION:/ { print $2; exit }' project.yml)"
TAG="v$VERSION"
OUT=.build/release
DMG="$OUT/HarnessButler-$VERSION.dmg"

fail() { echo "error: $*" >&2; exit 1; }

for file in "$DMG" "$DMG.sha256" "$OUT/appcast.xml"; do [ -f "$file" ] || fail "missing $file; run scripts/release.sh first"; done
xcrun stapler validate -q "$DMG" || fail "$DMG isn't notarized and stapled"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "no tag $TAG"
[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ] || fail "HEAD isn't $TAG; build the release from the tag"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null || fail "$TAG isn't pushed"

sha="$(cut -d' ' -f1 "$DMG.sha256")"
notes="$OUT/release-notes.md"
{
    echo "### Download"
    echo
    echo "**HarnessButler-$VERSION.dmg**: signed with Developer ID and notarized by Apple. It needs macOS 27 on Apple silicon."
    echo "Open the DMG and drag **Harness Butler** to **Applications**. Installed copies from 1.1.0 on update themselves."
    echo
    echo "SHA-256: \`$sha\`"
    echo
    awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" { on = 1; next } /^## \[/ { on = 0 } /^\[[0-9.]+\]: / { on = 0 } on' CHANGELOG.md \
        | sed -E "s#\]\((docs/[^)]*)\)#](https://github.com/$REPO/blob/$TAG/\1)#g"
} > "$notes"

echo "==> Creating the $TAG release as a draft with its assets"
gh release create "$TAG" --repo "$REPO" --draft --verify-tag --title "Harness Butler $VERSION" --notes-file "$notes" \
    "$DMG" "$DMG.sha256" "$OUT/appcast.xml"

echo "==> Checking the draft"
assets="$(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name' | sort | tr '\n' ' ')"
expected="$(printf '%s\n' "$(basename "$DMG")" "$(basename "$DMG").sha256" appcast.xml | sort | tr '\n' ' ')"
[ "$assets" = "$expected" ] || fail "draft assets are '$assets', expected '$expected' (the draft is left for you to check)"
digest="$(gh release view "$TAG" --repo "$REPO" --json assets -q ".assets[] | select(.name == \"$(basename "$DMG")\") | .digest")"
[ "$digest" = "sha256:$sha" ] || fail "uploaded DMG digest $digest doesn't match $sha"

echo "==> Publishing"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
gh release view "$TAG" --repo "$REPO" --json url -q .url
