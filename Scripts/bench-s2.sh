#!/bin/bash
# Runs the RPVision spike-S2 face-parsing benchmark on a destination and files the
# result under Research/bench/.
#
# The benchmark is an ordinary test in RPVisionTests; it prints one line starting
# with "RPBENCH-S2 " containing the JSON. This script scrapes that line, so the
# number in Research/bench/ is always the number the test actually measured.
#
# Two things differ from Scripts/bench-s1.sh, both deliberate:
#   -only-testing:.../FaceParsingModelTests   run just this suite
#   -parallel-testing-enabled NO              do not run suites concurrently
#   -configuration Release                    build the test bundle optimised
# The last one is the big one: reading the model's 262 144-element label output is
# a plain Swift loop, and a Debug bundle spends ~36 ms in it. Measured on this Mac,
# same model, same image: 5.8 ms in an optimised binary, 42 ms in a Debug test
# bundle. See Research/spikes/S2-face-parsing/S2-face-parsing.md §6.
#
# Usage: Scripts/bench-s2.sh [macos|ios|all]   (default: all)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$ROOT/RetouchPro.xcworkspace"
SCHEME="RetouchPro"
# Plan §0.1: iPad is paused, iOS means iPhone. Same default as Scripts/test.sh.
IOS_DESTINATION="${RP_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
OUT_DIR="$ROOT/Research/bench"
WHICH="${1:-all}"

mkdir -p "$OUT_DIR"

capture() {
    local label="$1" destination="$2" outfile="$3"
    echo "=== bench $label ==="
    local log
    log="$(mktemp)"
    xcodebuild test -workspace "$WORKSPACE" -scheme "$SCHEME" \
        -destination "$destination" \
        -only-testing:RPVisionTests/FaceParsingModelTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if ! grep -m1 '^RPBENCH-S2 ' "$log" | sed 's/^RPBENCH-S2 //' >"$outfile"; then
        echo "no RPBENCH-S2 line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/s2-face-parsing-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" \
        "$OUT_DIR/s2-face-parsing-ios-simulator.json"
fi
