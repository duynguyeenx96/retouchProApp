"""Downloads the BiSeNet CelebAMask-HQ checkpoint and pins its SHA-256.

docs/PLAN.md §6 points at zllrunning/face-parsing.PyTorch, whose README links
`79999_iter.pth` on Google Drive (id 154JgKpzCPW82qINcVieuPH3fZ2e0P812). Google
Drive is not a stable programmatic source, so this script prefers the Hugging Face
mirror `vivym/face-parsing-bisenet`. The two were downloaded side by side on
2026-09-04 and are **byte-identical** (same SHA-256, below), so the mirror is the
upstream artefact, not a re-export.

Usage: python fetch_model.py [--drive]
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, "models", "79999_iter.pth")

SHA256 = "468e13ca13a9b43cc0881a9f99083a430e9c0a38abd935431d1c28ee94b26567"
SIZE = 53_289_463

HF_URL = "https://huggingface.co/vivym/face-parsing-bisenet/resolve/main/79999_iter.pth"
DRIVE_URL = (
    "https://drive.usercontent.google.com/download"
    "?id=154JgKpzCPW82qINcVieuPH3fZ2e0P812&export=download"
)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    url = DRIVE_URL if "--drive" in sys.argv else HF_URL
    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    if not os.path.exists(DEST):
        print("downloading", url)
        subprocess.run(["curl", "-sL", "--max-time", "900", "-o", DEST, url], check=True)
    got = sha256(DEST)
    size = os.path.getsize(DEST)
    print(f"{DEST}\n  size   {size} (expected {SIZE})\n  sha256 {got}")
    if got != SHA256 or size != SIZE:
        print("MISMATCH — refusing to use this file")
        return 1
    print("  OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
