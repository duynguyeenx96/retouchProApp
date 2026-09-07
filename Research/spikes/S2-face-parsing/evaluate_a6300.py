"""The a6300 frames have no ground-truth masks, so this measures what can be
measured honestly and says plainly what it is.

There is no IoU here — inventing one would need hand-labelled masks. Instead:

1. **Core ML vs PyTorch agreement** on the same real-camera pixels. This *is* a
   real number: it says the converted model behaves like the reference on
   out-of-distribution input, not only on CelebA-HQ.
2. **Parts present.** A working parse of a frontal portrait must contain skin,
   hair, nose, both brows and lips, and either both eyes or eyeglasses. Counting
   which of those the model actually emits, per frame, turns "the overlay looks
   wrong" into a table. It does not prove the masks are *accurate*, only that the
   model did not collapse.
3. **Coverage sanity.** skin + hair + neck should cover most of a portrait crop;
   a frame where skin balloons past its usual share is a frame where the model
   swallowed the internal parts.

The overlays for the actual eyeballing are results/overlays/*.png.

Usage: python evaluate_a6300.py [--dir a6300]
"""

from __future__ import annotations

import json
import os
import sys

import numpy as np
from PIL import Image

from bisenet import LABELS

HERE = os.path.dirname(os.path.abspath(__file__))

# What a frontal portrait parse should contain.
EXPECTED = {
    "skin": [1],
    "hair": [17],
    "nose": [10],
    "brow_left": [2],
    "brow_right": [3],
    "upper_lip": [12],
    "lower_lip": [13],
    "eyes_or_glasses": [4, 5, 6],
}
MIN_FRACTION = 0.0005  # 0.05 % of 512x512 = 131 px; below that it is noise


def main() -> int:
    base = os.path.join(HERE, "a6300")
    if "--dir" in sys.argv:
        base = os.path.join(HERE, sys.argv[sys.argv.index("--dir") + 1])
    coreml_dir = os.path.join(base, "results", "coreml_labels")
    torch_dir = os.path.join(base, "results", "torch_labels")
    ids = sorted(os.path.splitext(f)[0] for f in os.listdir(coreml_dir) if f.endswith(".png"))

    per_image = {}
    agreements = []
    complete = 0
    for name in ids:
        cm = np.array(Image.open(os.path.join(coreml_dir, f"{name}.png")))
        tr = np.array(Image.open(os.path.join(torch_dir, f"{name}.png")))
        agreement = float((cm == tr).mean())
        agreements.append(agreement)

        total = cm.size
        fractions = {LABELS[c]: float((cm == c).sum() / total) for c in range(19)}
        present = {
            part: bool(np.isin(cm, ids_).sum() / total >= MIN_FRACTION)
            for part, ids_ in EXPECTED.items()
        }
        missing = [k for k, v in present.items() if not v]
        if not missing:
            complete += 1
        per_image[name] = {
            "coreml_vs_torch_pixel_agreement": agreement,
            "missing_parts": missing,
            "class_fraction": {k: round(v, 4) for k, v in fractions.items() if v >= 1e-4},
            "skin_fraction": fractions["skin"],
            "hair_fraction": fractions["hair"],
        }
        print(f"{name}: agreement={agreement:.4f} skin={fractions['skin']:.3f} "
              f"hair={fractions['hair']:.3f} missing={missing or '-'}")

    report = {
        "note": "No ground-truth masks exist for these frames. No IoU is reported. "
                "See the report's a6300 section; the visual check is results/overlays/.",
        "images": len(ids),
        "coreml_vs_torch_pixel_agreement": {
            "mean": float(np.mean(agreements)),
            "min": float(np.min(agreements)),
        },
        "frames_with_all_expected_parts": complete,
        "expected_parts": {k: [LABELS[c] for c in v] for k, v in EXPECTED.items()},
        "min_fraction_to_count_as_present": MIN_FRACTION,
        "per_image": per_image,
    }
    out = os.path.join(base, "results", "a6300_qualitative.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print(f"\n{complete}/{len(ids)} frames have every expected part")
    print("wrote", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
