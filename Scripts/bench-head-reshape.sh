#!/bin/bash
# Runs the Phase 6.2 §6.2 "Đầu" (head reshape) measurement and files the result
# under Research/bench/.
#
# The measurement is an ordinary test in RPEngineTests (HeadReshapeBenchTests);
# it prints one line starting with "RPBENCH-P6HEAD " containing the JSON, and
# this script scrapes that line — so the number filed under Research/ is always
# the number the test actually measured (docs/PLAN.md §5, "measure before ship").
# Same arrangement as Scripts/bench-warp.sh … bench-skin-sync.sh.
#
# The JSON carries seven claims, deliberately separate, because this group adds
# a new **mask consumer** and a new set of control points to a warp that is
# already measured (docs/ADR-0010):
#   reference.*  the Swift hair trace against an independent NumPy
#                implementation (Research/bench/hair-boundary-reference.py:
#                largest 4-connected component by label propagation, boundary as
#                per-row/column extremes). Exact agreement, or the number says by
#                how much it missed. Regenerate the reference with
#                  python3 Research/bench/hair-boundary-reference.py
#   alignment.*  the hair mask against the 478-point mesh, as the IoU of the
#                face-oval polygon with the parser's own facial classes, for both
#                signs of spike S2's derotation. This is the one free parameter
#                in putting a real mask and a real mesh in one frame, so it is
#                measured rather than asserted in a comment.
#   trace.*      cost and shape of the trace on the 11 real a6300 hair masks —
#                including how often the parsing crop cuts the silhouette, which
#                is this group's main real-world limitation.
#   handles.*    control points by role (mesh / expanded ring / hair boundary)
#                and how many are dropped as clipped or as crowding a mesh
#                handle. Per frame, not just aggregated.
#   accuracy.*   the lattice round-trip at the head handles, preview and export.
#                This group's displacements are ~10x the "Mặt" group's, so the
#                same 65/129 lattice carries proportionally more interpolation
#                error — see docs/ADR-0022.
#   golden.*     PSNR against WarpReference, the Double CPU rasteriser, on a real
#                a6300 frame with its real hair mask. Bar: the plan's 45 dB.
#   speed.*      ms/frame at a 2048 px preview and at 24 MP with the head group
#                off and on, so its MARGINAL cost over the "Mặt" group is visible,
#                plus the CPU cost of the trace + handle build (the part that
#                runs before anything is encoded).
#
# Needs the gitignored fixtures for everything except `reference.synthetic`:
#   Research/spikes/S2-face-parsing/a6300_upright/results/coreml_labels/*.png
#   Research/phase2/face-analyzer/results/a6300/twostage.json
#   Research/spikes/S1-landmark/a6300/images/raw/*.jpg
#   Research/spikes/S3-guided-filter-mls/images/full/*.jpg   (the 24 MP half)
# Without them the JSON carries "*_skipped" keys instead and this script still
# writes the file.
#
# None of it says the result is *pretty*, and none of it says the hair mask is
# *correct*: there is still no hand-drawn hairline ground truth on these frames,
# which the JSON states as "ground_truth_hairline": false. Every magnitude in
# HeadReshape is untuned ("constants_are_tuned": false), the same disclosure
# docs/ADR-0010 … ADR-0021 make for their groups.
#
# **Mac / iOS-Simulator numbers only**, as for every other node in this project;
# `is_real_device` in the JSON says which machine produced it.
#
# Same three flags as the other bench scripts, for the same reasons:
#   -only-testing:...              run just this suite
#   -parallel-testing-enabled NO   do not contend for the GPU
#   -configuration Release         the trace, the component labelling and the
#                                  handle build are plain Swift over a 512² mask
#                                  and are several times slower in a Debug bundle
#
# Set RP_SKIP_FULL_RES=1 to leave out the 24 MP pass.
#
# Usage: Scripts/bench-head-reshape.sh [macos|ios|all]   (default: all)

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
        -only-testing:RPEngineTests/HeadReshapeBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P6HEAD-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P6HEAD-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P6HEAD ' "$log" | sed 's/^RPBENCH-P6HEAD //' >"$outfile"; then
        echo "no RPBENCH-P6HEAD line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p6-head-reshape-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p6-head-reshape-ios-simulator.json"
fi
