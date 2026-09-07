"""IoU against CelebAMask-HQ ground truth — the plan's S2 pass bar.

docs/PLAN.md §3: "IoU skin/hair/eye >= 0.85 on 10 images". This scores every
available prediction directory against images/gt/ and reports:

  * the headline: mean IoU for the skin / hair / eye groups over the first 10
    images of the set (plan's bar), and over all N as supporting evidence;
  * per-class IoU for all 19 classes, so a class-index mistake cannot hide behind
    a good skin number;
  * a **mapping check**: for each predicted class, the ground-truth class it
    overlaps most. If the index->label table were wrong, predicted `hair` would
    match some other GT class and this would say so. Written to
    results/iou.json as `mapping_check`.

Prediction directories scored when present:
  results/torch_labels           PyTorch on PIL-resized input  (control)
  results/coreml_labels          Core ML via Swift, same pixels as the control
  results/coreml_labels_fromraw  Core ML via Swift, its own Core Image resize

Usage: python evaluate_iou.py [--dir a6300]
"""

from __future__ import annotations

import json
import os
import sys

import numpy as np
from PIL import Image

from bisenet import GROUPS, LABELS

HERE = os.path.dirname(os.path.abspath(__file__))
PLAN_BAR = 0.85
PLAN_N = 10

PRED_DIRS = ["torch_labels", "coreml_labels", "coreml_labels_fromraw"]


def load(path: str) -> np.ndarray:
    return np.array(Image.open(path).convert("L"), dtype=np.uint8)


def iou(a_mask: np.ndarray, b_mask: np.ndarray) -> float | None:
    union = np.logical_or(a_mask, b_mask).sum()
    if union == 0:
        return None
    return float(np.logical_and(a_mask, b_mask).sum() / union)


def summarise(values: list[float | None]) -> dict | None:
    kept = [v for v in values if v is not None]
    if not kept:
        return None
    arr = np.array(kept)
    return {
        "mean": float(arr.mean()),
        "min": float(arr.min()),
        "max": float(arr.max()),
        "images_scored": len(kept),
    }


def main() -> int:
    base = HERE
    if "--dir" in sys.argv:
        base = os.path.join(HERE, sys.argv[sys.argv.index("--dir") + 1])
    gt_dir = os.path.join(base, "images", "gt")
    results = os.path.join(base, "results")

    manifest_path = os.path.join(base, "images", "manifest_celebamaskhq.json")
    order = None
    if os.path.exists(manifest_path):
        order = [str(i["celeba_hq_index"]) for i in json.load(open(manifest_path))["images"]]
    ids = order or sorted(os.path.splitext(f)[0] for f in os.listdir(gt_dir))

    report = {
        "ground_truth": "images/gt (CelebAMask-HQ per-part annotations merged with "
                        "vendor/prepropess_data.py's rule)",
        "plan_bar": {"metric": "mean IoU skin/hair/eye", "threshold": PLAN_BAR,
                     "images": PLAN_N},
        "image_order": ids,
        "predictions": {},
    }

    for pred_name in PRED_DIRS:
        pred_dir = os.path.join(results, pred_name)
        if not os.path.isdir(pred_dir):
            continue
        per_image: dict[str, dict] = {}
        group_values = {g: [] for g in GROUPS}
        class_values = {c: [] for c in range(19)}
        # 19x19 running IoU, predicted class (row) vs ground-truth class (col).
        cross_inter = np.zeros((19, 19), dtype=np.int64)
        cross_union = np.zeros((19, 19), dtype=np.int64)

        for name in ids:
            pred_path = os.path.join(pred_dir, f"{name}.png")
            if not os.path.exists(pred_path):
                continue
            pred = load(pred_path)
            gt = load(os.path.join(gt_dir, f"{name}.png"))
            assert pred.shape == gt.shape, (pred.shape, gt.shape)

            entry = {}
            for g, ids_ in GROUPS.items():
                v = iou(np.isin(pred, ids_), np.isin(gt, ids_))
                group_values[g].append(v)
                entry[g] = v
            for c in range(19):
                v = iou(pred == c, gt == c)
                class_values[c].append(v)
            per_image[name] = entry

            pm = np.stack([pred == c for c in range(19)])
            gm = np.stack([gt == c for c in range(19)])
            counts_p = pm.reshape(19, -1).astype(np.int64)
            counts_g = gm.reshape(19, -1).astype(np.int64)
            inter = counts_p @ counts_g.T
            sizes_p = counts_p.sum(1)[:, None]
            sizes_g = counts_g.sum(1)[None, :]
            cross_inter += inter
            cross_union += sizes_p + sizes_g - inter

        n = len(per_image)
        first = {g: v[:PLAN_N] for g, v in group_values.items()}
        with np.errstate(divide="ignore", invalid="ignore"):
            cross = np.where(cross_union > 0, cross_inter / np.maximum(cross_union, 1), 0.0)
        mapping_check = {}
        for c in range(19):
            if cross[c].sum() == 0:
                continue
            best = int(np.argmax(cross[c]))
            mapping_check[LABELS[c]] = {
                "best_matching_gt_class": LABELS[best],
                "iou": float(cross[c][best]),
                "self_iou": float(cross[c][c]),
                "consistent": best == c,
            }

        report["predictions"][pred_name] = {
            "images": n,
            f"groups_first_{PLAN_N}": {g: summarise(v) for g, v in first.items()},
            f"pass_first_{PLAN_N}": {
                g: (summarise(v) or {"mean": 0})["mean"] >= PLAN_BAR for g, v in first.items()
            },
            "groups_all": {g: summarise(v) for g, v in group_values.items()},
            "per_class": {
                LABELS[c]: summarise(v) for c, v in class_values.items() if summarise(v)
            },
            "mapping_check": mapping_check,
            "per_image": per_image,
        }

        head = report["predictions"][pred_name][f"groups_first_{PLAN_N}"]
        allg = report["predictions"][pred_name]["groups_all"]
        print(f"\n== {pred_name} ({n} images) ==")
        for g in GROUPS:
            h = head[g]["mean"] if head[g] else float("nan")
            a = allg[g]["mean"] if allg[g] else float("nan")
            print(f"  {g:6s} first{PLAN_N}={h:.4f}  all{n}={a:.4f}  "
                  f"{'PASS' if h >= PLAN_BAR else 'FAIL'}")
        bad = [k for k, v in mapping_check.items() if not v["consistent"]]
        print(f"  mapping check: {'all consistent' if not bad else 'INCONSISTENT: ' + str(bad)}")

    out = os.path.join(results, "iou.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print("\nwrote", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
