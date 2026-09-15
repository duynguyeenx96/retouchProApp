#!/bin/bash
# Runs the Phase 6 §6.2 "Tạo khối" (Contour) measurement and files the result
# under Research/bench/.
#
# The measurement is an ordinary test in RPEngineTests (ContourBenchTests); it
# prints one line starting with "RPBENCH-P6CONTOUR " containing the JSON, and
# this script scrapes that line — so the number filed under Research/ is always
# the number the test actually measured (docs/PLAN.md §5, "measure before ship").
# Same arrangement as Scripts/bench-color.sh … bench-background-lock.sh.
#
# The JSON carries four claims, deliberately separate, because contour adds only
# a mask to a step that is already measured (the dodge/burn LUT, docs/ADR-0012):
#   golden.*       PSNR against ColorReference, the Double CPU control, extended
#                  with the one new step and fed the node's OWN uploaded lobes.
#                  Says the GPU evaluates the documented ellipse, in the
#                  documented order, with the documented falloff. Bar: the plan's
#                  45 dB. Runs anywhere.
#   selectivity.*  mean signed luminance change per contour zone, and worst |Δ|
#                  per control zone. Says "Gò má" lands on the cheekbone and
#                  moves the forehead centre by *exactly* 0 — the thing a PSNR
#                  cannot say, because a mask computing the documented falloff in
#                  the wrong place scores just as well. ADR-0011's shape, restated
#                  for the three contour zones. Runs anywhere.
#   coverage.*     the fraction of the frame the mask claims at four thresholds.
#                  §6.2's whole requirement is "theo mesh, không toàn khung"; this
#                  is that requirement as a number. Runs anywhere.
#   speed.*        ms/frame at a 2048 px preview and at 24 MP on the real a6300
#                  frame, with the contour branch off and on, so the MARGINAL cost
#                  of the eleven lobes is visible rather than buried in the colour
#                  grade's. Needs the gitignored fixtures:
#                    Research/spikes/S3-guided-filter-mls/images/full/*.jpg
#                  Without them the JSON has "speed_skipped" instead and this
#                  script still writes the file — the accuracy half is the part
#                  that gates the plan's 45 dB bar.
#
# None of it says the result is *pretty*. Every geometric constant in ContourMask
# (positions, half-extents, tilts, peak strengths) is argued from where the
# anatomy is and is untuned; the JSON says so in "constants_are_tuned": false,
# the same disclosure docs/ADR-0010 … ADR-0012 make for their groups.
#
# **Mac / iOS-Simulator numbers only**, as for every other node in this project;
# `is_real_device` in the JSON says which machine produced it. Unlike
# Scripts/bench-background-lock.sh there is no Simulator limitation to work
# around here — this is one compute kernel over a texture, so the Simulator
# result is a genuine (host-GPU) number, not a hole.
#
# Same three flags as the other bench scripts, for the same reasons:
#   -only-testing:...              run just this suite
#   -parallel-testing-enabled NO   do not contend for the GPU
#   -configuration Release         the CGImage -> float32 -> float16 upload of a
#                                  24 MP frame, and the CPU-side coverage sums,
#                                  are plain Swift and several times slower in a
#                                  Debug bundle
#
# Set RP_SKIP_FULL_RES=1 to leave out the 24 MP pass.
#
# Usage: Scripts/bench-contour.sh [macos|ios|all]   (default: all)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$ROOT/RetouchPro.xcworkspace"
SCHEME="RetouchPro"
# Plan §0.2: iPadOS deployment was removed entirely, iOS means iPhone. Same default as Scripts/test.sh.
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
        -only-testing:RPEngineTests/ContourBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P6CONTOUR-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P6CONTOUR-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P6CONTOUR ' "$log" | sed 's/^RPBENCH-P6CONTOUR //' >"$outfile"; then
        echo "no RPBENCH-P6CONTOUR line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p6-contour-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p6-contour-ios-simulator.json"
fi
