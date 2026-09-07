#!/usr/bin/env python
"""
Conversion fidelity check for `convert_blazeface_to_coreml.py`: Core ML vs the
original TFLite interpreter on identical input tensors.

This is the control that separates "the conversion is wrong" from "the detector
is wrong". It is the direct analogue of `verify_coreml_vs_tflite.py` for the mesh
model (S1 §3a), and it is deliberately run on the *same pixels* on both sides —
the crop resampler is out of the comparison entirely.

Inputs: the 256px face crops the Swift harness already wrote to crops/ (resized to
128 with PIL bilinear), plus one random-noise frame as a negative control.

Errors reported:
  * max/mean abs difference on the raw regressor tensor and on the score logits
  * the same after the decode both runtimes feed: sigmoid(clip(logit, +-100))
  * the decoded top-1 box centre / side difference, in 128px input pixels — the
    number that actually matters, because that box becomes the mesh model's ROI.

Usage:
    .venv/bin/python verify_blazeface_vs_tflite.py
"""
import glob
import json
import os

import numpy as np
from PIL import Image
import coremltools as ct
from ai_edge_litert.interpreter import Interpreter

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = os.path.join(HERE, "models")
RESULTS = os.path.join(HERE, "results")
SIDE = 128


def anchors():
    """MediaPipe SsdAnchorsCalculator for face_detection_short_range:
    num_layers 4, strides 8/16/16/16, anchor offset 0.5, fixed_anchor_size.
    That is 16x16x2 + 8x8x6 = 896 anchor centres; sizes are all 1.0 and unused."""
    out = []
    for stride, per_cell in ((8, 2), (16, 6)):
        fm = int(np.ceil(SIDE / stride))
        for y in range(fm):
            for x in range(fm):
                for _ in range(per_cell):
                    out.append(((x + 0.5) / fm, (y + 0.5) / fm))
    return np.array(out, dtype=np.float64)


ANCHORS = anchors()


def decode(reg, logits):
    """TensorsToDetectionsCalculator with reverse_output_order: true, all scales
    128. Returns (scores, boxes[cx,cy,w,h] in 128px pixels)."""
    scores = 1.0 / (1.0 + np.exp(-np.clip(logits, -100.0, 100.0)))
    cx = reg[:, 0] / SIDE + ANCHORS[:, 0]
    cy = reg[:, 1] / SIDE + ANCHORS[:, 1]
    w = reg[:, 2] / SIDE
    h = reg[:, 3] / SIDE
    return scores, np.stack([cx * SIDE, cy * SIDE, w * SIDE, h * SIDE], axis=1)


def main():
    os.makedirs(RESULTS, exist_ok=True)
    it = Interpreter(model_path=os.path.join(MODELS, "blaze_face_short_range.tflite"))
    it.allocate_tensors()
    inp = it.get_input_details()[0]
    outs = it.get_output_details()

    def run_tflite(nhwc):
        it.set_tensor(inp["index"], nhwc.astype(np.float32))
        it.invoke()
        reg = it.get_tensor(outs[0]["index"]).reshape(896, 16)
        cls = it.get_tensor(outs[1]["index"]).reshape(896)
        return reg, cls

    models = {
        p: ct.models.MLModel(os.path.join(MODELS, "BlazeFaceShortRange_%s.mlpackage" % p),
                             compute_units=ct.ComputeUnit.CPU_ONLY)
        for p in ("fp32", "fp16")
    }

    cases = []
    for p in sorted(glob.glob(os.path.join(HERE, "crops", "*.png")))[:20]:
        pil = Image.open(p).convert("RGB").resize((SIDE, SIDE), Image.BILINEAR)
        cases.append((os.path.basename(p), np.asarray(pil, dtype=np.float32)))
    rng = np.random.default_rng(0)
    cases.append(("__noise__", rng.uniform(0, 255, (SIDE, SIDE, 3)).astype(np.float32)))

    report = {"n_cases": len(cases), "builds": {}}
    for precision, model in models.items():
        d_reg, d_logit, d_score, d_box = [], [], [], []
        for name, rgb255 in cases:
            nhwc = (rgb255 / 127.5 - 1.0)[None, ...]
            reg_t, cls_t = run_tflite(nhwc)
            nchw = np.transpose(nhwc, (0, 3, 1, 2)).astype(np.float32)
            out = model.predict({"image": nchw})
            reg_c = np.array(out["regressors"]).reshape(896, 16)
            cls_c = np.array(out["score_logits"]).reshape(896)

            d_reg.append(np.abs(reg_c - reg_t).max())
            d_logit.append(np.abs(cls_c - cls_t).max())
            s_t, b_t = decode(reg_t, cls_t)
            s_c, b_c = decode(reg_c, cls_c)
            d_score.append(np.abs(s_c - s_t).max())
            i = int(np.argmax(s_t))
            if name != "__noise__" and s_t[i] > 0.5:
                d_box.append(np.abs(b_c[i] - b_t[i]).max())

        report["builds"][precision] = {
            "max_abs_regressor_diff": float(np.max(d_reg)),
            "mean_abs_regressor_diff": float(np.mean(d_reg)),
            "max_abs_logit_diff": float(np.max(d_logit)),
            "max_abs_score_diff": float(np.max(d_score)),
            "n_boxes_compared": len(d_box),
            "max_top1_box_diff_px_at_128": float(np.max(d_box)) if d_box else None,
            "mean_top1_box_diff_px_at_128": float(np.mean(d_box)) if d_box else None,
        }
        print(precision, json.dumps(report["builds"][precision], indent=1))

    report["note"] = (
        "Identical input tensors on both sides (PIL-resized 128px crops + one noise "
        "frame), so the resampler is out of the comparison. fp32 is the control: it "
        "says the MIL translation is numerically the same network. The box diff is "
        "in 128px detector-input pixels for the highest-scoring anchor."
    )
    out = os.path.join(RESULTS, "blazeface_coreml_vs_tflite.json")
    json.dump(report, open(out, "w"), indent=1)
    print("wrote", out)


if __name__ == "__main__":
    main()
