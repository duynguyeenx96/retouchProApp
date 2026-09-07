#!/usr/bin/env python
"""
S1 spike, step 3b (run with .venv, which has coremltools + LiteRT).

Answers the plan's pass bar: "sai so < 1 px @256 so MediaPipe Python".

Two comparisons, both against results/mp_reference.json produced by mp_reference.py:

  A. matched-ROI      our Core ML model fed MediaPipe's own 256x256 ROI crop.
                      Isolates the model conversion + the crop resampler from the
                      face detector. This is the number the plan's bar is about.
  B. Swift end-to-end our RPVision pipeline (Vision face box -> Core ML), read from
                      results/swift_landmarks.json. Includes the fact that Apple's
                      face box is not BlazeFace's, so the ROI differs.

Errors are reported in crop pixels: image-pixel error * 256 / roi_side, i.e. "how far
off would this point be if the face were framed at 256x256".
Writes results/accuracy_vs_mediapipe.json.
"""
import glob
import json
import os

import numpy as np
from PIL import Image
import coremltools as ct
from ai_edge_litert.interpreter import Interpreter

HERE = os.path.dirname(os.path.abspath(__file__))
# S1_BASE points mp_crops/ and results/ at another dataset directory with the same
# layout (a6300/ = the real Sony frames). Models always come from the spike root.
BASE = os.environ.get("S1_BASE", HERE)
RESULTS = os.path.join(BASE, "results")
SIDE = 256


def crop_to_image(roi):
    s = roi["side"] / SIDE
    c, sn = np.cos(roi["rotation"]), np.sin(roi["rotation"])
    return np.array([
        [s * c, -s * sn, roi["center_x"] - s * (c * SIDE / 2 - sn * SIDE / 2)],
        [s * sn, s * c, roi["center_y"] - s * (sn * SIDE / 2 + c * SIDE / 2)],
        [0.0, 0.0, 1.0],
    ])


def map_points(pts, m):
    h = np.concatenate([pts, np.ones((len(pts), 1))], axis=1)
    return (h @ m.T)[:, :2]


def tflite_runner():
    it = Interpreter(model_path=os.path.join(HERE, "models", "face_landmarks_detector.tflite"))
    it.allocate_tensors()
    inp = it.get_input_details()[0]
    out0 = it.get_output_details()[0]

    def run(nhwc):
        it.set_tensor(inp["index"], nhwc.astype(np.float32))
        it.invoke()
        return it.get_tensor(out0["index"]).reshape(478, 3)

    return run


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


def main():
    ref = json.load(open(os.path.join(RESULTS, "mp_reference.json")))
    rois = json.load(open(os.path.join(RESULTS, "mp_rois.json")))
    run_tfl = tflite_runner()
    coreml = ct.models.MLModel(os.path.join(HERE, "models", "FaceLandmark478.mlpackage"),
                               compute_units=ct.ComputeUnit.CPU_AND_GPU)

    report = {"dataset": os.path.basename(os.path.normpath(BASE)),
              "per_image": {}, "summary": {}, "excluded": []}

    def same_face(pts, gt, roi_side):
        """Guard for multi-face frames: Vision's first face and MediaPipe's first
        face must be the same person, otherwise the error is meaningless."""
        return np.linalg.norm(pts.mean(axis=0) - gt.mean(axis=0)) < 0.5 * roi_side

    # --- A. matched ROI -----------------------------------------------------
    err_coreml, err_tflite = [], []
    for p in sorted(glob.glob(os.path.join(BASE, "mp_crops", "*.png"))):
        name = os.path.basename(p).replace(".png", ".jpg")
        if name not in ref or name not in rois:
            continue
        pil = Image.open(p).convert("RGB")
        arr = np.asarray(pil, dtype=np.float32) / 255.0
        m = crop_to_image(rois[name])
        gt = np.array(ref[name]["points"])[:, :2]
        scale = SIDE / rois[name]["side"]

        cm = np.array(coreml.predict({"image": pil})["landmarks"]).reshape(478, 3)[:, :2]
        d_cm = np.linalg.norm(map_points(cm, m) - gt, axis=1) * scale
        err_coreml.append(d_cm)

        tf = run_tfl(arr[None, ...])[:, :2]
        d_tf = np.linalg.norm(map_points(tf, m) - gt, axis=1) * scale
        err_tflite.append(d_tf)

        report["per_image"].setdefault(name, {})["matched_roi_coreml_mean_px_at_256"] = float(d_cm.mean())
        report["per_image"][name]["matched_roi_tflite_mean_px_at_256"] = float(d_tf.mean())
        report["per_image"][name]["roi_side_px"] = rois[name]["side"]

    report["summary"]["A_matched_roi_coreml_vs_mediapipe"] = stats(err_coreml)
    report["summary"]["A_control_tflite_vs_mediapipe"] = stats(err_tflite)

    # --- B. Swift end-to-end ------------------------------------------------
    swift_path = os.path.join(RESULTS, "swift_landmarks.json")
    if os.path.exists(swift_path):
        swift = json.load(open(swift_path))["records"]
        err_swift = []
        for rec in swift:
            name = rec["image"]
            if name not in ref:
                continue
            pts = np.array(rec["image_points"], dtype=np.float64).reshape(478, 2)
            gt = np.array(ref[name]["points"])[:, :2]
            scale = SIDE / rois[name]["side"]
            if not same_face(pts, gt, rois[name]["side"]):
                report["excluded"].append(
                    {"image": name, "why": "Vision and MediaPipe locked onto different faces"})
                continue
            d = np.linalg.norm(pts - gt, axis=1) * scale
            err_swift.append(d)
            report["per_image"].setdefault(name, {})["swift_e2e_mean_px_at_256"] = float(d.mean())
            report["per_image"][name]["swift_roi_side_px"] = rec["crop"]["side"]
        report["summary"]["B_swift_pipeline_vs_mediapipe"] = stats(err_swift)

    # --- C. ROI scale sweep for the Vision front end ------------------------
    sweep_path = os.path.join(RESULTS, "swift_roi_sweep.json")
    if os.path.exists(sweep_path):
        sweep = json.load(open(sweep_path))
        report["summary"]["C_swift_roi_scale_sweep"] = {}
        for key in sorted(sweep):
            errs = []
            for rec in sweep[key]:
                name = rec["image"]
                if name not in ref:
                    continue
                pts = np.array(rec["image_points"], dtype=np.float64).reshape(478, 2)
                gt = np.array(ref[name]["points"])[:, :2]
                if not same_face(pts, gt, rois[name]["side"]):
                    continue
                errs.append(np.linalg.norm(pts - gt, axis=1) * SIDE / rois[name]["side"])
            report["summary"]["C_swift_roi_scale_sweep"][key] = stats(errs)

    report["note"] = (
        "A: Core ML model on MediaPipe's own ROI crop, landmarks mapped back to image pixels "
        "and compared with mediapipe.tasks FaceLandmarker output, then rescaled to a 256px face "
        "crop. The tflite control is the same measurement with the unconverted model, so the "
        "residual there is the ROI resampler (cv2.warpAffine vs MediaPipe's ImageToTensor), not "
        "the conversion. B: RPVision's Vision-detector pipeline end to end; its extra error is "
        "the different face box, not the model."
    )
    out = os.path.join(RESULTS, "accuracy_vs_mediapipe.json")
    json.dump(report, open(out, "w"), indent=1)
    print(json.dumps(report["summary"], indent=1))
    print("wrote", out)


if __name__ == "__main__":
    main()
