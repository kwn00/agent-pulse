#!/usr/bin/env bash
# Builds a universal Agent Pulse.app and zips it the way releases (and the Homebrew cask) expect:
#   build/AgentPulse-<version>.zip + build/AgentPulse-<version>.zip.sha256
#
#   scripts/package.sh            # version from the latest v* tag, else 0.0.0
#   VERSION=1.2.3 scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//')"
  VERSION="${VERSION:-0.0.0}"
fi
export VERSION
export UNIVERSAL="${UNIVERSAL:-1}"

scripts/build-app.sh release

ZIP="build/AgentPulse-${VERSION}.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "build/Agent Pulse.app" "$ZIP"
(cd build && shasum -a 256 "AgentPulse-${VERSION}.zip" > "AgentPulse-${VERSION}.zip.sha256")

echo "✓ $ZIP"
cat "$ZIP.sha256"
