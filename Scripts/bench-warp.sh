#!/bin/bash
# Runs the Phase 2 "Mặt" (face reshape) measurement and files the result under
# Research/bench/.
#
# The measurement is an ordinary test in RPEngineTests (WarpBenchTests); it prints
# one line starting with "RPBENCH-P2WARP " containing the JSON, and this script
# scrapes that line — so the number filed under Research/ is always the number the
# test actually measured (docs/PLAN.md §5, "measure before ship").
#
# The JSON carries four things:
#   geometry.*        are FaceMesh's index lists on the part of the face they name,
#                     measured on the 11 real a6300 meshes
#   handles.*         how far each slider moves the face at 100, as a fraction of
#                     face width — the magnitude table, verified not restated
#   accuracy.*        level 1 (GPU grid solve vs the Double CPU MLSDeformation) and
#                     level 2 (landmark round trip through the 65/129 lattice)
#   rendered_golden.* level 3: PSNR of the rendered warp against WarpReference, a
#                     Double CPU rasterisation of the same mesh
#   speed.*           ms/frame at a 2048 px preview and at the real 24 MP frame
#
# Every one of them needs a fixture — a reshape slider has nothing to measure
# without a face. The gitignored ones are:
#   Research/phase2/face-analyzer/results/a6300/twostage.json  (11 real meshes)
#   Research/spikes/S1-landmark/a6300/images/raw/*.jpg         (the 2691² frames)
#   Research/spikes/S1-landmark/a6300/manifest.json            (crop offsets)
#   Research/spikes/S3-guided-filter-mls/images/full/*.jpg     (the 24 MP frames)
# Without them the JSON says which half was skipped and this script still writes
# the file.
#
# Same three flags as Scripts/bench-skin.sh, for the same reasons:
#   -only-testing:...              run just this suite
#   -parallel-testing-enabled NO   do not contend for the GPU
#   -configuration Release         the CGImage -> float32 -> float16 upload of a
#                                  24 MP frame is plain Swift/vImage and is
#                                  several times slower in a Debug bundle
#
# Set RP_SKIP_FULL_RES=1 to leave out the 24 MP pass.
#
# Usage: Scripts/bench-warp.sh [macos|ios|all]   (default: all)

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
        -only-testing:RPEngineTests/WarpBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P2WARP-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P2WARP-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P2WARP ' "$log" | sed 's/^RPBENCH-P2WARP //' >"$outfile"; then
        echo "no RPBENCH-P2WARP line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p2-warp-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p2-warp-ios-simulator.json"
fi
