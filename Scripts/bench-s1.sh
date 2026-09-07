#!/bin/bash
# Runs the RPVision spike-S1 landmark benchmark on a destination and files the
# result under Research/bench/.
#
# The benchmark is an ordinary test in RPVisionTests; it prints one line starting
# with "RPBENCH " containing the JSON. This script just scrapes that line, so the
# number in Research/bench/ is always the number the test actually measured.
#
# Usage: Scripts/bench-s1.sh [macos|ios|all]   (default: all)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$ROOT/RetouchPro.xcworkspace"
SCHEME="RetouchPro"
IOS_DESTINATION="${RP_IOS_DESTINATION:-platform=iOS Simulator,name=iPad (A16)}"
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
        -only-testing:RPVisionTests >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if ! grep -m1 '^RPBENCH ' "$log" | sed 's/^RPBENCH //' >"$outfile"; then
        echo "no RPBENCH line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/s1-landmark-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/s1-landmark-ios-simulator.json"
fi
