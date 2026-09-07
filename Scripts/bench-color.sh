#!/bin/bash
# Runs the Phase 2 "Color" slider measurement and files the result under
# Research/bench/.
#
# The measurement is an ordinary test in RPEngineTests (ColorBenchTests); it
# prints one line starting with "RPBENCH-P2COLOR " containing the JSON, and this
# script scrapes that line — so the number filed under Research/ is always the
# number the test actually measured (docs/PLAN.md §5, "measure before ship").
#
# The JSON carries four claims, which are deliberately separate:
#   golden.*      PSNR against ColorReference, the Double CPU control. Says the
#                 GPU computes the documented formula. Runs anywhere.
#   behaviour.*   mean signed luminance change on each end of the ramp, and mean
#                 |Δ| per labelled region of the chart. Says Highlights acts on
#                 the highlights, Shadows on the shadows, an HSL band on its own
#                 hue, and Auto D&B on the blobs rather than on the ramp — the
#                 thing a PSNR cannot say, because a slider computing the
#                 documented formula on the wrong pixels scores just as well.
#                 Runs anywhere.
#   speed.*       ms/frame at a 2048 px preview and at 24 MP, on the real a6300
#                 frame spike S3 already uses. Needs the gitignored fixtures:
#                   Research/spikes/S3-guided-filter-mls/images/full/*.jpg
#                 Without them the JSON has "speed_skipped" instead and this
#                 script still writes the file — the accuracy half is the part
#                 that gates the plan's 45 dB bar.
#   speed.*.core_image_control
#                 the same two frames through a CIFilter chain
#                 (CIExposureAdjust + CITemperatureAndTint +
#                 CIHighlightShadowAdjust + CIColorControls + CIVibrance +
#                 CIToneCurve). This is the **control** for docs/ADR-0012's
#                 "Metal, not Core Image" decision, which docs/PLAN.md §1.3's
#                 "Core Image + kernel" row made a decision worth measuring. It
#                 covers 9 of the group's 18 sliders (contrast+saturation share
#                 one CIColorControls call, temperature+tint share one
#                 CITemperatureAndTint call) — there is no CIFilter for
#                 per-hue-band HSL or for the two-scale Auto D&B — so it is a
#                 LOWER BOUND on what a CIFilter implementation would cost.
#
# None of them says the result is *pretty*. Nobody has looked at a render; every
# constant is argued from what the operation physically is and is untuned
# (ColorRenderNode's "known limitations", docs/ADR-0012).
#
# Same three flags as the other bench scripts, for the same reasons:
#   -only-testing:...              run just this suite
#   -parallel-testing-enabled NO   do not contend for the GPU
#   -configuration Release         the CGImage -> float32 -> float16 upload of a
#                                  24 MP frame is plain Swift/vImage and is
#                                  several times slower in a Debug bundle
#
# Set RP_SKIP_FULL_RES=1 to leave out the 24 MP pass.
#
# Usage: Scripts/bench-color.sh [macos|ios|all]   (default: all)

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
        -only-testing:RPEngineTests/ColorBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P2COLOR-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P2COLOR-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P2COLOR ' "$log" | sed 's/^RPBENCH-P2COLOR //' >"$outfile"; then
        echo "no RPBENCH-P2COLOR line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p2-color-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p2-color-ios-simulator.json"
fi
