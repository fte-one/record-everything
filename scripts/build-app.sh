#!/bin/zsh
# Builds and signs "Record Everything.app" into ./build.
#   CONFIG=debug|release   default release
#   ARCHS="arm64 x86_64"   architectures to build (default: this Mac's); several give a universal binary
#   SIGN_IDENTITY=...      code signing identity; "-" signs ad hoc.
#                          Default: the first "Developer ID Application" identity, else any valid one, else ad hoc.
#   SDK=...                SDK path override
# A stable identity keeps the macOS screen recording and microphone permissions across rebuilds.
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${CONFIG:-release}"
ARCHS=(${=ARCHS:-$(uname -m)})
APP="$ROOT/build/Record Everything.app"
ENTITLEMENTS="$ROOT/Support/RecordEverything.entitlements"

cd "$ROOT"
VENDOR="$ROOT/Vendor"
[[ -d "$VENDOR/Sparkle.framework" ]] || "$ROOT/scripts/fetch-sparkle.sh"
OUT="$ROOT/build/$CONFIG"
mkdir -p "$OUT"
if [[ "$CONFIG" == "release" ]]; then OPT=(-O -whole-module-optimization); else OPT=(-Onone -g); fi

# The macOS 27 SDK turns @State into a macro whose plugin ships only with Xcode.
# With Command Line Tools alone, build against the newest macOS 26 SDK instead.
if [[ -z "${SDK:-}" ]]; then
  SDK="$(xcrun --show-sdk-path)"
  if [[ ! -d "$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/SwiftUIMacros.framework" ]] \
     && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk(NOn) /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
      [[ -d "$candidate" ]] && { SDK="$candidate"; break; }
    done
  fi
fi

# Compiled with swiftc directly: the SwiftPM manifest API of the installed Command Line Tools does not link.
SOURCES=("${(@f)$(find "$ROOT/Sources/RecordEverything" -name '*.swift' | sort)}")
SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "==> Compiling $arch ($CONFIG)"
  swiftc "${OPT[@]}" \
    -swift-version 5 \
    -target "$arch-apple-macos15.0" \
    -sdk "$SDK" \
    -module-name RecordEverything \
    -framework ScreenCaptureKit -framework AVFoundation -framework AVKit -framework Carbon \
    -framework ServiceManagement -framework IOKit \
    -F "$VENDOR" -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "$OUT/RecordEverything-$arch" \
    "${SOURCES[@]}"
  SLICES+=("$OUT/RecordEverything-$arch")
done
lipo -create "${SLICES[@]}" -output "$OUT/RecordEverything"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/RecordEverything" "$APP/Contents/MacOS/RecordEverything"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
for lproj in "$ROOT"/Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# ditto keeps the framework's symlinks intact.
mkdir -p "$APP/Contents/Frameworks"
ditto "$VENDOR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null)"
  SIGN_IDENTITY="$(print -r -- "$identities" | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  [[ -z "$SIGN_IDENTITY" ]] && SIGN_IDENTITY="$(print -r -- "$identities" | awk -F'"' '/"/ {print $2; exit}')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

# Hardened runtime is required for notarization; the entitlements keep camera and microphone working under it.
# Inside out: first Sparkle with its helpers (Autoupdate, Updater.app, XPC services), then the app that seals it.
BASE_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" && "$CONFIG" == "release" ]] && BASE_ARGS+=(--timestamp)
codesign "${BASE_ARGS[@]}" --deep "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${BASE_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo "Built $APP"
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/RecordEverything")"
echo "  signed with:   $SIGN_IDENTITY"
