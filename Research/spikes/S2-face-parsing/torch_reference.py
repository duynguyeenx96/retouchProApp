"""PyTorch reference run — the control for everything else in this spike.

Reproduces upstream `vendor/test.py` exactly (PIL bilinear resize to 512, ToTensor,
ImageNet normalise, `net(x)[0]`, argmax over channels) and writes:

  images/in512/<id>.png          the 512x512 RGB tensor the model actually saw,
                                 so the Core ML checks can be fed identical pixels
  results/torch_labels/<id>.png  argmax class index per pixel, uint8
  results/torch_logits/<id>.npy  raw logits (only for --keep-logits; ~19 MB each)

Usage: python torch_reference.py [--dir a6300] [--keep-logits]
"""

from __future__ import annotations

import json
import os
import sys

import numpy as np
import torch
from PIL import Image

from bisenet import INPUT_SIZE, MEAN, STD, load_bisenet

HERE = os.path.dirname(os.path.abspath(__file__))


def preprocess(path: str) -> tuple[np.ndarray, torch.Tensor]:
    img = Image.open(path).convert("RGB").resize(
        (INPUT_SIZE, INPUT_SIZE), Image.BILINEAR)
    rgb = np.array(img, dtype=np.uint8)
    x = torch.from_numpy(rgb).permute(2, 0, 1).float() / 255.0
    mean = torch.tensor(MEAN).view(3, 1, 1)
    std = torch.tensor(STD).view(3, 1, 1)
    return rgb, ((x - mean) / std).unsqueeze(0)


def main() -> int:
    base = HERE
    if "--dir" in sys.argv:
        base = os.path.join(HERE, sys.argv[sys.argv.index("--dir") + 1])
    keep_logits = "--keep-logits" in sys.argv

    raw_dir = os.path.join(base, "images", "raw")
    in512 = os.path.join(base, "images", "in512")
    lab_dir = os.path.join(base, "results", "torch_labels")
    log_dir = os.path.join(base, "results", "torch_logits")
    for d in (in512, lab_dir) + ((log_dir,) if keep_logits else ()):
        os.makedirs(d, exist_ok=True)

    net = load_bisenet(os.path.join(HERE, "models", "79999_iter.pth"))
    ids = sorted(
        os.path.splitext(f)[0]
        for f in os.listdir(raw_dir)
        if f.lower().endswith((".jpg", ".png"))
    )

    summary = {}
    with torch.no_grad():
        for name in ids:
            src = next(
                os.path.join(raw_dir, f)
                for f in os.listdir(raw_dir)
                if os.path.splitext(f)[0] == name
            )
            rgb, x = preprocess(src)
            Image.fromarray(rgb).save(os.path.join(in512, f"{name}.png"))
            logits = net(x)[0]
            labels = logits.argmax(1)[0].to(torch.uint8).numpy()
            Image.fromarray(labels, mode="L").save(os.path.join(lab_dir, f"{name}.png"))
            if keep_logits:
                np.save(os.path.join(log_dir, f"{name}.npy"), logits[0].numpy())
            present = np.unique(labels).tolist()
            summary[name] = present
            print(name, "classes:", present)

    out = os.path.join(base, "results", "torch_reference.json")
    with open(out, "w") as f:
        json.dump(
            {
                "checkpoint": "models/79999_iter.pth",
                "preprocess": "PIL BILINEAR 512x512, /255, ImageNet mean/std, net(x)[0].argmax(1)",
                "classes_present": summary,
            },
            f,
            indent=2,
        )
    print("wrote", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
