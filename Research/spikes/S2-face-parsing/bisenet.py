"""Loads zllrunning/face-parsing.PyTorch's BiSeNet exactly as upstream defines it.

`vendor/model.py` and `vendor/resnet.py` are byte-identical copies of the upstream
files (MIT, `vendor/LICENSE`); their SHA-256s are recorded in S2-face-parsing.md.
Nothing here edits them — the only adjustment is stubbing out
`torch.utils.model_zoo.load_url`, because `Resnet18.init_weight()` fetches the
ImageNet resnet18 weights that we immediately overwrite with the CelebAMask-HQ
checkpoint. Without the stub the conversion needs the network and is not
deterministic.

Class indices come from upstream `vendor/prepropess_data.py`, which is the script
that produced the training labels: `enumerate(atts, 1)` over
    skin l_brow r_brow l_eye r_eye eye_g l_ear r_ear ear_r
    nose mouth u_lip l_lip neck neck_l cloth hair hat
with 0 = background. Any other ordering found on the internet for "CelebAMask-HQ
19 classes" does not describe *this* checkpoint.
"""

from __future__ import annotations

import os
import sys

import torch
import torch.utils.model_zoo

VENDOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor")

# Class index -> label, straight out of vendor/prepropess_data.py.
ATTS = [
    "skin", "l_brow", "r_brow", "l_eye", "r_eye", "eye_g", "l_ear", "r_ear",
    "ear_r", "nose", "mouth", "u_lip", "l_lip", "neck", "neck_l", "cloth",
    "hair", "hat",
]
LABELS = ["background"] + ATTS
assert len(LABELS) == 19

# The three groups the plan's pass bar names (docs/PLAN.md §3, S2).
GROUPS = {
    "skin": [LABELS.index("skin")],
    "hair": [LABELS.index("hair")],
    "eye": [LABELS.index("l_eye"), LABELS.index("r_eye")],
}

# vendor/test.py: resize to 512x512 bilinear, ToTensor, Normalize(imagenet).
INPUT_SIZE = 512
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)


def _import_upstream():
    if VENDOR not in sys.path:
        sys.path.insert(0, VENDOR)
    import model as upstream_model  # noqa: PLC0415  (vendor/model.py)

    return upstream_model.BiSeNet


def load_bisenet(checkpoint: str, n_classes: int = 19) -> "torch.nn.Module":
    BiSeNet = _import_upstream()
    # The stub has to wrap *construction*, not the import: Resnet18.init_weight()
    # runs in __init__.
    original = torch.utils.model_zoo.load_url
    torch.utils.model_zoo.load_url = lambda *a, **k: {}
    try:
        net = BiSeNet(n_classes=n_classes)
    finally:
        torch.utils.model_zoo.load_url = original
    state = torch.load(checkpoint, map_location="cpu", weights_only=True)
    net.load_state_dict(state, strict=True)  # strict: any key drift is a hard error
    net.eval()
    return net


class NormalisedBiSeNet(torch.nn.Module):
    """BiSeNet with upstream's preprocessing folded into the graph.

    Takes RGB in [0, 255] (what a Core ML image input hands over) and returns the
    primary 19-channel logit map only. `conv_out16` / `conv_out32` are deep
    supervision heads used during training; upstream inference uses `net(img)[0]`.
    """

    def __init__(self, net: "torch.nn.Module"):
        super().__init__()
        self.net = net
        scale = torch.tensor([1.0 / (255.0 * s) for s in STD]).view(1, 3, 1, 1)
        bias = torch.tensor([-m / s for m, s in zip(MEAN, STD)]).view(1, 3, 1, 1)
        self.register_buffer("scale", scale)
        self.register_buffer("bias", bias)

    def forward(self, x):
        return self.net(x * self.scale + self.bias)[0]


class ArgmaxBiSeNet(NormalisedBiSeNet):
    """Same, but returns the per-pixel class index (what the masks need)."""

    def forward(self, x):
        logits = super().forward(x)
        return torch.argmax(logits, dim=1, keepdim=False).to(torch.int32)
