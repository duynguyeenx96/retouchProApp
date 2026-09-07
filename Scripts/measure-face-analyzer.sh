#!/bin/bash
# Reproduces every number Phase 2's FaceAnalyzer claims.
#
# Unlike Scripts/bench-s1.sh / bench-s2.sh, which scrape an RPBENCH line out of a
# test bundle, this drives the harness in Research/phase2/face-analyzer: the
# accuracy question ("does the two-stage detector reach the < 1 px bar") needs the
# 31 reference images and the MediaPipe Python reference, neither of which belongs
# in a test bundle.
#
# Prerequisites, all produced by Phase 0:
#   Research/spikes/S1-landmark/models/{FaceLandmark478,BlazeFaceShortRange}.mlpackage
#   Research/spikes/S2-face-parsing/models/FaceParsing19.mlpackage
#   Research/spikes/S1-landmark/{,a6300/}{images/raw,results/mp_reference.json,results/mp_rois.json}
# If BlazeFaceShortRange.mlpackage is missing:
#   cd Research/spikes/S1-landmark && .venv/bin/python convert_blazeface_to_coreml.py
#
# Usage: Scripts/measure-face-analyzer.sh [accuracy|bench|sweep|all]   (default: all)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/Research/phase2/face-analyzer"
PY="$ROOT/Research/spikes/S1-landmark/.venv/bin/python"
STOCK="$ROOT/Research/spikes/S1-landmark"
A6300="$ROOT/Research/spikes/S1-landmark/a6300"
WHICH="${1:-all}"

run() { (cd "$H/SwiftHarness" && swift run -c release p2harness "$@"); }

if [[ "$WHICH" == "accuracy" || "$WHICH" == "all" ]]; then
    run run "$STOCK" stock
    run run "$A6300" a6300
    # fp16 vs fp32 detector control. The fp32 build must be the *image-input* one:
    # RPVision hands the model a CVPixelBuffer, so the MultiArray builds cannot be
    # substituted here.
    P2_PARSING=0 \
        P2_BLAZEFACE_MODEL="$STOCK/models/BlazeFaceShortRange_fp32_image.mlpackage" \
        run run "$STOCK" fp32_stock
    P2_PARSING=0 \
        P2_BLAZEFACE_MODEL="$STOCK/models/BlazeFaceShortRange_fp32_image.mlpackage" \
        run run "$A6300" fp32_a6300
fi

if [[ "$WHICH" == "sweep" || "$WHICH" == "all" ]]; then
    # Stage-2 crop scale: how much of the frame BlazeFace sees decides how good its
    # eye keypoints, and therefore the ROI roll, are.
    for s in 1.5 2.0 2.5 3.0 3.5 4.0; do
        P2_PARSING=0 P2_DETECTOR_SCALE="$s" run run "$STOCK" "sweep_stock_ds$s"
        P2_PARSING=0 P2_DETECTOR_SCALE="$s" run run "$A6300" "sweep_a6300_ds$s"
    done
fi

if [[ "$WHICH" == "accuracy" || "$WHICH" == "sweep" || "$WHICH" == "all" ]]; then
    "$PY" "$H/compare_twostage.py" "$STOCK" stock
    "$PY" "$H/compare_twostage.py" "$A6300" a6300
    "$PY" "$H/summarise.py"
fi

if [[ "$WHICH" == "bench" || "$WHICH" == "all" ]]; then
    run bench "$A6300"
    run cache "$A6300"
fi

echo "results: $H/results/summary.json"
echo "bench:   $ROOT/Research/bench/p2-face-analyzer-macos.json"
echo "         $ROOT/Research/bench/p2-face-analyzer-cache-macos.json"
