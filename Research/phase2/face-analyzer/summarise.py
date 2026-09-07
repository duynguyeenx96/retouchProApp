#!/usr/bin/env python
"""
Rolls every run under results/ into one file, results/summary.json.

Sections:
  headline          the shipping configuration (fp16 detector, detectorRegionScale
                    3.5) vs the MediaPipe Python reference, per dataset and pooled
                    by point count
  control           spike S1's Vision-box pipeline, rescored by the same code
  detector_scale    the stage-2 crop-scale sweep, per dataset and pooled
  detector_precision  fp16 vs an fp32 image-input build of the same graph
  parsing           parts-present on the roll-normalised CelebA-framed crop

Pooling is by point count, not by averaging the two dataset means, because the
stock set has 9 560 points and the a6300 set 5 258 — the same convention spike S1
used in `a6300_roi_stats.py`.

Usage:  .venv/bin/python summarise.py     (S1's venv, for numpy)
"""
import importlib.util
import json
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "compare_twostage", os.path.join(HERE, "compare_twostage.py"))
ct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ct)

DATASETS = {
    "stock": os.path.join(HERE, "../../spikes/S1-landmark"),
    "a6300": os.path.join(HERE, "../../spikes/S1-landmark/a6300"),
}


def reference(dataset):
    results = os.path.join(DATASETS[dataset], "results")
    return (
        json.load(open(os.path.join(results, "mp_reference.json"))),
        json.load(open(os.path.join(results, "mp_rois.json"))),
    )


def load(label):
    path = os.path.join(HERE, "results", label, "twostage.json")
    return json.load(open(path)) if os.path.exists(path) else None


def scored(label, dataset):
    payload = load(label)
    if payload is None:
        return None
    ref, rois = reference(dataset)
    stats, excluded, _ = ct.score(payload["records"], ref, rois)
    stats["roi_vs_mediapipe"] = ct.roi_delta(payload["records"], rois)
    stats["excluded"] = excluded
    return stats


def pooled(per_dataset):
    """Point-count-weighted mean of the per-dataset means."""
    n = sum(s["n_points"] for s in per_dataset if s)
    if n == 0:
        return None
    return {
        "n_points": n,
        "mean_px_at_256": sum(
            s["mean_px_at_256"] * s["n_points"] for s in per_dataset if s) / n,
    }


def main():
    report = {}

    report["headline"] = {}
    for name in DATASETS:
        report["headline"][name] = scored(name, name)
    report["headline"]["pooled"] = pooled(
        [report["headline"][n] for n in DATASETS])

    report["control_s1_vision_pipeline"] = {}
    for name, path in DATASETS.items():
        ref, rois = reference(name)
        control = os.path.join(path, "results", "swift_landmarks.json")
        if not os.path.exists(control):
            continue
        records = json.load(open(control))["records"]
        stats, _, _ = ct.score(records, ref, rois)
        stats["roi_vs_mediapipe"] = ct.roi_delta(records, rois)
        report["control_s1_vision_pipeline"][name] = stats
    report["control_s1_vision_pipeline"]["pooled"] = pooled(
        [report["control_s1_vision_pipeline"].get(n) for n in DATASETS])

    report["detector_scale"] = {}
    scales = ["1.5", "2.0", "2.5", "3.0", "3.5", "4.0"]
    for s in scales:
        row = {n: scored("sweep_%s_ds%s" % (n, s), n) for n in DATASETS}
        row = {k: v for k, v in row.items() if v}
        if not row:
            continue
        report["detector_scale"][s] = {
            n: {
                "n_images": v["n_images"],
                "mean_px_at_256": v["mean_px_at_256"],
                "roll_abs_deg_mean": v["roi_vs_mediapipe"]["roll_abs_deg_mean"],
            }
            for n, v in row.items()
        }
        report["detector_scale"][s]["pooled"] = pooled(list(row.values()))

    report["detector_precision"] = {}
    for name in DATASETS:
        fp32 = scored("fp32_%s" % name, name)
        fp16 = report["headline"][name]
        if fp32 and fp16:
            report["detector_precision"][name] = {
                "fp16_mean_px_at_256": fp16["mean_px_at_256"],
                "fp32_mean_px_at_256": fp32["mean_px_at_256"],
                "fp16_minus_fp32_px": fp16["mean_px_at_256"] - fp32["mean_px_at_256"],
            }

    report["parsing"] = {}
    for name in DATASETS:
        payload = load(name)
        if not payload:
            continue
        records = [r for r in payload["records"] if "parsing" in r]
        if not records:
            continue
        report["parsing"][name] = {
            "n": len(records),
            "parts_present": int(sum(r["parsing"]["parts_present"] for r in records)),
            "failed": [r["image"] for r in records if not r["parsing"]["parts_present"]],
            "skin_fraction_mean": float(
                np.mean([r["parsing"]["skin_fraction"] for r in records])),
            "skin_fraction_max": float(
                np.max([r["parsing"]["skin_fraction"] for r in records])),
        }

    report["note"] = (
        "Bar: docs/PLAN.md §3 spike S1, landmark error < 1 px at a 256px face crop "
        "against the MediaPipe Python reference. 'control' is the pipeline spike S1 "
        "shipped (Apple Vision's box straight into the mesh model), rescored here by "
        "the same function as the treatment. Neither number says anything about "
        "device speed; that is the bench file."
    )
    out = os.path.join(HERE, "results", "summary.json")
    json.dump(report, open(out, "w"), indent=1)
    print(json.dumps(report, indent=1))
    print("wrote", out)


if __name__ == "__main__":
    main()
