"""Does a bigger input fix the eye group? — the other hypothesis.

experiment_facecrop.py ruled out framing (CelebA-HQ faces already fill the frame,
so the "tighter crop" idea collapses to the baseline). The remaining lever is
input resolution: BiSeNet is fully convolutional, so it runs at any multiple of 32.

This runs the PyTorch model — Core ML has already been shown to match it to
0.02 % of pixels (results/coreml_vs_torch.json), so there is no need to convert a
model per resolution just to answer the question — resizes the argmax back to the
512 ground-truth grid with nearest neighbour, and scores.

Cost matters as much as accuracy: 1024 is 4x the pixels, and PLAN §1.4 already
budgets "parsing 512 px". Any gain has to be weighed against ms/image.

Usage: python experiment_resolution.py [--sizes 384,512,768,1024]
"""

from __future__ import annotations

import json
import os
import sys
import time

import numpy as np
import torch
from PIL import Image

from bisenet import GROUPS, MEAN, STD, load_bisenet

HERE = os.path.dirname(os.path.abspath(__file__))
GT_SIDE = 512


def iou(a: np.ndarray, b: np.ndarray) -> float | None:
    union = np.logical_or(a, b).sum()
    return None if union == 0 else float(np.logical_and(a, b).sum() / union)


def main() -> int:
    sizes = [384, 512, 768, 1024]
    if "--sizes" in sys.argv:
        sizes = [int(s) for s in sys.argv[sys.argv.index("--sizes") + 1].split(",")]

    net = load_bisenet(os.path.join(HERE, "models", "79999_iter.pth"))
    manifest = json.load(open(os.path.join(HERE, "images", "manifest_celebamaskhq.json")))
    ids = [str(i["celeba_hq_index"]) for i in manifest["images"]]
    mean = torch.tensor(MEAN).view(3, 1, 1)
    std = torch.tensor(STD).view(3, 1, 1)

    report = {"note": "PyTorch, whole frame, argmax resized to the 512 GT grid",
              "sizes": {}}
    for size in sizes:
        values = {g: [] for g in GROUPS}
        elapsed = []
        for name in ids:
            src = Image.open(
                os.path.join(HERE, "images", "raw", f"{name}.jpg")
            ).convert("RGB").resize((size, size), Image.BILINEAR)
            x = torch.from_numpy(np.array(src)).permute(2, 0, 1).float() / 255.0
            x = ((x - mean) / std).unsqueeze(0)
            t0 = time.perf_counter()
            with torch.no_grad():
                labels = net(x)[0].argmax(1)[0].to(torch.uint8).numpy()
            elapsed.append((time.perf_counter() - t0) * 1e3)
            if size != GT_SIDE:
                labels = np.array(
                    Image.fromarray(labels, mode="L").resize(
                        (GT_SIDE, GT_SIDE), Image.NEAREST))
            gt = np.array(Image.open(os.path.join(HERE, "images", "gt", f"{name}.png")))
            for g, gids in GROUPS.items():
                v = iou(np.isin(labels, gids), np.isin(gt, gids))
                if v is not None:
                    values[g].append(v)
        entry = {
            g: {
                "mean_first10": float(np.array(v)[:10].mean()),
                "mean_all": float(np.mean(v)),
                "min": float(np.min(v)),
            }
            for g, v in values.items()
        }
        entry["torch_cpu_ms_median"] = float(np.median(elapsed))
        report["sizes"][str(size)] = entry
        print(f"{size:5d}: " + "  ".join(
            f"{g}={entry[g]['mean_first10']:.4f}/{entry[g]['mean_all']:.4f}" for g in GROUPS)
            + f"   torch-cpu {entry['torch_cpu_ms_median']:.0f} ms")

    out = os.path.join(HERE, "results", "resolution_sweep.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print("wrote", out, "(values are first10/all30)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
