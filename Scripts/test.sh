#!/bin/bash
# Runs the full RetouchPro test suite on both supported destinations.
#
# Seven test bundles run, all of them from the one shared scheme:
#   RPCoreTests RPVisionTests RPEngineTests RPImportTests RPUITests RPTestKitTests
#   RetouchProAppTests   <- app-target tests (App/FaceAnalysisRenderBridge.swift)
#
# `RetouchProAppTests` lives in RetouchPro.xcodeproj rather than in a package,
# because the code it tests is in the app target: the bridge from RPVision's
# `FaceAnalysis` to RPEngine's `FaceRenderInput` cannot live in either package
# (RPEngine does not import RPVision). It has **no TEST_HOST** and compiles
# `App/FaceAnalysisRenderBridge.swift` into itself, so it needs no app launch and
# runs on both destinations below — see the header of
# AppTests/FaceAnalysisRenderBridgeTests.swift.
#
# NOTE: the workspace flag is required. Xcode only schedules a local Swift
# package's test target when the package is a *workspace* member; with
# `-project RetouchPro.xcodeproj` xcodebuild silently drops every package test
# and fails with "There are no test bundles available to test".
# See docs/ADR-0001-project-skeleton.md.
#
# Usage: Scripts/test.sh [macos|ios|all]   (default: all)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$ROOT/RetouchPro.xcworkspace"
SCHEME="RetouchPro"
SCHEME_FILE="$ROOT/RetouchPro.xcodeproj/xcshareddata/xcschemes/$SCHEME.xcscheme"

# A test bundle that is not in the scheme's <Testables> is silently not run —
# `xcodebuild test` still reports success. Check membership up front so a
# dropped target is an error here and not a quiet gap in coverage.
for bundle in RPCoreTests RPVisionTests RPEngineTests RPImportTests RPUITests \
              RPTestKitTests RetouchProAppTests; do
    if ! grep -q "BlueprintName = \"$bundle\"" "$SCHEME_FILE"; then
        echo "error: $bundle is missing from $SCHEME_FILE <Testables>; it would not run." >&2
        exit 1
    fi
done
# Plan §0.1: iPad is paused, iOS means iPhone for now.
# The name must exist on the *latest* installed runtime, because xcodebuild resolves
# a name-only destination with OS:latest. On this machine `iPhone 16` only exists on
# the iOS 18.0 runtime (iOS 26.3 ships 17/17 Pro/Air/16e), so `name=iPhone 16` alone
# fails with "Unable to find a device matching ... {OS:latest, name:iPhone 16}".
# To test the iOS 18 deployment floor instead, run with
#   RP_IOS_DESTINATION='platform=iOS Simulator,name=iPhone 16,OS=18.0' Scripts/test.sh
# Check what exists here with: xcrun simctl list devices available
IOS_DESTINATION="${RP_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
WHICH="${1:-all}"

run() {
    local label="$1"
    shift
    echo "=== $label ==="
    xcodebuild test -workspace "$WORKSPACE" -scheme "$SCHEME" "$@"
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    run "macOS" -destination 'platform=macOS'
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    run "iOS Simulator — $IOS_DESTINATION" -destination "$IOS_DESTINATION"
fi
