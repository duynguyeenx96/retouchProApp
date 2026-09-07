"""Why does the eye group miss the bar, and can framing fix it?

Whole-frame parsing at 512 puts an eye at ~1 400 px (0.5 % of the image, and as
few as 230 px on the worst frame in the set), so its IoU is dominated by a
one-pixel boundary error. Phase 2 will not feed the model whole frames — it
parses a face crop. This measures how much that is worth.

The crop here is an **oracle**: the square bounding box of the ground-truth face
classes, expanded by `--scale`. That makes the result an upper bound on what a
detector-driven crop can buy, not a promise. Sweeping the scale also shows how
sensitive the answer is to getting the box right, which is the thing that bit
spike S1 (docs/ADR-0005).

Predictions are mapped back onto the full 512 grid (nearest neighbour, background
outside the crop) and scored against the same ground truth as evaluate_iou.py, so
the numbers are directly comparable.

Usage: python experiment_facecrop.py [--scale 1.2,1.4,1.6,2.0]
"""

from __future__ import annotations

import json
import os
import sys

import coremltools as ct
import numpy as np
from PIL import Image

from bisenet import GROUPS, LABELS

HERE = os.path.dirname(os.path.abspath(__file__))
FACE_CLASSES = [1, 2, 3, 4, 5, 10, 11, 12, 13]  # skin, brows, eyes, nose, mouth, lips
SIDE = 512


def iou(a: np.ndarray, b: np.ndarray) -> float | None:
    union = np.logical_or(a, b).sum()
    return None if union == 0 else float(np.logical_and(a, b).sum() / union)


def square_box(mask: np.ndarray, scale: float, limit: int) -> tuple[int, int, int]:
    ys, xs = np.nonzero(mask)
    cx, cy = (xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2
    side = max(xs.max() - xs.min(), ys.max() - ys.min()) * scale
    side = min(side, limit)
    x0 = int(round(min(max(cx - side / 2, 0), limit - side)))
    y0 = int(round(min(max(cy - side / 2, 0), limit - side)))
    return x0, y0, int(round(side))


def main() -> int:
    scales = [1.2, 1.4, 1.6, 2.0]
    if "--scale" in sys.argv:
        scales = [float(s) for s in sys.argv[sys.argv.index("--scale") + 1].split(",")]

    model = ct.models.MLModel(os.path.join(HERE, "models", "FaceParsing19.mlpackage"))
    manifest = json.load(open(os.path.join(HERE, "images", "manifest_celebamaskhq.json")))
    ids = [str(i["celeba_hq_index"]) for i in manifest["images"]]

    report = {
        "note": "oracle face crop from ground-truth face classes, upper bound",
        "face_classes": [LABELS[c] for c in FACE_CLASSES],
        "baseline": "results/iou.json -> predictions.coreml_labels",
        "scales": {},
    }

    for scale in scales:
        values = {g: [] for g in GROUPS}
        for name in ids:
            gt = np.array(Image.open(os.path.join(HERE, "images", "gt", f"{name}.png")))
            src = Image.open(
                os.path.join(HERE, "images", "raw", f"{name}.jpg")).convert("RGB")
            face = np.isin(gt, FACE_CLASSES)
            if not face.any():
                continue
            # GT is 512; the source jpg is 1024. Box in GT space, crop in source space.
            x0, y0, side = square_box(face, scale, SIDE)
            ratio = src.width / SIDE
            crop = src.crop(
                (int(x0 * ratio), int(y0 * ratio),
                 int((x0 + side) * ratio), int((y0 + side) * ratio))
            ).resize((SIDE, SIDE), Image.BILINEAR)

            labels = np.asarray(model.predict({"image": crop})["labels"]).astype(np.uint8)
            labels = labels.reshape(SIDE, SIDE)
            back = np.array(
                Image.fromarray(labels, mode="L").resize((side, side), Image.NEAREST))
            full = np.zeros((SIDE, SIDE), dtype=np.uint8)
            full[y0:y0 + side, x0:x0 + side] = back

            for g, gids in GROUPS.items():
                v = iou(np.isin(full, gids), np.isin(gt, gids))
                if v is not None:
                    values[g].append(v)

        entry = {}
        for g, v in values.items():
            arr = np.array(v)
            entry[g] = {
                "mean_first10": float(arr[:10].mean()),
                "mean_all": float(arr.mean()),
                "min": float(arr.min()),
                "images": len(v),
            }
        report["scales"][f"{scale}"] = entry
        print(f"scale {scale}: " + "  ".join(
            f"{g}={entry[g]['mean_first10']:.4f}/{entry[g]['mean_all']:.4f}" for g in GROUPS))

    out = os.path.join(HERE, "results", "facecrop_sweep.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print("wrote", out, "(values are first10/all30)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
