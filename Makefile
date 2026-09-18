# Agent Pulse — convenience targets. `make app` is all most people need.

APP := build/Agent\ Pulse.app

.PHONY: app package run debug test probe snapshot icon xcodeproj clean

## Release .app bundle via SwiftPM (no Xcode project needed)
app:
	scripts/build-app.sh release

## Build + launch the bundle
run: app
	open $(APP)

## Universal release zip + sha256 in build/ (what CI attaches to a GitHub Release)
package:
	scripts/package.sh

## Fast debug build + run as a bare executable (no LSUIElement; fine for hacking)
debug:
	swift build && .build/debug/AgentPulse

test:
	swift test

## Fetch every provider once and print what the panel would show
probe:
	swift build && .build/debug/AgentPulse --probe

## Render the panel offscreen to build/panel.png (add SETTINGS=1 for the settings pane)
snapshot:
	swift build && mkdir -p build && .build/debug/AgentPulse --snapshot build/panel.png $(if $(SETTINGS),--settings,)

icon:
	swift scripts/make-icon.swift Support/AppIcon.icns

## Generate AgentPulse.xcodeproj (requires `brew install xcodegen`)
xcodeproj:
	xcodegen generate

clean:
	rm -rf .build build AgentPulse.xcodeproj
