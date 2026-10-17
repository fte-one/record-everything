#!/bin/zsh
# Builds and publishes a release.
#
#   ./scripts/release.sh 1.1.0        set version 1.1.0 (build number + 1), then release
#   ./scripts/release.sh              release the version that is in Support/Info.plist
#
# Steps: universal build with Developer ID signature -> DMG -> notarization and stapling ->
# Sparkle appcast signed with the EdDSA key from the keychain -> GitHub release with
# Record-Everything-<version>.dmg, Record-Everything.dmg (stable download link) and appcast.xml.
# The installed apps read .../releases/latest/download/appcast.xml and update themselves.
#
#   NOTARY_PROFILE=...  notarytool keychain profile (default: crispyflow-notary, same Apple team)
#   SPARKLE_ACCOUNT=... keychain account of the Sparkle key (default: record-everything)
#   SKIP_NOTARIZE=1     local test: stop after the signed DMG, never publishes
#   PUBLISH=0           build, notarize and write the appcast, but do not publish
#   YES=1               publish without asking
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
REPO="fte-one/record-everything"
PLIST="Support/Info.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-crispyflow-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-record-everything}"
APP="$ROOT/build/Record Everything.app"
DIST="$ROOT/dist"
PB=/usr/libexec/PlistBuddy

# 1) Version.
if [[ -n "${1:-}" ]]; then
  BUILD=$(( $($PB -c 'Print :CFBundleVersion' "$PLIST") + 1 ))
  $PB -c "Set :CFBundleShortVersionString $1" -c "Set :CFBundleVersion $BUILD" "$PLIST"
  echo "==> Version $1 (build $BUILD) written to $PLIST"
fi
VERSION="$($PB -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$($PB -c 'Print :CFBundleVersion' "$PLIST")"
DMG="$DIST/Record-Everything-$VERSION.dmg"

if [[ -z "${SKIP_NOTARIZE:-}" && "${PUBLISH:-1}" != "0" ]] && gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists on GitHub. Pass a new version: ./scripts/release.sh <version>" >&2
  exit 1
fi

# 2) Universal build with the Developer ID (no ad-hoc fallback for releases).
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No \"Developer ID Application\" identity in the keychain." >&2
  exit 1
fi
CONFIG=release ARCHS="arm64 x86_64" SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/build-app.sh"

# 3) DMG with the app and an Applications link, signed with the same identity.
echo "==> Creating $DMG"
mkdir -p "$DIST"
STAGING="$(mktemp -d)"
APPCAST_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING" "$APPCAST_DIR"' EXIT
ditto "$APP" "$STAGING/Record Everything.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Record Everything" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
  echo "Signed, not notarized (not publishable): $DMG"
  exit 0
fi

# 4) Notarize and staple the DMG and the app.
echo "==> Notarizing (profile: $NOTARY_PROFILE)"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
  cat >&2 <<'MSG'
Notarization failed. Common causes:
  - HTTP 403 "agreement missing or expired": the team's Account Holder has to accept the current
    Apple Developer Program License Agreement on developer.apple.com (Account) and in App Store Connect.
  - Missing profile: xcrun notarytool store-credentials <name> --apple-id ... --team-id ... --password <app-specific password>
MSG
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# 5) Appcast for exactly this DMG, signed with the EdDSA key from the keychain.
echo "==> Creating appcast"
cp "$DMG" "$APPCAST_DIR/"
"$ROOT/Vendor/bin/generate_appcast" --account "$SPARKLE_ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/$REPO/releases" \
  --link "https://github.com/$REPO" \
  "$APPCAST_DIR"
cp "$APPCAST_DIR/appcast.xml" "$DIST/appcast.xml"
cp "$DMG" "$DIST/Record-Everything.dmg"

if [[ "${PUBLISH:-1}" == "0" ]]; then
  echo "Release built, not published: $DMG, $DIST/appcast.xml"
  exit 0
fi

# 6) Commit the version, push, publish the GitHub release.
if [[ -z "${YES:-}" ]]; then
  read -r "REPLY?==> Commit version $VERSION ($BUILD), push and publish release v$VERSION on GitHub? [y/N] "
  [[ "$REPLY" == [yYjJ]* ]] || { echo "Not published. Files are in $DIST."; exit 0; }
fi
if ! git diff --quiet -- "$PLIST"; then
  git commit -m "Release $VERSION" -- "$PLIST"
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Uncommitted changes besides the version; commit them first." >&2
  exit 1
fi
git push origin HEAD
NOTES="$ROOT/release-notes/$VERSION.md"
NOTES_ARGS=(--generate-notes)
[[ -f "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "v$VERSION" --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "Record Everything $VERSION" "${NOTES_ARGS[@]}" \
  "$DMG" "$DIST/Record-Everything.dmg" "$DIST/appcast.xml"
echo "Published: https://github.com/$REPO/releases/tag/v$VERSION"
echo "Download:  https://github.com/$REPO/releases/latest/download/Record-Everything.dmg"
