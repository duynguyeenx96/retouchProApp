#!/bin/bash
# Runs the Phase 6 §6.1 "Khoá nền" (background lock) benchmark on a destination
# and files the result under Research/bench/.
#
# The benchmark is an ordinary test in RPVisionTests
# (PersonSegmentationBenchTests); it prints one line starting with
# "RPBENCH-P6BGLOCK " containing the JSON. This script scrapes that line, so the
# number in Research/bench/ is always the number the test actually measured —
# same arrangement as Scripts/bench-s1.sh … bench-color.sh.
#
# What it measures: VNGeneratePersonSegmentationRequest at .fast / .balanced /
# .accurate, on real a6300 frames, at a 2048 px preview and on the full 24 MP
# frame, plus where the mask lands (mean coverage inside a face box found by a
# *separate* Vision request, against the frame's corners). The timing alone is
# not enough to pick a quality level: .fast returns a 256x192 mask for a 2048 px
# preview and covers ~0.90 of a face box, while .balanced/.accurate are >0.99.
#
# -configuration Release, for the same reason as Scripts/bench-s2.sh: the mask
# unpack and the coverage sums are plain Swift loops over a few hundred thousand
# bytes and a Debug bundle is several times slower at them. The Vision request
# itself is framework code and does not care, but the scraped JSON should not mix
# an optimised request with an unoptimised readout.
#
# Fixtures: Research/spikes/S3-guided-filter-mls/images/full (gitignored sips
# decodes of Research/data/*.ARW). Point elsewhere with RP_BGLOCK_IMAGES. With no
# fixtures the test prints RPBENCH-P6BGLOCK-SKIP and this script fails loudly
# rather than writing an empty file.
#
# **This produces a Mac number only.** No iPhone figure exists for this node,
# exactly as for every other node in this project (docs/ADR-0007 … ADR-0016) — and
# unlike those, the iOS Simulator cannot stand in either: it has no
# person-segmentation model and every `perform` fails with `com.apple.Vision 9
# "Could not create inference context"`. The Simulator run therefore still writes
# its file, but with `"supported": false` and the exact error instead of a
# millisecond figure, which is the finding, not a hole. `is_real_device` in the
# JSON says which machine produced it.
#
# Usage: Scripts/bench-background-lock.sh [macos|ios|all]   (default: all)

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
        -only-testing:RPVisionTests/PersonSegmentationBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P6BGLOCK-SKIP' "$log"; then
        echo "benchmark skipped itself:"
        grep '^RPBENCH-P6BGLOCK-SKIP' "$log"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P6BGLOCK ' "$log" | sed 's/^RPBENCH-P6BGLOCK //' >"$outfile"; then
        echo "no RPBENCH-P6BGLOCK line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p6-background-lock-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" \
        "$OUT_DIR/p6-background-lock-ios-simulator.json"
fi
