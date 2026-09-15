#!/bin/bash
# Runs the Phase 6 §6.2 "Sửa da" (đồng bộ da toàn thân) measurement and files the
# result under Research/bench/.
#
# The measurement is an ordinary test in RPEngineTests (SkinSyncBenchTests); it
# prints one line starting with "RPBENCH-P6SKINSYNC " containing the JSON, and
# this script scrapes that line — so the number filed under Research/ is always
# the number the test actually measured (docs/PLAN.md §5, "measure before ship").
# Same arrangement as Scripts/bench-color.sh … bench-contour.sh.
#
# READ THIS BEFORE READING THE JSON. docs/PLAN.md §6.2 asks for an IoU "trên bộ
# ảnh test nhiều tông da khác nhau". **That measurement does not exist yet.** The
# only labelled data the project can reach is panelpts/research/data, and it has
# no _gt.bmp: `node panelpts/research/eval.js` prints "4 ảnh, 0 có ground truth …
# CHƯA CÓ GROUND TRUTH". Someone has to paint ground-truth masks before a real
# photographic IoU can be quoted. That is why RPEngineFeatureFlags.bodySkinSync
# is default off and why the JSON carries "human_ground_truth_available": false.
#
# What the JSON does carry, all of it real:
#   port.*           SkinCore vs the SHIPPED skincore.js, byte for byte on the
#                    generated fixture. coverage_max_abs_diff must be 0 and
#                    probe_mismatches must be 0 — this is the "identical
#                    numerics" claim in .claude/agents/coder.md, as a number.
#                    Runs anywhere, needs no GPU.
#   accuracy.*       IoU / precision / recall against a CONSTRUCTED ground truth
#                    across a six-step skin-tone ladder, on two frames per tone:
#                    "clean" (detection) and "cluttered" (rejection of
#                    skin-coloured wood). Synthetic, and labelled as such.
#   union.*          What the whole-frame mask does inside SkinRenderNode: how
#                    much area it adds, that it never weakens the per-face mask,
#                    that the flag-off path is bit-exact, and that a §6.1 gate
#                    still narrows the *unioned* result (gated_bottom_half_px
#                    must be 0 — that is the widen-before-narrow ordering, as an
#                    assertion).
#   speed.*          The classifier is CPU and runs once per IMAGE, not per
#                    frame; the union is one extra r8 dispatch per frame. Both
#                    are reported separately because they are charged at
#                    different rates.
#   coverage_real.*  Coverage fraction on the real a6300 frames under
#                    Research/spikes/S3-guided-filter-mls/images/full (gitignored)
#                    — the same COVERAGE, not accuracy, number eval.js prints.
#                    Replaced by "coverage_real_skipped" when they are absent;
#                    the script still writes the file, because the port and union
#                    halves are the ones that gate anything.
#
# **Mac / iOS-Simulator numbers only**, as for every other node in this project;
# "is_real_device" in the JSON says which machine produced it.
#
# Same three flags as the other bench scripts, for the same reasons:
#   -only-testing:...              run just this suite
#   -parallel-testing-enabled NO   do not contend for the GPU
#   -configuration Release         the classifier is a plain Swift loop over every
#                                  pixel of a 24 MP frame and is several times
#                                  slower in a Debug bundle — a Debug number here
#                                  would be meaningless
#
# Usage: Scripts/bench-skin-sync.sh [macos|ios|all]   (default: all)

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
        -only-testing:RPEngineTests/SkinSyncBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P6SKINSYNC-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P6SKINSYNC-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P6SKINSYNC ' "$log" | sed 's/^RPBENCH-P6SKINSYNC //' >"$outfile"; then
        echo "no RPBENCH-P6SKINSYNC line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p6-skin-sync-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p6-skin-sync-ios-simulator.json"
fi
