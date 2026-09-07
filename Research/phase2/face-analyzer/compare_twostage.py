#!/usr/bin/env python
"""
Phase 2: does the two-stage detector actually close spike S1's end-to-end gap?

S1 §4a measured the whole RPVision pipeline (Apple Vision box -> 478-point mesh) at
**1.399 px** mean error against the MediaPipe Python reference on the user's 11 real
a6300 frames, with a < 1 px bar, and showed no ROI scale fixes it. The prescribed
fix was a two-stage detector (Vision rough box -> face-centred crop -> BlazeFace ROI
-> mesh). This script measures whether it worked.

Three numbers per dataset, all against the same `results/mp_reference.json` S1 used:

  control   the S1 pipeline, recomputed here from results/swift_landmarks.json, so
            the control and the treatment are scored by identical code
  twostage  RPVision's FaceAnalyzer, from the harness's twostage.json
  roi       how far each pipeline's ROI is from MediaPipe's own ROI
            (side ratio, centre offset as a fraction of the ROI side, roll delta)

Errors are in crop pixels: image-pixel error * 256 / mediapipe_roi_side, i.e. "how
far off would this point be if the face were framed at 256x256" — the same
normalisation `compare_vs_mediapipe.py` uses, so the numbers are comparable with
S1's tables directly.

Usage:
    python3 compare_twostage.py <datasetDir> <label>
        <datasetDir>  a spike dataset with results/mp_reference.json + mp_rois.json
        <label>       the results/<label>/twostage.json the harness wrote

Stdlib + numpy only; run it with the S1 venv (`.venv/bin/python`).
"""
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SIDE = 256


def stats(errors):
    e = np.concatenate(errors)
    return {
        "n_images": len(errors),
        "n_points": int(e.size),
        "mean_px_at_256": float(e.mean()),
        "median_px_at_256": float(np.median(e)),
        "p95_px_at_256": float(np.percentile(e, 95)),
        "max_px_at_256": float(e.max()),
        "worst_image_mean_px_at_256": float(max(x.mean() for x in errors)),
    }


def same_face(pts, gt, roi_side):
    """Multi-face guard, copied from compare_vs_mediapipe.py so the two scripts
    exclude the same frames."""
    return np.linalg.norm(pts.mean(axis=0) - gt.mean(axis=0)) < 0.5 * roi_side


def score(records, ref, rois, key="image_points"):
    errs, excluded, per_image = [], [], {}
    for rec in records:
        name = rec["image"]
        if name not in ref or name not in rois:
            continue
        pts = np.array(rec[key], dtype=np.float64).reshape(-1, 2)
        gt = np.array(ref[name]["points"])[:, :2]
        if not same_face(pts, gt, rois[name]["side"]):
            excluded.append({"image": name, "why": "different face from MediaPipe's"})
            continue
        d = np.linalg.norm(pts - gt, axis=1) * SIDE / rois[name]["side"]
        errs.append(d)
        per_image[name] = float(d.mean())
    return stats(errs), excluded, per_image


def roi_delta(records, rois):
    """How different is this pipeline's ROI from MediaPipe's own?"""
    ratios, offsets, rolls = [], [], []
    for rec in records:
        name = rec["image"]
        if name not in rois:
            continue
        mp = rois[name]
        ours = rec["crop"]
        ratios.append(mp["side"] / ours["side"])
        d = math.hypot(ours["center_x"] - mp["center_x"], ours["center_y"] - mp["center_y"])
        offsets.append(d / mp["side"])
        delta = ours["rotation"] - mp["rotation"]
        delta = delta - 2 * math.pi * math.floor((delta + math.pi) / (2 * math.pi))
        rolls.append(abs(math.degrees(delta)))
    return {
        "n": len(ratios),
        "mp_side_over_ours_mean": float(np.mean(ratios)),
        "mp_side_over_ours_std": float(np.std(ratios)),
        "centre_offset_frac_of_side_mean": float(np.mean(offsets)),
        "roll_abs_deg_mean": float(np.mean(rolls)),
        "roll_abs_deg_max": float(np.max(rolls)),
    }


def main():
    dataset = os.path.abspath(sys.argv[1])
    label = sys.argv[2]
    results = os.path.join(dataset, "results")
    ref = json.load(open(os.path.join(results, "mp_reference.json")))
    rois = json.load(open(os.path.join(results, "mp_rois.json")))

    two = json.load(open(os.path.join(HERE, "results", label, "twostage.json")))
    report = {
        "dataset": os.path.basename(dataset),
        "label": label,
        "blazeface_model": two.get("blazeface_model"),
        "summary": {},
        "per_image": {},
        "excluded": {},
    }

    s, excluded, per_image = score(two["records"], ref, rois)
    report["summary"]["twostage_vs_mediapipe"] = s
    report["excluded"]["twostage"] = excluded
    report["per_image"]["twostage"] = per_image
    report["summary"]["twostage_roi_vs_mediapipe_roi"] = roi_delta(two["records"], rois)

    control_path = os.path.join(results, "swift_landmarks.json")
    if os.path.exists(control_path):
        control = json.load(open(control_path))["records"]
        s, excluded, per_image = score(control, ref, rois)
        report["summary"]["control_s1_vision_pipeline_vs_mediapipe"] = s
        report["excluded"]["control"] = excluded
        report["per_image"]["control"] = per_image
        report["summary"]["control_roi_vs_mediapipe_roi"] = roi_delta(control, rois)

    if "parsing" in (two["records"][0] if two["records"] else {}):
        present = [r["parsing"]["parts_present"] for r in two["records"]]
        report["summary"]["parsing_parts_present"] = {
            "n": len(present),
            "ok": int(sum(present)),
            "failed": [r["image"] for r in two["records"] if not r["parsing"]["parts_present"]],
            "skin_fraction_mean": float(
                np.mean([r["parsing"]["skin_fraction"] for r in two["records"]])),
        }

    report["note"] = (
        "Same reference, same normalisation and the same multi-face guard as spike "
        "S1's compare_vs_mediapipe.py, so 'twostage' is directly comparable with that "
        "report's row B. The control is S1's own recorded run rescored here rather "
        "than quoted, so both sides of the comparison come out of one execution of "
        "one piece of code."
    )
    out = os.path.join(HERE, "results", label, "twostage_vs_mediapipe.json")
    json.dump(report, open(out, "w"), indent=1)
    print(json.dumps(report["summary"], indent=1))
    print("wrote", out)


if __name__ == "__main__":
    main()
