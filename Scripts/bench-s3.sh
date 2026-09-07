#!/bin/bash
# Runs the RPEngine spike-S3 benchmark (guided filter + MLS mesh warp) on a
# destination and files the result under Research/bench/.
#
# The benchmark is an ordinary test in RPEngineTests; it prints one line starting
# with "RPBENCH-S3 " containing the JSON. This script scrapes that line, so the
# number in Research/bench/ is always the number the test actually measured.
#
# Same three flags as Scripts/bench-s2.sh, for the same reasons:
#   -only-testing:.../SpikeS3BenchTests       run just this suite
#   -parallel-testing-enabled NO              do not contend for the GPU
#   -configuration Release                    build the test bundle optimised
# The last one matters here too, though less than for S2: the per-frame work is
# on the GPU, but the CGImage -> float32 -> float16 upload of a 24 MP frame is
# plain Swift/vImage and is several times slower in a Debug bundle.
#
# The benchmark needs the spike fixtures, which are gitignored because they are
# 190 MB of decoded camera frames:
#   Research/spikes/S3-guided-filter-mls/images/full/*.jpg   (sips, see the report §8)
#   Research/spikes/S3-guided-filter-mls/control/*.json      (s3harness controlpoints)
# Without them the test prints RPBENCH-S3-SKIP and passes; this script then fails
# loudly rather than filing a stale file.
#
# Usage: Scripts/bench-s3.sh [macos|ios|all]   (default: all)

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
        -only-testing:RPEngineTests/SpikeS3BenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-S3-SKIP' "$log"; then
        echo "benchmark skipped: $(grep -m1 '^RPBENCH-S3-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-S3 ' "$log" | sed 's/^RPBENCH-S3 //' >"$outfile"; then
        echo "no RPBENCH-S3 line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/s3-guided-mls-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" \
        "$OUT_DIR/s3-guided-mls-ios-simulator.json"
fi
