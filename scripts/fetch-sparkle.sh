#!/bin/zsh
# Downloads the pinned Sparkle release (framework + signing tools) into Vendor/ (not checked in).
# Run once before the first build, or with --force to replace it.
set -euo pipefail

ROOT="${0:A:h:h}"
SPARKLE_VERSION="2.9.4"
VENDOR="$ROOT/Vendor"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

if [[ -d "$VENDOR/Sparkle.framework" && "${1:-}" != "--force" ]]; then
  echo "Sparkle is already in $VENDOR (reload with --force)."
  exit 0
fi

echo "==> Downloading Sparkle $SPARKLE_VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/sparkle.tar.xz"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP"
rm -rf "$VENDOR/Sparkle.framework" "$VENDOR/bin"
mkdir -p "$VENDOR"
ditto "$TMP/Sparkle.framework" "$VENDOR/Sparkle.framework"
ditto "$TMP/bin" "$VENDOR/bin"
echo "==> Sparkle $SPARKLE_VERSION in $VENDOR ($(lipo -archs "$VENDOR/Sparkle.framework/Versions/Current/Sparkle"))"
