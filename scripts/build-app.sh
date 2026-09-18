#!/usr/bin/env bash
# Builds Agent Pulse with SwiftPM and wraps it into a signed (ad-hoc) .app bundle.
#
#   scripts/build-app.sh            # release build → build/Agent Pulse.app
#   scripts/build-app.sh debug      # debug build
#   UNIVERSAL=1 scripts/build-app.sh  # arm64 + x86_64 slice
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_NAME="Agent Pulse"
EXECUTABLE="AgentPulse"
BUNDLE_ID="dev.agentpulse.app"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

# Prefer the full Xcode toolchain when Command Line Tools are selected but Xcode is installed.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# `${ARR[@]+"${ARR[@]}"}` keeps `set -u` happy on macOS's bash 3.2 when the array is empty.
echo "▸ swift build -c $CONFIGURATION ${ARCH_FLAGS[*]+${ARCH_FLAGS[*]}}"
swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_PATH="$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$EXECUTABLE"

if [[ ! -f Support/AppIcon.icns ]]; then
  echo "▸ rendering app icon"
  swift scripts/make-icon.swift Support/AppIcon.icns
fi

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$EXECUTABLE"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

sed \
  -e "s|\$(EXECUTABLE_NAME)|$EXECUTABLE|g" \
  -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
  -e "s|\$(MARKETING_VERSION)|$VERSION|g" \
  -e "s|\$(CURRENT_PROJECT_VERSION)|$BUILD_NUMBER|g" \
  -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|14.0|g" \
  Support/Info.plist > "$APP/Contents/Info.plist"

echo "▸ codesign (ad-hoc)"
codesign --force --sign - --timestamp=none --options runtime "$APP" 2>/dev/null || codesign --force --sign - "$APP"

echo "✓ $APP"
echo "  open \"$APP\"        # run it"
echo "  cp -R \"$APP\" /Applications"
