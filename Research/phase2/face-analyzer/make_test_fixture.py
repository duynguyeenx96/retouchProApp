#!/usr/bin/env python
"""
Builds the RPVisionTests fixture for the BlazeFace path.

Same idea as spike S2's fixture: a golden produced by the *Python* side, so the
Swift test is checking against something that did not come out of the Swift code
it is testing.

Writes into Packages/RPVision/Tests/RPVisionTests/Phase2/:
  blazeface_128.png      the S1 test face, resized to the detector's 128px input
                         (Wikimedia Commons "Alex Roessner Headshot 2022",
                         CC BY-SA 4.0 — licence recorded in
                         Research/spikes/S1-landmark/images/manifest_commons.json,
                         which is why this one can be committed)
  blazeface_golden.json  the decoded top detection: score, box and 6 keypoints in
                         the 0..1 frame of that 128px input, from
                         `verify_blazeface_vs_tflite.py`'s decoder — i.e. the
                         MediaPipe maths written once in Python and once in Swift.

The model itself is copied by hand:
  cp -R Research/spikes/S1-landmark/models/BlazeFaceShortRange.mlpackage \
        Packages/RPVision/Tests/RPVisionTests/Phase2/

Usage:  .venv/bin/python make_test_fixture.py     (S1's venv)
"""
import importlib.util
import json
import os

import numpy as np
from PIL import Image
import coremltools as ct

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
S1 = os.path.join(REPO, "Research/spikes/S1-landmark")
DEST = os.path.join(REPO, "Packages/RPVision/Tests/RPVisionTests/Phase2")

spec = importlib.util.spec_from_file_location(
    "verify_blazeface", os.path.join(S1, "verify_blazeface_vs_tflite.py"))
vb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vb)

SOURCE = os.path.join(
    REPO, "Packages/RPVision/Tests/RPVisionTests/SpikeS1/face_crop_256.png")


def main():
    os.makedirs(DEST, exist_ok=True)
    pil = Image.open(SOURCE).convert("RGB").resize((128, 128), Image.BILINEAR)
    pil.save(os.path.join(DEST, "blazeface_128.png"))

    model = ct.models.MLModel(
        os.path.join(S1, "models", "BlazeFaceShortRange.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY)
    out = model.predict({"image": pil})
    reg = np.array(out["regressors"]).reshape(896, 16)
    logits = np.array(out["score_logits"]).reshape(896)

    scores, boxes = vb.decode(reg, logits)
    keep = np.where(scores >= 0.5)[0]
    order = keep[np.argsort(-scores[keep])]

    # Weighted NMS, MediaPipe's WEIGHTED algorithm, over the surviving anchors.
    def iou(a, b):
        ax0, ay0 = a[0] - a[2] / 2, a[1] - a[3] / 2
        ax1, ay1 = a[0] + a[2] / 2, a[1] + a[3] / 2
        bx0, by0 = b[0] - b[2] / 2, b[1] - b[3] / 2
        bx1, by1 = b[0] + b[2] / 2, b[1] + b[3] / 2
        iw = max(0.0, min(ax1, bx1) - max(ax0, bx0))
        ih = max(0.0, min(ay1, by1) - max(ay0, by0))
        inter = iw * ih
        union = a[2] * a[3] + b[2] * b[3] - inter
        return inter / union if union > 0 else 0.0

    best = order[0]
    cluster = [i for i in order if iou(boxes[i], boxes[best]) > 0.3]
    total = scores[cluster].sum()
    side = float(vb.SIDE)

    def weighted(values):
        return float((scores[cluster] * values[cluster]).sum() / total)

    xmin = weighted(boxes[:, 0] - boxes[:, 2] / 2) / side
    ymin = weighted(boxes[:, 1] - boxes[:, 3] / 2) / side
    xmax = weighted(boxes[:, 0] + boxes[:, 2] / 2) / side
    ymax = weighted(boxes[:, 1] + boxes[:, 3] / 2) / side

    anchors = vb.ANCHORS
    keypoints = []
    for k in range(6):
        kx = (reg[:, 4 + k * 2] / side + anchors[:, 0])
        ky = (reg[:, 5 + k * 2] / side + anchors[:, 1])
        keypoints.append([weighted(kx), weighted(ky)])

    golden = {
        "source": "SpikeS1/face_crop_256.png resized to 128 with PIL BILINEAR",
        "model": "BlazeFaceShortRange.mlpackage (fp16)",
        "n_cluster": len(cluster),
        "score": float(scores[best]),
        "box_xywh_normalised": [xmin, ymin, xmax - xmin, ymax - ymin],
        "keypoints_normalised": keypoints,
        "note": (
            "Decoded by the Python side (verify_blazeface_vs_tflite.decode + the "
            "weighted NMS above), so the Swift BlazeFaceDecoder is checked against "
            "an independent implementation of MediaPipe's calculators rather than "
            "against itself."
        ),
    }
    with open(os.path.join(DEST, "blazeface_golden.json"), "w") as f:
        json.dump(golden, f, indent=1)
    print(json.dumps(golden, indent=1))
    print("wrote", DEST)


if __name__ == "__main__":
    main()
