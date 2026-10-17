#!/bin/zsh
# Renders the app icon from scripts/make-icon.swift into Resources/AppIcon.icns.
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
SDK_ARGS=()
for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk(NOn); do SDK_ARGS=(-sdk "$candidate"); break; done
swiftc -O "${SDK_ARGS[@]}" -o "$TMP/make-icon" "$ROOT/scripts/make-icon.swift"
"$TMP/make-icon" "$ROOT"
rm -rf "$TMP"
