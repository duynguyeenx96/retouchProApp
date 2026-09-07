#!/usr/bin/env python3
"""
S1 spike, §4a follow-up. Stdlib only, no venv needed.

Two derived files, both from JSON that is already on disk:

  a6300/results/roi_delta.json        how far RPVision's ROI (Vision box +
                                      eye-centroid roll, scale = visionBoxScale) is
                                      from MediaPipe's BlazeFace ROI on the real
                                      a6300 frames. This is the term that keeps
                                      comparison B above 1 px.
  a6300/results/roi_scale_pooled.json the two ROI-scale sweeps (20 stock portraits,
                                      11 a6300 frames) pooled by point count, which
                                      is what decides whether FaceCrop.visionBoxScale
                                      should stay at 1.40.

Usage: python3 a6300_roi_stats.py
"""
import json
import math
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
A = os.path.join(HERE, "a6300", "results")


def roi_delta():
    swift = json.load(open(os.path.join(A, "swift_landmarks.json")))["records"]
    mp = json.load(open(os.path.join(A, "mp_rois.json")))
    rows = []
    for rec in swift:
        name = rec["image"]
        if name not in mp:
            continue
        m, c = mp[name], rec["crop"]
        rows.append({
            "image": name,
            "mp_side_over_swift_side": m["side"] / c["side"],
            "rotation_delta_rad": c["rotation"] - m["rotation"],
            "center_delta_over_side":
                math.hypot(c["center_x"] - m["center_x"], c["center_y"] - m["center_y"]) / m["side"],
        })
    ratio = [r["mp_side_over_swift_side"] for r in rows]
    drot = [r["rotation_delta_rad"] for r in rows]
    out = {
        "per_image": rows,
        "mean_mp_side_over_swift_side": statistics.mean(ratio),
        "sd_mp_side_over_swift_side": statistics.pstdev(ratio),
        "mean_abs_rotation_delta_rad": statistics.mean(abs(x) for x in drot),
        "sd_rotation_delta_rad": statistics.pstdev(drot),
        "mean_center_delta_over_side": statistics.mean(r["center_delta_over_side"] for r in rows),
        "note": "Vision (DetectFaceLandmarksRequest box + eye-centroid roll, scale = "
                "FaceCrop.visionBoxScale = 1.40) vs MediaPipe BlazeFace ROI (square_long, "
                "scale = 1.5), 11 real a6300 frames.",
    }
    path = os.path.join(A, "roi_delta.json")
    json.dump(out, open(path, "w"), indent=1)
    print("mean mp_side/swift_side %.4f (sd %.4f)" % (out["mean_mp_side_over_swift_side"],
                                                      out["sd_mp_side_over_swift_side"]))
    print("mean |rotation delta| %.4f rad (sd %.4f)" % (out["mean_abs_rotation_delta_rad"],
                                                        out["sd_rotation_delta_rad"]))
    print("mean centre delta %.4f x side" % out["mean_center_delta_over_side"])
    print("wrote", path)


def pooled_sweep():
    stock = json.load(open(os.path.join(HERE, "results", "accuracy_vs_mediapipe.json")))
    real = json.load(open(os.path.join(A, "accuracy_vs_mediapipe.json")))
    a = stock["summary"]["C_swift_roi_scale_sweep"]
    b = real["summary"]["C_swift_roi_scale_sweep"]
    out = {
        "note": "Point-weighted pooling of the two ROI-scale sweeps: 20 Wikimedia portraits "
                "(results/) and 11 real Sony a6300 frames (a6300/results/). mean_px_at_256 "
                "vs the MediaPipe Python reference.",
        "per_scale": {},
    }
    best = None
    print("%-12s %8s %8s %8s" % ("scale", "wiki", "a6300", "pooled"))
    for k in sorted(set(a) & set(b)):
        na, nb = a[k]["n_points"], b[k]["n_points"]
        pooled = (a[k]["mean_px_at_256"] * na + b[k]["mean_px_at_256"] * nb) / (na + nb)
        out["per_scale"][k] = {
            "wikimedia_mean_px": a[k]["mean_px_at_256"],
            "a6300_mean_px": b[k]["mean_px_at_256"],
            "pooled_mean_px": pooled,
            "n_points": na + nb,
        }
        print("%-12s %8.3f %8.3f %8.3f" % (k, a[k]["mean_px_at_256"], b[k]["mean_px_at_256"], pooled))
        if best is None or pooled < out["per_scale"][best]["pooled_mean_px"]:
            best = k
    out["pooled_argmin"] = best
    path = os.path.join(A, "roi_scale_pooled.json")
    json.dump(out, open(path, "w"), indent=1)
    print("pooled argmin:", best)
    print("wrote", path)


if __name__ == "__main__":
    roi_delta()
    print()
    pooled_sweep()
