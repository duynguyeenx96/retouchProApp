#!/bin/bash
# Runs the Phase 6 §6.1 "Cọ mask thủ công" measurement and files the result
# under Research/bench/.
#
# The measurement is an ordinary test in RPEngineTests (ManualMaskBenchTests);
# it prints one line starting with "RPBENCH-P6BRUSH " containing the JSON, and
# this script scrapes that line — so the number filed under Research/ is always
# the number the test actually measured (docs/PLAN.md §5, "measure before ship").
# Same arrangement as Scripts/bench-color.sh … Scripts/bench-contour.sh.
#
# Three claims, deliberately separate:
#   paint.*   main-thread ms per touch event. `beginStroke`/`extendStroke` run
#             in the touch handler, so this is what decides whether the brush is
#             attached to the finger. The GPU drain is measured after the drag,
#             not inside it, because the session deliberately does not wait.
#   render.*  SkinRenderNode ms/frame **with** the painted gate and **without**
#             it, same fixture, same run. The ungated pass is the control, and
#             `gate_marginal_ms` is the entire cost of gating: one
#             rp_manual_mask_modulate dispatch over an r8 texture.
#   undo.*    ms to replay a 20-stroke history. Undo is a replay rather than a
#             texture snapshot (docs/ADR-0019 §3) and that trade is only
#             defensible if a replay is cheap.
#
# **This script exists to close ADR-0019's own blocker**, which is the reason it
# takes a third destination the other bench scripts do not:
#
#   Scripts/bench-manual-mask.sh device <udid>
#
# ADR-0019 shipped the brush with the flag off and said *"a ms/frame on an
# A-series part is required before it is turned on"*. macOS and the Simulator
# both run on the host Mac's GPU, so neither can answer that; only a build on the
# phone can. Find the udid with `xcrun xctrace list devices`.
#
# Usage: Scripts/bench-manual-mask.sh [macos|ios|all|device <udid>]   (default: all)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$ROOT/RetouchPro.xcworkspace"
SCHEME="RetouchPro"
# Plan §0.2: iPadOS deployment was removed entirely, iOS means iPhone.
IOS_DESTINATION="${RP_IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
OUT_DIR="$ROOT/Research/bench"
WHICH="${1:-all}"

mkdir -p "$OUT_DIR"

capture() {
    local label="$1" destination="$2" outfile="$3"
    shift 3
    echo "=== bench $label ==="
    local log
    log="$(mktemp)"
    xcodebuild test -workspace "$WORKSPACE" -scheme "$SCHEME" \
        -destination "$destination" \
        -only-testing:RPEngineTests/ManualMaskBenchTests \
        -configuration Release ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE" \
        -parallel-testing-enabled NO "$@" >"$log" 2>&1 || {
        echo "xcodebuild failed; tail of log:"
        tail -40 "$log"
        rm -f "$log"
        return 1
    }
    if grep -q '^RPBENCH-P6BRUSH-SKIP' "$log"; then
        echo "measurement skipped: $(grep -m1 '^RPBENCH-P6BRUSH-SKIP' "$log")"
        rm -f "$log"
        return 1
    fi
    if ! grep -m1 '^RPBENCH-P6BRUSH ' "$log" | sed 's/^RPBENCH-P6BRUSH //' >"$outfile"; then
        echo "no RPBENCH-P6BRUSH line found in $log"
        return 1
    fi
    rm -f "$log"
    echo "wrote $outfile"
    cat "$outfile"
    echo
}

if [[ "$WHICH" == "macos" || "$WHICH" == "all" ]]; then
    capture "macOS" "platform=macOS" "$OUT_DIR/p6-manual-mask-macos.json"
fi

if [[ "$WHICH" == "ios" || "$WHICH" == "all" ]]; then
    capture "$IOS_DESTINATION" "$IOS_DESTINATION" "$OUT_DIR/p6-manual-mask-ios-simulator.json"
fi

if [[ "$WHICH" == "device" ]]; then
    UDID="${2:-}"
    if [[ -z "$UDID" ]]; then
        echo "usage: Scripts/bench-manual-mask.sh device <udid>   (xcrun xctrace list devices)" >&2
        exit 2
    fi
    # The test runner has to be signed for the phone. Everything else is the
    # same run as the two above, on the one machine whose GPU is the product's.
    #
    # RP_CODE_SIGN_ENTITLEMENTS works around the standing App Group provisioning
    # blocker: `App/RetouchPro.entitlements` asks for
    # `group.com.duynguyen.RetouchPro` (docs/ADR-0017, the Share Extension
    # handoff) and this machine's team provisioning profile does not carry it, so
    # a plain device build stops at
    #   "Provisioning profile … doesn't match the entitlements file's value for
    #    the com.apple.security.application-groups entitlement".
    # Pointing this at a copy of that file with the App Group removed produces a
    # build that cannot receive a share but can run every test — which is what a
    # GPU measurement needs. It changes no file in the repository.
    ENTITLEMENTS_ARG=()
    if [[ -n "${RP_CODE_SIGN_ENTITLEMENTS:-}" ]]; then
        ENTITLEMENTS_ARG=("CODE_SIGN_ENTITLEMENTS=$RP_CODE_SIGN_ENTITLEMENTS")
    fi
    capture "iPhone $UDID" "platform=iOS,id=$UDID" "$OUT_DIR/p6-manual-mask-device.json" \
        -allowProvisioningUpdates "${ENTITLEMENTS_ARG[@]}"
fi
