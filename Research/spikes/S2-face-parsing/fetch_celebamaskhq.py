"""Pulls a small evaluation set out of CelebAMask-HQ without downloading 3.1 GB.

`CelebAMask-HQ.zip` is mirrored on Hugging Face and the CDN honours HTTP range
requests, so `remote_zip.py` reads the ZIP central directory and then only the
members we ask for. This grabs, for each selected image:

  CelebAMask-HQ/CelebA-HQ-img/<i>.jpg                        (1024x1024 source)
  CelebAMask-HQ/CelebAMask-HQ-mask-anno/<i//2000>/<i:05d>_<att>.png   (512x512)

and merges the per-part annotations into one 512x512 label PNG using
`vendor/prepropess_data.py`'s exact rule (`mask[sep_mask == 225] = l`, l from
`enumerate(atts, 1)`). Merging locally rather than taking someone's pre-merged
mask is the point: it guarantees the ground-truth indices are the same ones the
checkpoint was trained against.

Image selection: the official CelebAMask-HQ split is CelebA's, i.e.
`CelebA-HQ-to-CelebA-mapping.txt` orig_idx >= 182638 is *test*
(switchablenorms/CelebAMask-HQ, face_parsing/Data_preprocessing/g_partition.py).
We take the first N test-split indices in ascending CelebA-HQ index order, which
is deterministic and involves no cherry-picking.

Caveat recorded in the report: zllrunning's `face_dataset.FaceMask` lists *all* of
`CelebA-HQ-img` regardless of mode, so the published checkpoint was very likely
trained on the whole 30 k set, test split included. Using the official test split
is the best available convention, not a guarantee of held-out data — which is why
the report leans on the a6300 frames for the generalisation question.

Usage: python fetch_celebamaskhq.py [N]      (default 10)
"""

from __future__ import annotations

import io
import json
import os
import sys
import zipfile

import numpy as np
from PIL import Image

from remote_zip import HTTPRangeFile

HERE = os.path.dirname(os.path.abspath(__file__))
ZIP_URL = "https://huggingface.co/datasets/RichardErkhov/celebamask-hq/resolve/main/CelebAMask-HQ.zip"
ATTS = [
    "skin", "l_brow", "r_brow", "l_eye", "r_eye", "eye_g", "l_ear", "r_ear",
    "ear_r", "nose", "mouth", "u_lip", "l_lip", "neck", "neck_l", "cloth",
    "hair", "hat",
]
TEST_SPLIT_MIN_ORIG_IDX = 182638


def main() -> int:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    img_dir = os.path.join(HERE, "images", "raw")
    gt_dir = os.path.join(HERE, "images", "gt")
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(gt_dir, exist_ok=True)

    raw = HTTPRangeFile(ZIP_URL)
    zf = zipfile.ZipFile(io.BufferedReader(raw, buffer_size=1 << 20))
    names = set(zf.namelist())

    mapping = zf.read("CelebAMask-HQ/CelebA-HQ-to-CelebA-mapping.txt").decode()
    test_ids = []
    for line in mapping.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 2:
            continue
        idx, orig = int(parts[0]), int(parts[1])
        if orig >= TEST_SPLIT_MIN_ORIG_IDX:
            test_ids.append((idx, orig, parts[2]))
    test_ids.sort()
    print(f"official test split: {len(test_ids)} images; taking the first {n}")

    manifest = []
    for idx, orig, orig_file in test_ids[:n]:
        jpg = f"CelebAMask-HQ/CelebA-HQ-img/{idx}.jpg"
        dest_img = os.path.join(img_dir, f"{idx}.jpg")
        if not os.path.exists(dest_img):
            with open(dest_img, "wb") as f:
                f.write(zf.read(jpg))

        label = np.zeros((512, 512), dtype=np.uint8)
        present = []
        for l, att in enumerate(ATTS, 1):
            member = (
                f"CelebAMask-HQ/CelebAMask-HQ-mask-anno/{idx // 2000}/"
                f"{idx:05d}_{att}.png"
            )
            if member not in names:
                continue
            sep = np.array(Image.open(io.BytesIO(zf.read(member))).convert("P"))
            label[sep == 225] = l
            present.append(att)
        Image.fromarray(label, mode="L").save(os.path.join(gt_dir, f"{idx}.png"))
        src_w, src_h = Image.open(dest_img).size
        print(f"  {idx}: parts={len(present)} {present}")
        manifest.append(
            {
                "celeba_hq_index": idx,
                "celeba_orig_index": orig,
                "celeba_orig_file": orig_file,
                "image": f"images/raw/{idx}.jpg",
                "image_size": [src_w, src_h],
                "ground_truth": f"images/gt/{idx}.png",
                "parts_present": present,
            }
        )

    out = os.path.join(HERE, "images", "manifest_celebamaskhq.json")
    with open(out, "w") as f:
        json.dump(
            {
                "source_zip": ZIP_URL,
                "source_zip_size_bytes": raw.size,
                "upstream": "https://github.com/switchablenorms/CelebAMask-HQ",
                "licence": "non-commercial research and educational use only",
                "split": "official test split (CelebA orig_idx >= 182638)",
                "label_ids": ["background"] + ATTS,
                "merge_rule": "vendor/prepropess_data.py: mask[sep_mask==225] = enumerate(atts,1)",
                "images": manifest,
            },
            f,
            indent=2,
        )
    print("wrote", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
