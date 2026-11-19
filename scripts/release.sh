#!/bin/bash
# Builds a Developer ID-signed, notarized and stapled DMG of Harness Butler, plus the signed
# Sparkle appcast that points at it. Publish both with scripts/publish.sh.
#
#   scripts/release.sh                 # build, sign, notarize, staple, appcast
#   SKIP_NOTARIZE=1 scripts/release.sh # build and sign only (for a local check; no appcast)
#
# Needs, once per Mac:
#   - the "Developer ID Application" certificate for TEAM_ID in the login keychain;
#   - notarization credentials:
#       xcrun notarytool store-credentials harness-butler-notary --apple-id <Apple ID> --team-id <TEAM_ID>
#   - the Sparkle EdDSA key (account "harness-butler") in the login keychain. It was made with
#     Sparkle's generate_keys; move it to another Mac with `generate_keys --account harness-butler -x/-f`.
#     Its public half is SUPublicEDKey in project.yml. Losing it means users can't update.
#
# Before running: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION (Sparkle compares the
# latter) in project.yml, add the version's section to CHANGELOG.md, commit and tag.
#
# Output in .build/release: HarnessButler-<version>.dmg (+ .sha256) and appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-Q3DXPG4JBK}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-harness-butler-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-harness-butler}"
REPO="aegis-ventures-ai/harness-buddy"
APP_NAME="Harness Butler"
VERSION="$(awk '/MARKETING_VERSION:/ { print $2; exit }' project.yml)"
BUILD="$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)"
FEED="$(awk '/SUFeedURL:/ { print $2; exit }' project.yml)"
OUT=.build/release
APP="$OUT/derived/Build/Products/Release/$APP_NAME.app"
DMG="$OUT/HarnessButler-$VERSION.dmg"
SPARKLE_BIN="$OUT/derived/SourcePackages/artifacts/sparkle/Sparkle/bin"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

step "Checking the version"
grep -q "^## \[$VERSION\]" CHANGELOG.md || fail "CHANGELOG.md has no section for $VERSION"
# Sparkle offers an update only when CURRENT_PROJECT_VERSION is higher than the installed one.
if published="$(curl -fsSL --max-time 20 "$FEED" 2>/dev/null)"; then
    previous="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>|sparkle:version="[0-9]+"' <<<"$published" | grep -oE '[0-9]+' | sort -n | tail -1)"
    if [ -n "$previous" ] && [ "$BUILD" -le "$previous" ]; then
        fail "CURRENT_PROJECT_VERSION is $BUILD, but the published feed already has build $previous"
    fi
    echo "build $BUILD (published feed: ${previous:-none})"
else
    echo "build $BUILD (no published feed yet)"
fi

step "Building $APP_NAME $VERSION ($BUILD), Release, signed for team $TEAM_ID"
rm -rf "$OUT"
mkdir -p "$OUT"
# xcodebuild writes the app's package pins (Sparkle) into the kit's Package.resolved, which leaves
# the tree dirty and makes publish.sh refuse to run. Put the committed file back afterwards.
resolved=Packages/HarnessButlerKit/Package.resolved
resolved_backup="$(mktemp)"
cp "$resolved" "$resolved_backup"
restore_resolved() {
    if [ -f "$resolved_backup" ]; then cp "$resolved_backup" "$resolved" && rm -f "$resolved_backup"; fi
}
trap restore_resolved EXIT
xcodegen generate --quiet
xcodebuild -project HarnessButler.xcodeproj -scheme HarnessButler -configuration Release \
    -derivedDataPath "$OUT/derived" -destination "generic/platform=macOS" -quiet \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build
restore_resolved

step "Signing Sparkle's helpers"
# Xcode signs the framework but leaves its helpers ad-hoc, which notarization rejects. Inside out:
# helpers, then the framework, then the app (https://sparkle-project.org/documentation/sandboxing/).
sparkle="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements App/HarnessButler/HarnessButler.entitlements "$APP"

step "Checking the app"
codesign --verify --deep --strict --verbose=2 "$APP"
# Every executable inside must be ours, with the Hardened Runtime and a secure timestamp.
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q 'Mach-O' || continue
    details="$(codesign --display --verbose=4 "$file" 2>&1)" || fail "unsigned: ${file#"$APP"/}"
    grep -q "TeamIdentifier=$TEAM_ID" <<<"$details" || fail "not signed by team $TEAM_ID: ${file#"$APP"/}"
    grep -qE 'flags=0x[0-9a-f]*\(.*runtime' <<<"$details" || fail "no Hardened Runtime: ${file#"$APP"/}"
    grep -q '^Timestamp=' <<<"$details" || fail "no secure timestamp: ${file#"$APP"/}"
done < <(find "$APP" -type f -perm -u+x -print0)
# The notary service rejects the debugging entitlement Xcode adds to development builds.
if codesign --display --entitlements - --xml "$APP" 2>/dev/null | grep -q 'get-task-allow'; then
    fail "the app has the get-task-allow entitlement"
fi
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$VERSION" ] || fail "app says $(plist CFBundleShortVersionString), expected $VERSION"
[ "$(plist CFBundleVersion)" = "$BUILD" ] || fail "app build is $(plist CFBundleVersion), expected $BUILD"
public_key="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
[ "$(plist SUPublicEDKey)" = "$public_key" ] || fail "SUPublicEDKey doesn't match the '$SPARKLE_ACCOUNT' key in the keychain"

step "Making the DMG"
stage="$OUT/dmg"
mkdir -p "$stage"
ditto "$APP" "$stage/$APP_NAME.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"
# hdiutil create has once written a corrupt image that still signed fine; notarytool then rejected
# it as "not a UDIF disk image". Check the image's checksums before spending a notarization on it.
hdiutil verify -quiet "$DMG" || fail "$DMG is corrupt (hdiutil verify failed); run the script again"

if [ "${SKIP_NOTARIZE:-0}" = 1 ]; then
    step "Skipping notarization and the appcast (SKIP_NOTARIZE=1): don't publish this DMG"
    echo "$DMG"
    exit 0
fi

step "Notarizing (this usually takes a few minutes)"
result="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json)"
status="$(plutil -extract status raw - <<<"$result")"
if [ "$status" != "Accepted" ]; then
    id="$(plutil -extract id raw - <<<"$result")"
    echo "error: notarization finished with status '$status'; Apple's log follows" >&2
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
fi

step "Stapling the ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

step "Making the appcast"
# Release notes: this version's CHANGELOG section, next to the DMG so generate_appcast embeds it.
feed_dir="$OUT/appcast"
mkdir -p "$feed_dir"
cp "$DMG" "$feed_dir/"
awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" { on = 1; next } /^## \[/ { on = 0 } /^\[[0-9.]+\]: / { on = 0 } on' CHANGELOG.md \
    > "$feed_dir/HarnessButler-$VERSION.md"
# generate_appcast and sign_update would each trigger a keychain prompt for the key (only
# generate_keys, which created it, may read it silently) and block an unattended run. So
# generate_keys exports it to a private temporary file that is deleted on exit.
key_dir="$(mktemp -d)"
trap 'restore_resolved; rm -rf "$key_dir"' EXIT
(umask 077 && "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "$key_dir/key" >/dev/null)
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$key_dir/key" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --full-release-notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
    --link "https://github.com/$REPO" \
    --embed-release-notes --maximum-versions 1 \
    "$feed_dir"
cp "$feed_dir/appcast.xml" "$OUT/appcast.xml"
grep -q "sparkle:edSignature=" "$OUT/appcast.xml" || fail "the appcast item has no EdDSA signature"
grep -q "<sparkle:version>$BUILD</sparkle:version>\|sparkle:version=\"$BUILD\"" "$OUT/appcast.xml" || fail "the appcast doesn't list build $BUILD"
signature="$(grep -oE 'sparkle:edSignature="[^"]+"' "$OUT/appcast.xml" | head -1 | cut -d'"' -f2)"
"$SPARKLE_BIN/sign_update" --ed-key-file "$key_dir/key" --verify "$DMG" "$signature"
rm -rf "$key_dir"

step "Done"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
ls -1 "$DMG" "$DMG.sha256" "$OUT/appcast.xml"
cat "$DMG.sha256"
