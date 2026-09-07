#!/bin/bash
# Runs the Phase 2 "Da" (skin) slider measurement and files the result under
# Research/bench/.
#
# The measurement is an ordinary test in RPEngineTests (SkinBenchTests); it prints
# one line starting with "RPBENCH-P2SKIN " containing the JSON, and this script
# scrapes that line — so the number filed under Research/ is always the number the
# test actually measured (docs/PLAN.md §5, "measure before ship").
#
# The JSON carries **both** halves of the claim:
#   golden.*  PSNR against SkinReference, the Double CPU control. Runs anywhere.
#   speed.*   ms/frame at a 2048 px preview and at 24 MP, on the real a6300 frame
#             spike S3 already uses. Needs the gitignored fixtures:
#               Research/spikes/S3-guided-filter-mls/images/full/*.jpg
#               Research/spikes/S3-guided-filter-mls/control/*.json   (s3harness controlpoints)
#             Without them the JSON has "speed_skipped" instead and this script
#             still writes the file — the accuracy half is the part that gates the
#             plan's 45 dB bar.
#
# Same three flags as Scripts/bench-s3.sh, for the same reasons:
#   -only-testing:...       run just this suite
#   -parallel-testing-enabled NO   do not contend for the GPU
#   -configuration Release  the CGImage -> float32 -> float16 upload of a 24 MP
#                           frame is plain Swift/vImage and is several times
#                           slower in a Debug bundle
#
# Set RP_SKIP_FULL_RES=1 to leave out the 24 MP pass (it holds ~550 MB of Metal
# textures).
#
# Usage: Scripts/bench-skin.sh [macos|ios|all]   (default: all)

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
        -only-testing:RPEngineTests/SkinBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P2SKIN-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P2SKIN-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P2SKIN ' "$log" | sed 's/^RPBENCH-P2SKIN //' >"$outfile"; then
        echo "no RPBENCH-P2SKIN line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p2-skin-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p2-skin-ios-simulator.json"
fi
