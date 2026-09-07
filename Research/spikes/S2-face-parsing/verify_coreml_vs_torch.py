"""Did the conversion preserve the network? — the control run.

Feeds Core ML and PyTorch *identical* tensors (the 512x512 RGB uint8 arrays
`torch_reference.py` wrote to images/in512), so any difference here is the
converter and the numeric precision, not the resampler and not the model.

Reports, per build:
  logit mean/max absolute difference
  label agreement (fraction of the 262 144 pixels whose argmax is unchanged)
  per-class IoU of the Core ML label map against the PyTorch one

and does the same for FaceParsing19.mlpackage, the image-input argmax build the
Swift side uses (labels only — it has no logit output).

Usage: python verify_coreml_vs_torch.py [--dir a6300]
"""

from __future__ import annotations

import json
import os
import sys

import coremltools as ct
import numpy as np
import torch
from PIL import Image

from bisenet import GROUPS, LABELS, NormalisedBiSeNet, load_bisenet

HERE = os.path.dirname(os.path.abspath(__file__))


def iou(a: np.ndarray, b: np.ndarray, ids) -> float | None:
    am = np.isin(a, ids)
    bm = np.isin(b, ids)
    union = np.logical_or(am, bm).sum()
    if union == 0:
        return None
    return float(np.logical_and(am, bm).sum() / union)


def main() -> int:
    base = HERE
    if "--dir" in sys.argv:
        base = os.path.join(HERE, sys.argv[sys.argv.index("--dir") + 1])
    in512 = os.path.join(base, "images", "in512")
    ids = sorted(os.path.splitext(f)[0] for f in os.listdir(in512) if f.endswith(".png"))

    torch_net = NormalisedBiSeNet(load_bisenet(os.path.join(HERE, "models", "79999_iter.pth")))
    torch_net.eval()

    models = {
        "logits_fp32": ct.models.MLModel(os.path.join(HERE, "models", "FaceParsing19_logits_fp32.mlpackage")),
        "logits_fp16": ct.models.MLModel(os.path.join(HERE, "models", "FaceParsing19_logits_fp16.mlpackage")),
    }
    image_model = ct.models.MLModel(os.path.join(HERE, "models", "FaceParsing19.mlpackage"))

    acc: dict[str, dict[str, list]] = {
        k: {"logit_mean_abs": [], "logit_max_abs": [], "label_agreement": []}
        for k in models
    }
    acc["image_argmax_fp16"] = {"label_agreement": []}
    group_iou: dict[str, dict[str, list]] = {
        k: {g: [] for g in GROUPS} for k in list(models) + ["image_argmax_fp16"]
    }

    for name in ids:
        rgb = np.array(Image.open(os.path.join(in512, f"{name}.png")).convert("RGB"))
        x = torch.from_numpy(rgb).permute(2, 0, 1).float().unsqueeze(0)  # 0-255 RGB
        with torch.no_grad():
            ref_logits = torch_net(x)[0].numpy()
        ref_labels = ref_logits.argmax(0)

        arr = x.numpy()
        for key, model in models.items():
            got = model.predict({"image": arr})["logits"][0]
            diff = np.abs(got.astype(np.float64) - ref_logits.astype(np.float64))
            acc[key]["logit_mean_abs"].append(float(diff.mean()))
            acc[key]["logit_max_abs"].append(float(diff.max()))
            labels = got.argmax(0)
            acc[key]["label_agreement"].append(float((labels == ref_labels).mean()))
            for g, gids in GROUPS.items():
                v = iou(labels, ref_labels, gids)
                if v is not None:
                    group_iou[key][g].append(v)

        pil = Image.open(os.path.join(in512, f"{name}.png")).convert("RGB")
        labels = np.asarray(image_model.predict({"image": pil})["labels"]).astype(np.int64)
        labels = labels.reshape(512, 512)
        acc["image_argmax_fp16"]["label_agreement"].append(float((labels == ref_labels).mean()))
        for g, gids in GROUPS.items():
            v = iou(labels, ref_labels, gids)
            if v is not None:
                group_iou["image_argmax_fp16"][g].append(v)
        print(f"{name}: agreement fp32={acc['logits_fp32']['label_agreement'][-1]:.6f} "
              f"fp16={acc['logits_fp16']['label_agreement'][-1]:.6f} "
              f"image={acc['image_argmax_fp16']['label_agreement'][-1]:.6f}")

    report = {
        "note": "Core ML vs PyTorch on identical 512x512 uint8 RGB inputs "
                "(images/in512). Difference = conversion + precision only.",
        "images": len(ids),
        "builds": {},
    }
    for key, metrics in acc.items():
        entry = {
            k: {"mean": float(np.mean(v)), "min": float(np.min(v)), "max": float(np.max(v))}
            for k, v in metrics.items()
            if v
        }
        entry["group_iou_vs_torch"] = {
            g: float(np.mean(v)) for g, v in group_iou[key].items() if v
        }
        report["builds"][key] = entry

    out = os.path.join(base, "results", "coreml_vs_torch.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report["builds"], indent=2))
    print("wrote", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
