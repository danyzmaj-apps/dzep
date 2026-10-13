#!/usr/bin/env bash
# Builds, signs, notarizes and publishes the Mac app as a DMG on GitHub
# Releases, with the Sparkle appcast the installed apps update from.
#
#   apps/dzep-macos-app/tool/release.sh            the version in this app's pubspec.yaml → GitHub release v<version>
#   apps/dzep-macos-app/tool/release.sh --dry-run  same build, signed for development, nothing notarized or published
#
# Needs (checked below): Xcode signed in to the team in config/Dzep.xcconfig
# with a "Developer ID Application" certificate, a notarytool keychain profile
# (`xcrun notarytool store-credentials dzep-notary`), the Sparkle signing key
# in the login keychain (macos/Pods/Sparkle/bin/generate_keys), fvm and gh.
# See docs/RELEASING.md.
set -euo pipefail
# Runs in the Mac app (apps/dzep-macos-app); config/ and CHANGELOG.md are the repo's, two levels up.
cd "$(dirname "$0")/.."
ROOT=../..

DRY=false
[[ "${1:-}" == "--dry-run" ]] && DRY=true
NOTARY_PROFILE="${NOTARY_PROFILE:-dzep-notary}"
REPO="${REPO:-danyzmaj-apps/dzep}"

die() { echo "release: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

VERSION=$(sed -n 's/^version: *\([0-9.]*\)+\{0,1\}.*/\1/p' pubspec.yaml)
[[ -n "$VERSION" ]] || die "no version in pubspec.yaml"
TEAM=""
[[ -f $ROOT/config/Local.xcconfig ]] && TEAM=$(sed -n 's/^DZEP_TEAM *= *//p' $ROOT/config/Local.xcconfig | tail -1)
[[ -n "$TEAM" ]] || TEAM=$(sed -n 's/^DZEP_TEAM *= *//p' $ROOT/config/Dzep.xcconfig | tail -1)
OUT=build/release
SPARKLE=macos/Pods/Sparkle/bin
DMG="$OUT/Dzep-$VERSION.dmg"

step "Checking prerequisites (v$VERSION, team $TEAM)"
command -v fvm >/dev/null || die "fvm is not installed (https://fvm.app)"
if ! $DRY; then
  command -v gh >/dev/null || die "gh is not installed (brew install gh)"
  [[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes"
  git rev-parse "v$VERSION" >/dev/null 2>&1 && die "tag v$VERSION exists; bump the version in pubspec.yaml"
  grep -q "^## $VERSION" $ROOT/CHANGELOG.md || die "CHANGELOG.md has no '## $VERSION' section"
  security find-identity -v -p codesigning | grep -q "Developer ID Application.*($TEAM)" \
    || die "no 'Developer ID Application' certificate for team $TEAM (Xcode → Settings → Accounts → Manage Certificates → +)"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notarytool profile '$NOTARY_PROFILE' (xcrun notarytool store-credentials $NOTARY_PROFILE)"
fi

step "Building"
rm -rf "$OUT" && mkdir -p "$OUT"
fvm flutter build macos --release
[[ -x "$SPARKLE/generate_keys" ]] || die "Sparkle isn't installed (cd macos && pod install)"
$DRY || "$SPARKLE/generate_keys" -p >/dev/null 2>&1 || die "no Sparkle signing key in the keychain (see docs/RELEASING.md)"

step "Archiving"
xcodebuild -quiet -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
  -archivePath "$OUT/Dzep.xcarchive" -allowProvisioningUpdates archive

step "Exporting ($($DRY && echo development || echo developer-id))"
cat >"$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>$($DRY && echo debugging || echo developer-id)</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -quiet -exportArchive -archivePath "$OUT/Dzep.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/export.plist" -allowProvisioningUpdates
APP="$OUT/export/Dzep.app"
codesign --verify --deep --strict "$APP"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$OUT/notary.log"
  grep -q "status: Accepted" "$OUT/notary.log" || die "notarization failed for $1 (see $OUT/notary.log)"
}

if ! $DRY; then
  step "Notarizing the app"
  ditto -c -k --keepParent "$APP" "$OUT/Dzep.zip"
  notarize "$OUT/Dzep.zip"
  xcrun stapler staple "$APP"
fi

step "Making the DMG"
mkdir -p "$OUT/dmg" && cp -R "$APP" "$OUT/dmg/" && ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Džep $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format ULFO "$DMG"
if ! $DRY; then
  codesign --sign "Developer ID Application" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi

if $DRY; then
  step "Dry run done: $DMG (development-signed, not notarized, not published)"
  exit 0
fi

step "Writing the appcast"
mkdir -p "$OUT/appcast" && cp "$DMG" "$OUT/appcast/"
# The previous appcast keeps older versions listed (and enables delta updates).
gh release download --repo "$REPO" --pattern appcast.xml --dir "$OUT/appcast" 2>/dev/null || true
"$SPARKLE/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
  "$OUT/appcast"

step "Publishing v$VERSION"
awk -v v="$VERSION" '$0 ~ "^## "v {on=1; next} /^## / {on=0} on' $ROOT/CHANGELOG.md >"$OUT/notes.md"
git tag "v$VERSION" && git push origin "v$VERSION"
gh release create "v$VERSION" --repo "$REPO" --title "Džep $VERSION" --notes-file "$OUT/notes.md" \
  "$DMG" "$OUT/appcast/appcast.xml"
echo "Released: https://github.com/$REPO/releases/tag/v$VERSION"
