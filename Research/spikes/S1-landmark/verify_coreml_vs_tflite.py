#!/usr/bin/env python
"""
S1 spike, step 2: does the Core ML conversion preserve TFLite numerics?

Feeds identical 256x256 RGB tensors to (a) the original face_landmarks_detector.tflite via
LiteRT and (b) the converted .mlpackage via coremltools' macOS runtime, and reports per-point
2D error in crop pixels.

Inputs: the 256x256 crops written by the Swift harness (crops/*.png) if present, otherwise
falls back to random noise + the raw test images resized. Writes results/coreml_vs_tflite.json.
"""
import glob
import json
import os
import sys
import numpy as np
from PIL import Image
import coremltools as ct
from ai_edge_litert.interpreter import Interpreter

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")


def tflite_runner():
    it = Interpreter(model_path=os.path.join(HERE, "models", "face_landmarks_detector.tflite"))
    it.allocate_tensors()
    inp = it.get_input_details()[0]
    outs = it.get_output_details()

    def run(nhwc):
        it.set_tensor(inp["index"], nhwc.astype(np.float32))
        it.invoke()
        lm = it.get_tensor(outs[0]["index"]).reshape(478, 3)
        # output order in get_output_details is not guaranteed; find by size
        logit = None
        for o in outs:
            if o["name"].endswith("_1"):
                logit = float(it.get_tensor(o["index"]).reshape(-1)[0])
        score = 1.0 / (1.0 + np.exp(-logit)) if logit is not None else None
        return lm, score

    return run


def main():
    os.makedirs(RESULTS, exist_ok=True)
    run_tfl = tflite_runner()
    models = {}
    for suffix in ("fp32", "fp16"):
        p = os.path.join(HERE, "models", "FaceLandmark478_%s.mlpackage" % suffix)
        models[suffix] = ct.models.MLModel(p, compute_units=ct.ComputeUnit.CPU_AND_GPU)

    cases = []
    for p in sorted(glob.glob(os.path.join(HERE, "crops", "*.png"))):
        a = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32) / 255.0
        cases.append((os.path.basename(p), a))
    if not cases:
        print("no crops/ found - falling back to resized raw images", file=sys.stderr)
        for p in sorted(glob.glob(os.path.join(HERE, "images", "raw", "*.jpg")))[:10]:
            im = Image.open(p).convert("RGB").resize((256, 256), Image.BILINEAR)
            cases.append((os.path.basename(p), np.asarray(im, dtype=np.float32) / 255.0))
    rng = np.random.default_rng(7)
    cases.append(("__random_noise__", rng.random((256, 256, 3)).astype(np.float32)))

    report = {"cases": [], "summary": {}}
    agg = {"fp32": [], "fp16": []}
    for name, hwc in cases:
        nhwc = hwc[None, ...]
        nchw = np.transpose(nhwc, (0, 3, 1, 2)).astype(np.float32)
        ref, ref_score = run_tfl(nhwc)
        row = {"case": name, "tflite_score": ref_score}
        for suffix, m in models.items():
            out = m.predict({"image": nchw})
            got = np.array(out["landmarks"]).reshape(478, 3)
            d = np.linalg.norm(got[:, :2] - ref[:, :2], axis=1)
            row[suffix] = {
                "mean_px": float(d.mean()),
                "p95_px": float(np.percentile(d, 95)),
                "max_px": float(d.max()),
                "max_abs_z": float(np.abs(got[:, 2] - ref[:, 2]).max()),
                "score": float(np.array(out["score"]).reshape(-1)[0]),
            }
            agg[suffix].append(d)
        report["cases"].append(row)
        print(name, {k: round(row[k]["mean_px"], 5) for k in ("fp32", "fp16")})

    for suffix, ds in agg.items():
        alld = np.concatenate(ds)
        report["summary"][suffix] = {
            "n_cases": len(ds),
            "n_points": int(alld.size),
            "mean_px": float(alld.mean()),
            "p95_px": float(np.percentile(alld, 95)),
            "max_px": float(alld.max()),
        }
    report["note"] = (
        "Error is 2D Euclidean distance in 256x256 crop pixels between the converted Core ML "
        "model and the original TFLite model on identical input tensors. Core ML run on "
        "CPU_AND_GPU on this Mac."
    )
    out = os.path.join(RESULTS, "coreml_vs_tflite.json")
    json.dump(report, open(out, "w"), indent=1)
    print(json.dumps(report["summary"], indent=1))
    print("wrote", out)


if __name__ == "__main__":
    main()
