#!/bin/bash
# Runs the Phase 6 canvas-histogram measurement and files the result under
# Research/bench/ (docs/ADR-0024).
#
# The measurement is an ordinary test in RPEngineTests (HistogramBenchTests); it
# prints one line starting with "RPBENCH-P6HIST " containing the JSON, and this
# script scrapes that line — so the number filed under Research/ is always the
# number the test actually measured (docs/PLAN.md §5, "measure before ship").
#
# What the JSON claims, and what it does not:
#   pass    ms for the clear + accumulate dispatch alone at a 2048 px preview,
#           measured around commit + waitUntilCompleted, so it is an upper bound
#           on the GPU time rather than a GPU counter.
#   drag    ms/redraw over 60 back-to-back LivePreviewRenderer redraws with a
#           changing slider value, **with** and **without** a histogram sample
#           attached. The "without" run is the control; the difference is what a
#           live histogram costs an interactive drag.
#   stall   main-thread ms to encode + commit one sample, against
#           LivePreviewRenderer.readOutputPixels() — the documented stalling
#           readback the sampler exists to avoid — on the same texture in the
#           same run.
#
# None of them says the plot is *correct*. The correctness claim for this item
# is RPEngineTests/HistogramTests, which asserts exact bucket counts on textures
# whose answer is known by construction (half pure red / half black, a ramp of
# bucket-centre values, out-of-range floats).
#
# Needs no fixture files: everything is synthetic, so this runs anywhere.
#
# Same three flags as the other bench scripts, for the same reasons:
#   -only-testing:...              run just this suite
#   -parallel-testing-enabled NO   do not contend for the GPU
#   -configuration Release         the CGImage -> float32 -> float16 upload in
#                                  the drag fixture is plain Swift and is several
#                                  times slower in a Debug bundle
#
# Usage: Scripts/bench-histogram.sh [macos|ios|all]   (default: macos)
#
# The default is macOS alone, unlike the older bench scripts: the histogram
# overlay is a **macOS-only** feature this round (docs/ADR-0024 §6), so there is
# no iOS number to file. Pass `ios` explicitly if that ever changes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$ROOT/RetouchPro.xcworkspace"
SCHEME="RetouchPro"
# Plan §0.2: iPadOS deployment was removed entirely, iOS means iPhone. Same default as Scripts/test.sh.
IOS_DESTINATION="${RP_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
OUT_DIR="$ROOT/Research/bench"
WHICH="${1:-macos}"

mkdir -p "$OUT_DIR"

capture() {
    local label="$1" destination="$2" outfile="$3"
    echo "=== bench $label ==="
    local log
    log="$(mktemp)"
    xcodebuild test -workspace "$WORKSPACE" -scheme "$SCHEME" \
        -destination "$destination" \
        -only-testing:RPEngineTests/HistogramBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P6HIST-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P6HIST-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P6HIST ' "$log" | sed 's/^RPBENCH-P6HIST //' >"$outfile"; then
        echo "no RPBENCH-P6HIST line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p6-histogram-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p6-histogram-ios-simulator.json"
fi
