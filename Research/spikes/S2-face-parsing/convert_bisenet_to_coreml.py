"""BiSeNet (79999_iter.pth) -> Core ML.

Unlike spike S1 (a TFLite flatbuffer, hand-translated to MIL — docs/ADR-0005),
this checkpoint *is* a PyTorch model, so coremltools' supported
`torch.jit.trace` -> MIL path is a single hop and is the right tool. See
docs/ADR-0006-face-parsing-model-conversion.md.

Three artefacts, mirroring S1's shape:

  FaceParsing19.mlpackage             fp16, 512x512 RGB *image* in,
                                      int32 `labels` [1,512,512] out (argmax).
                                      The product/bench path.
  FaceParsing19_logits_fp32.mlpackage fp32, [1,3,512,512] MultiArray in,
  FaceParsing19_logits_fp16.mlpackage fp16, same, `logits` [1,19,512,512] out.
                                      Only used by verify_coreml_vs_torch.py, so
                                      "did the conversion change the network" is
                                      answerable separately from "is the model
                                      any good".

Preprocessing is folded into the graph (bisenet.NormalisedBiSeNet): the model
takes RGB 0-255 and does `(x/255 - imagenet_mean) / imagenet_std` itself. A Core ML
`ImageType` can only apply one scalar `scale`, and the ImageNet std is per-channel,
so doing it outside would need three separate multiplies in every caller — one more
place for the Swift side to disagree with the Python reference.

Usage: python convert_bisenet_to_coreml.py
"""

from __future__ import annotations

import json
import os

import coremltools as ct
import numpy as np
import torch

from bisenet import ArgmaxBiSeNet, INPUT_SIZE, LABELS, NormalisedBiSeNet, load_bisenet

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKPOINT = os.path.join(HERE, "models", "79999_iter.pth")
S = INPUT_SIZE


def trace(module: torch.nn.Module) -> torch.jit.ScriptModule:
    module.eval()
    example = torch.rand(1, 3, S, S) * 255.0
    with torch.no_grad():
        return torch.jit.trace(module, example)


def convert_logits(net, precision, path):
    traced = trace(NormalisedBiSeNet(net))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 3, S, S), dtype=np.float32)],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.save(path)
    print("wrote", path)
    return mlmodel


def convert_image(net, path):
    traced = trace(ArgmaxBiSeNet(net))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, S, S),
                color_layout=ct.colorlayout.RGB,
                scale=1.0,
                bias=[0.0, 0.0, 0.0],
            )
        ],
        outputs=[ct.TensorType(name="labels", dtype=np.int32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    spec = mlmodel.get_spec()
    mlmodel.short_description = (
        "BiSeNet face parsing, CelebAMask-HQ 19 classes "
        "(zllrunning/face-parsing.PyTorch 79999_iter.pth). "
        "Input: 512x512 RGB, 0-255, ImageNet normalisation applied inside the graph. "
        "Output 'labels': int32 [1,512,512] class index per pixel."
    )
    mlmodel.user_defined_metadata["rp.labels"] = json.dumps(LABELS)
    mlmodel.user_defined_metadata["rp.source"] = (
        "https://github.com/zllrunning/face-parsing.PyTorch 79999_iter.pth "
        "sha256 468e13ca13a9b43cc0881a9f99083a430e9c0a38abd935431d1c28ee94b26567"
    )
    mlmodel.user_defined_metadata["rp.spike"] = "S2-face-parsing"
    mlmodel.save(path)
    print("wrote", path, "outputs:", [o.name for o in spec.description.output])
    return mlmodel


def main() -> int:
    net = load_bisenet(CHECKPOINT)
    print("loaded", CHECKPOINT)
    n_params = sum(p.numel() for p in net.parameters())
    print(f"parameters: {n_params:,}")

    out = os.path.join(HERE, "models")
    convert_logits(net, ct.precision.FLOAT32, os.path.join(out, "FaceParsing19_logits_fp32.mlpackage"))
    convert_logits(net, ct.precision.FLOAT16, os.path.join(out, "FaceParsing19_logits_fp16.mlpackage"))
    convert_image(net, os.path.join(out, "FaceParsing19.mlpackage"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
