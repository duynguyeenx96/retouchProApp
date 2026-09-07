#!/usr/bin/env python
"""
Test for convert_tflite_to_coreml.check_variant_ordering.

Why this exists: `ct.convert` **mutates** the MIL program it is handed — an
ImageType input prepends the 1/255 scale ops to the graph — and
convert_tflite_to_coreml.main() builds `prog` once and converts it three times.
The guard is the only thing stopping a future edit from double-normalising the
model, and a double-normalised model does not fail to convert or look wrong in
the spec: convert_blazeface_to_coreml.py shipped exactly that bug and the
detector simply found no face in any of the 31 test frames.

So the guard is real load-bearing logic and gets a test rather than a manual
trace. The three cases are the shipping shape and the two ways to break it.

Run (needs the spike venv for coremltools, which the module imports at import
time; nothing here touches a .tflite file, a model or the GPU):

    Research/spikes/S1-landmark/.venv/bin/python \
        Research/spikes/S1-landmark/test_convert_invariant.py

Exit code 0 = pass. Prints one line per case.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from convert_tflite_to_coreml import check_variant_ordering

# The precision field is never read by the guard, so a placeholder keeps the
# test independent of coremltools' enum.
FP32, FP16 = "fp32", "fp16"

CASES = [
    # (name, variants, should_pass)
    (
        "shipping shape: two array variants then one image variant last",
        [
            (FP32, "FaceLandmark478_fp32", None),
            (FP16, "FaceLandmark478_fp16", None),
            (FP16, "FaceLandmark478", "image"),
        ],
        True,
    ),
    (
        "no image variant at all (nothing to double-normalise)",
        [
            (FP32, "FaceLandmark478_fp32", None),
            (FP16, "FaceLandmark478_fp16", None),
        ],
        True,
    ),
    (
        "single image variant, alone",
        [(FP16, "FaceLandmark478", "image")],
        True,
    ),
    (
        "BAD: image variant is not last — the array variant after it converts a "
        "prog that already has the scale ops",
        [
            (FP32, "FaceLandmark478_fp32", None),
            (FP16, "FaceLandmark478", "image"),
            (FP16, "FaceLandmark478_fp16", None),
        ],
        False,
    ),
    (
        "BAD: two image variants — the second scales 1/255 twice",
        [
            (FP32, "FaceLandmark478_fp32", None),
            (FP16, "FaceLandmark478_a", "image"),
            (FP16, "FaceLandmark478_b", "image"),
        ],
        False,
    ),
    (
        "BAD: two image variants, adjacent at the end (the tempting 'but it is "
        "still last' shape)",
        [
            (FP32, "FaceLandmark478_fp32", None),
            (FP16, "FaceLandmark478_a", "image"),
            (FP16, "FaceLandmark478", "image"),
        ],
        False,
    ),
]


def main():
    failures = 0
    for name, variants, should_pass in CASES:
        try:
            check_variant_ordering(variants)
            accepted = True
            message = ""
        except AssertionError as error:
            accepted = False
            message = str(error)
        ok = accepted == should_pass
        failures += 0 if ok else 1
        print(
            "%s  %-6s %s%s"
            % (
                "PASS" if ok else "FAIL",
                "accept" if accepted else "reject",
                name,
                "" if accepted else "  [%s]" % message,
            )
        )

    print("%d/%d cases behaved as specified" % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
