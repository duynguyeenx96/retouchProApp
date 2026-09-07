#!/bin/bash
# Runs the Phase 2 live-preview (MTKView canvas) measurement and files the result
# under Research/bench/.
#
# The measurement is an ordinary test in RPEngineTests (LivePreviewBenchTests);
# it prints one line starting with "RPBENCH-P2LIVE " containing the JSON, and
# this script scrapes that line — so the number filed under Research/ is always
# the number the test actually measured (docs/PLAN.md §5, "measure before ship").
#
# What the JSON claims, and what it does not:
#   redraw[]        ms per canvas redraw at a 2048 px preview, per slider group
#                   and for all four together. This is the interaction path: the
#                   whole cost of moving a slider once the shot is open.
#   present         ms for the placement/resample pass alone (zoom, pan, resize).
#                   No node runs for those — the graph's output texture is kept.
#   drag_60_frames  60 back-to-back redraws with a changing slider value, i.e. a
#                   real drag. `decodes`/`uploads`/`face_analyses` are 0 by
#                   construction: the loop calls neither. The UI-side proof that
#                   the app does the same is
#                   RPUITests/LivePreviewWiringTests.analysisRunsOncePerShot.
#   per_shot        decode + upload + graph prewarm — the costs that must stay
#                   OFF the slider path, recorded so "once per shot" is a number
#                   and not a claim.
#
# None of them says the picture is *good*. The correctness claim for this item is
# RPEngineTests/LivePreviewRendererTests: the wired preview is bit-identical
# (max abs difference 0) to calling RenderGraph directly with the same request.
#
# Needs the gitignored fixtures — a real a6300 frame and the 478-point mesh
# measured on it:
#   Research/spikes/S3-guided-filter-mls/images/full/DSC05123.jpg
#   Research/phase2/face-analyzer/results/ (via FaceLandmarkFixtures)
# Without them the JSON carries "skipped" and this script still writes the file.
#
# Same three flags as the other bench scripts, for the same reasons:
#   -only-testing:...              run just this suite
#   -parallel-testing-enabled NO   do not contend for the GPU
#   -configuration Release         the CGImage -> float32 -> float16 upload is
#                                  plain Swift/vImage and is several times slower
#                                  in a Debug bundle
#
# Usage: Scripts/bench-live-preview.sh [macos|ios|all]   (default: all)

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
        -only-testing:RPEngineTests/LivePreviewBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P2LIVE-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P2LIVE-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P2LIVE ' "$log" | sed 's/^RPBENCH-P2LIVE //' >"$outfile"; then
        echo "no RPBENCH-P2LIVE line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p2-live-preview-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p2-live-preview-ios-simulator.json"
fi
