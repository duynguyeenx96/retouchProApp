#!/usr/bin/env python
"""
S1 spike, step 3a (run with .venv-mp, which has mediapipe 0.10.21).

Produces the MediaPipe Python reference the plan's pass bar is measured against:

  results/mp_reference.json   478 landmarks per image, in image pixels, from
                              mediapipe.tasks FaceLandmarker (IMAGE mode, CPU).
  mp_crops/<name>.png         the 256x256 ROI MediaPipe's own graph would feed to
                              the mesh network, reproduced here from the FaceDetector
                              output with the same calculator maths
                              (DetectionsToRects + RectTransformation
                               square_long=true, scale=1.5, then a rotated warpAffine).
  results/mp_rois.json        the ROI parameters, so step 3b can map crop-space
                              landmarks back into image pixels.
"""
import glob
import json
import math
import os

import cv2
import numpy as np
import mediapipe as mp
from mediapipe.tasks import python as mpp
from mediapipe.tasks.python import vision

HERE = os.path.dirname(os.path.abspath(__file__))
# S1_BASE points images/, mp_crops/ and results/ at another dataset directory that
# has the same layout (used for a6300/, the real Sony frames). Models always come
# from the spike root.
BASE = os.environ.get("S1_BASE", HERE)
TASK = os.path.join(HERE, "models", "face_landmarker_v2_with_blendshapes.task")
DETECTOR = os.path.join(HERE, "models", "blaze_face_short_range.tflite")
CROPS = os.path.join(BASE, "mp_crops")
RESULTS = os.path.join(BASE, "results")
SIDE = 256


def roi_from_detection(det, w, h, scale=1.5):
    """Replicates DetectionsToRectsCalculator + RectTransformationCalculator."""
    bb = det.bounding_box
    cx = bb.origin_x + bb.width / 2.0
    cy = bb.origin_y + bb.height / 2.0
    kp = det.keypoints  # 0 = subject's right eye, 1 = subject's left eye
    x0, y0 = kp[0].x * w, kp[0].y * h
    x1, y1 = kp[1].x * w, kp[1].y * h
    rotation = -math.atan2(-(y1 - y0), x1 - x0)
    rotation = rotation - 2 * math.pi * math.floor((rotation + math.pi) / (2 * math.pi))
    long_side = max(bb.width, bb.height)
    side = round(long_side * scale)
    return {"center_x": cx, "center_y": cy, "side": float(side), "rotation": rotation}


def crop_to_image_matrix(roi):
    s = roi["side"] / SIDE
    c, sn = math.cos(roi["rotation"]), math.sin(roi["rotation"])
    # [x_img, y_img] = center + R * s * ([u,v] - SIDE/2)
    m = np.array(
        [
            [s * c, -s * sn, roi["center_x"] - s * (c * SIDE / 2 - sn * SIDE / 2)],
            [s * sn, s * c, roi["center_y"] - s * (sn * SIDE / 2 + c * SIDE / 2)],
            [0.0, 0.0, 1.0],
        ]
    )
    return m


def main():
    os.makedirs(CROPS, exist_ok=True)
    os.makedirs(RESULTS, exist_ok=True)

    lm = vision.FaceLandmarker.create_from_options(
        vision.FaceLandmarkerOptions(
            base_options=mpp.BaseOptions(model_asset_path=TASK,
                                         delegate=mpp.BaseOptions.Delegate.CPU),
            running_mode=vision.RunningMode.IMAGE, num_faces=1))
    fd = vision.FaceDetector.create_from_options(
        vision.FaceDetectorOptions(
            base_options=mpp.BaseOptions(model_asset_path=DETECTOR,
                                         delegate=mpp.BaseOptions.Delegate.CPU),
            running_mode=vision.RunningMode.IMAGE))

    refs, rois = {}, {}
    for p in sorted(glob.glob(os.path.join(BASE, "images", "raw", "*.jpg"))):
        name = os.path.basename(p)
        bgr = cv2.imread(p)
        h, w = bgr.shape[:2]
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        mpimg = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

        res = lm.detect(mpimg)
        if not res.face_landmarks:
            print("no landmarks", name)
            continue
        pts = [[l.x * w, l.y * h, l.z] for l in res.face_landmarks[0]]
        refs[name] = {"image_w": w, "image_h": h, "points": pts}

        det = fd.detect(mpimg)
        if not det.detections:
            print("no detection", name)
            continue
        roi = roi_from_detection(det.detections[0], w, h)
        rois[name] = roi
        m = crop_to_image_matrix(roi)
        inv = np.linalg.inv(m)[:2]
        crop = cv2.warpAffine(rgb, inv, (SIDE, SIDE), flags=cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
        cv2.imwrite(os.path.join(CROPS, name.replace(".jpg", ".png")),
                    cv2.cvtColor(crop, cv2.COLOR_RGB2BGR))
        print(name, "roi side", roi["side"], "rot %.4f" % roi["rotation"])

    json.dump(refs, open(os.path.join(RESULTS, "mp_reference.json"), "w"))
    json.dump(rois, open(os.path.join(RESULTS, "mp_rois.json"), "w"), indent=1)
    print("images with reference landmarks:", len(refs))


if __name__ == "__main__":
    main()
