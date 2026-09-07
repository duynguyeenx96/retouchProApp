#!/usr/bin/env python
"""
S1 spike: convert MediaPipe's face_landmarks_detector.tflite (478 landmarks) to Core ML.

Why a hand-written converter instead of tf2onnx / onnx2torch:
the graph only uses 9 builtin ops (CONV_2D, DEPTHWISE_CONV_2D, PRELU, ADD, MAX_POOL_2D,
PAD, LOGISTIC, RESHAPE, DEQUANTIZE-of-constants). Emitting them directly into coremltools'
MIL builder is far fewer moving parts than a TF/ONNX/PyTorch round trip, and every op maps
1:1 so numerics are preserved (verified against the LiteRT interpreter in verify_coreml_vs_tflite.py).

Layout: TFLite feature maps are NHWC, Core ML/MIL convs are NCHW. Every rank-4 activation is
tracked in NCHW; weights are transposed on the way in; RESHAPE transposes back to NHWC first.

Usage:
    .venv/bin/python convert_tflite_to_coreml.py
"""
import os
import sys
import numpy as np
import tflite
from tflite.BuiltinOperator import BuiltinOperator
from tflite.BuiltinOptions import BuiltinOptions
from tflite.Conv2DOptions import Conv2DOptions
from tflite.DepthwiseConv2DOptions import DepthwiseConv2DOptions
from tflite.Pool2DOptions import Pool2DOptions
from tflite.TensorType import TensorType

import coremltools as ct
from coremltools.converters.mil import Builder as mb

HERE = os.path.dirname(os.path.abspath(__file__))
TFLITE = os.path.join(HERE, "models", "face_landmarks_detector.tflite")
OUT_DIR = os.path.join(HERE, "models")

OPNAMES = {v: k for k, v in BuiltinOperator.__dict__.items() if not k.startswith("_")}
NP_DTYPE = {
    TensorType.FLOAT32: np.float32,
    TensorType.FLOAT16: np.float16,
    TensorType.INT32: np.int32,
    TensorType.INT64: np.int64,
    TensorType.UINT8: np.uint8,
    TensorType.INT8: np.int8,
}
PAD_SAME, PAD_VALID = 0, 1
ACT_NONE, ACT_RELU, ACT_RELU_N1_TO_1, ACT_RELU6 = 0, 1, 2, 3


class TFLiteGraph:
    def __init__(self, path):
        self.buf = open(path, "rb").read()
        self.model = tflite.Model.GetRootAsModel(self.buf, 0)
        self.g = self.model.Subgraphs(0)
        self.opnames = [
            OPNAMES.get(self.model.OperatorCodes(i).BuiltinCode())
            for i in range(self.model.OperatorCodesLength())
        ]

    def tensor(self, i):
        return self.g.Tensors(i)

    def name(self, i):
        return self.tensor(i).Name().decode()

    def shape(self, i):
        return [int(x) for x in self.tensor(i).ShapeAsNumpy()]

    def const(self, i):
        """Return numpy array for a tensor backed by a buffer, else None."""
        t = self.tensor(i)
        b = self.model.Buffers(t.Buffer())
        if b.DataLength() == 0:
            return None
        raw = b.DataAsNumpy().tobytes()
        dt = NP_DTYPE[t.Type()]
        return np.frombuffer(raw, dtype=dt).reshape(self.shape(i)).copy()


def apply_activation(x, act, name):
    if act == ACT_NONE:
        return x
    if act == ACT_RELU:
        return mb.relu(x=x, name=name)
    if act == ACT_RELU6:
        return mb.relu6(x=x, name=name)
    raise NotImplementedError("fused activation %d" % act)


def build(tg):
    g = tg.g
    in_idx = int(g.Inputs(0))
    n, h, w, c = tg.shape(in_idx)
    assert (n, c) == (1, 3), tg.shape(in_idx)

    # vars[i] = (mil_var, layout) with layout in {"nchw", "raw"}
    vars_ = {}

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, h, w))])
    def prog(image):
        vars_[in_idx] = (image, "nchw")

        def get(i):
            if i in vars_:
                return vars_[i]
            k = tg.const(i)
            if k is None:
                raise RuntimeError("tensor %d (%s) has no producer and no buffer" % (i, tg.name(i)))
            return (k, "const")

        for oi in range(g.OperatorsLength()):
            op = g.Operators(oi)
            kind = tg.opnames[op.OpcodeIndex()]
            ins = [int(x) for x in op.InputsAsNumpy()]
            outs = [int(x) for x in op.OutputsAsNumpy()]
            nm = "op%03d_%s" % (oi, kind.lower())

            if kind == "DEQUANTIZE":
                k = tg.const(ins[0])
                if k is None:
                    raise RuntimeError("runtime DEQUANTIZE not supported (op %d)" % oi)
                vars_[outs[0]] = (k.astype(np.float32), "const")

            elif kind == "CONV_2D":
                o = Conv2DOptions()
                o.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
                x = get(ins[0])[0]
                wt = get(ins[1])[0]          # [Cout, kh, kw, Cin]
                bias = get(ins[2])[0].astype(np.float32)
                wt = np.transpose(wt.astype(np.float32), (0, 3, 1, 2))  # -> [Cout, Cin, kh, kw]
                y = mb.conv(
                    x=x, weight=wt, bias=bias,
                    strides=[o.StrideH(), o.StrideW()],
                    pad_type="same" if o.Padding() == PAD_SAME else "valid",
                    dilations=[o.DilationHFactor(), o.DilationWFactor()],
                    groups=1, name=nm,
                )
                y = apply_activation(y, o.FusedActivationFunction(), nm + "_act")
                vars_[outs[0]] = (y, "nchw")

            elif kind == "DEPTHWISE_CONV_2D":
                o = DepthwiseConv2DOptions()
                o.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
                x = get(ins[0])[0]
                wt = get(ins[1])[0]          # [1, kh, kw, Cout]
                bias = get(ins[2])[0].astype(np.float32)
                cout = wt.shape[3]
                mult = o.DepthMultiplier()
                assert mult == 1, "depth_multiplier %d unsupported" % mult
                wt = np.transpose(wt.astype(np.float32), (3, 0, 1, 2))  # -> [Cout, 1, kh, kw]
                y = mb.conv(
                    x=x, weight=wt, bias=bias,
                    strides=[o.StrideH(), o.StrideW()],
                    pad_type="same" if o.Padding() == PAD_SAME else "valid",
                    dilations=[o.DilationHFactor(), o.DilationWFactor()],
                    groups=cout, name=nm,
                )
                y = apply_activation(y, o.FusedActivationFunction(), nm + "_act")
                vars_[outs[0]] = (y, "nchw")

            elif kind == "PRELU":
                x = get(ins[0])[0]
                alpha = get(ins[1])[0].astype(np.float32).reshape(-1)
                vars_[outs[0]] = (mb.prelu(x=x, alpha=alpha, name=nm), "nchw")

            elif kind == "ADD":
                a, la = get(ins[0])
                b, lb = get(ins[1])
                vars_[outs[0]] = (mb.add(x=a, y=b, name=nm), la if la != "const" else lb)

            elif kind == "MAX_POOL_2D":
                o = Pool2DOptions()
                o.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
                x = get(ins[0])[0]
                y = mb.max_pool(
                    x=x,
                    kernel_sizes=[o.FilterHeight(), o.FilterWidth()],
                    strides=[o.StrideH(), o.StrideW()],
                    pad_type="same" if o.Padding() == PAD_SAME else "valid",
                    name=nm,
                )
                y = apply_activation(y, o.FusedActivationFunction(), nm + "_act")
                vars_[outs[0]] = (y, "nchw")

            elif kind == "PAD":
                x, layout = get(ins[0])
                pads = get(ins[1])[0].astype(np.int32)   # [[n],[h],[w],[c]] in NHWC
                assert layout == "nchw" and pads.shape == (4, 2)
                assert pads[0].tolist() == [0, 0], "batch padding unsupported"
                cpad, hpad, wpad = pads[3], pads[1], pads[2]
                y = x
                if hpad.any() or wpad.any():
                    # MIL pad() pads the trailing N dims; here that is H and W.
                    y = mb.pad(
                        x=y,
                        pad=[int(hpad[0]), int(hpad[1]), int(wpad[0]), int(wpad[1])],
                        mode="constant", constant_val=0.0, name=nm + "_hw")
                if cpad.any():
                    # Channel padding via concat of an explicit zero block. mb.pad on
                    # the channel axis loads fine on macOS but the iOS Simulator's Core
                    # ML runtime rejects the resulting model.mil with error -7, so the
                    # zero block is materialised instead.
                    n_, h_, w_, _c = tg.shape(ins[0])  # PAD input is still NHWC in TFLite
                    parts = []
                    if int(cpad[0]):
                        parts.append(np.zeros((n_, int(cpad[0]), h_, w_), dtype=np.float32))
                    parts.append(y)
                    if int(cpad[1]):
                        parts.append(np.zeros((n_, int(cpad[1]), h_, w_), dtype=np.float32))
                    y = mb.concat(values=parts, axis=1, name=nm + "_cpad")
                vars_[outs[0]] = (mb.identity(x=y, name=nm), "nchw")

            elif kind == "LOGISTIC":
                x, layout = get(ins[0])
                vars_[outs[0]] = (mb.sigmoid(x=x, name=nm), layout)

            elif kind == "RESHAPE":
                x, layout = get(ins[0])
                target = get(ins[1])[0].astype(np.int32).tolist()
                if layout == "nchw":
                    x = mb.transpose(x=x, perm=[0, 2, 3, 1], name=nm + "_nhwc")
                vars_[outs[0]] = (mb.reshape(x=x, shape=target, name=nm), "raw")

            else:
                raise NotImplementedError("op %s at %d" % (kind, oi))

        # graph outputs, in TFLite order: Identity (1434), Identity_1 (score logit), Identity_2 (sigmoid)
        out_idx = [int(g.Outputs(i)) for i in range(g.OutputsLength())]
        lm, lm_layout = vars_[out_idx[0]]
        if lm_layout == "nchw":
            lm = mb.transpose(x=lm, perm=[0, 2, 3, 1], name="landmarks_nhwc")
        landmarks = mb.reshape(x=lm, shape=[478, 3], name="landmarks")

        # Identity_1 is the face-presence logit; MediaPipe's TensorsToFloats step
        # applies the sigmoid, so do it here. (Identity_2 is a second scalar head
        # whose meaning is not documented -- it reads ~1e-4 on clean face crops
        # where presence is ~1.0 -- so it is dropped rather than mislabelled.)
        logit, logit_layout = vars_[out_idx[1]]
        if logit_layout == "nchw":
            logit = mb.transpose(x=logit, perm=[0, 2, 3, 1], name="score_nhwc")
        score = mb.reshape(x=mb.sigmoid(x=logit, name="score_sigmoid"), shape=[1], name="score")
        return landmarks, score

    return prog


def check_variant_ordering(variants):
    """Raise unless at most one variant takes an image input, and it is last.

    `prog` is built ONCE in `main` and `ct.convert` **mutates** the MIL program it
    is handed: an ImageType input prepends the scale/bias ops to the graph. So
    converting the same `prog` a second time with an image input would apply the
    1/255 scaling twice. That bug is not hypothetical — it happened in
    convert_blazeface_to_coreml.py, where the doubly-normalised detector found no
    face in any of the 31 test frames, and it is invisible in the model spec
    unless you count the ops (see that file's `main`, which fixes it by rebuilding
    `prog` per variant).

    Here the defence is ordering alone, so pin it. If a future edit needs more
    than one image-input variant, do not relax this check — move the
    `prog = build(tg)` call inside the loop, the way the BlazeFace script does.

    A module-level function rather than an inline assert in `main` so
    `test_convert_invariant.py` can exercise it without a TFLite file, a GPU or a
    30-second conversion.

    `variants` is a list of `(precision, stem, input_kind)`; `input_kind` is
    `"image"` or `None`.
    """
    image_variants = [i for i, v in enumerate(variants) if v[2] == "image"]
    assert image_variants in ([], [len(variants) - 1]), (
        "at most one image-input variant is allowed and it must be last "
        "(ct.convert mutates `prog`); got indices %r of %d variants"
        % (image_variants, len(variants))
    )


def main():
    tg = TFLiteGraph(TFLITE)
    prog = build(tg)
    # Three artefacts:
    #   *_fp32 / *_fp16      MLMultiArray input, used for exact numeric comparison against TFLite
    #   FaceLandmark478      fp16 + image input, the one the Swift harness / RPVision loads
    variants = [
        (ct.precision.FLOAT32, "FaceLandmark478_fp32", None),
        (ct.precision.FLOAT16, "FaceLandmark478_fp16", None),
        # INVARIANT — must stay last, and must be the only image-input variant.
        (ct.precision.FLOAT16, "FaceLandmark478", "image"),
    ]
    check_variant_ordering(variants)
    for precision, stem, input_kind in variants:
        inputs = None
        if input_kind == "image":
            inputs = [ct.ImageType(name="image", shape=(1, 3, 256, 256),
                                   scale=1.0 / 255.0, color_layout=ct.colorlayout.RGB)]
        m = ct.convert(
            prog,
            inputs=inputs,
            convert_to="mlprogram",
            compute_precision=precision,
            minimum_deployment_target=ct.target.iOS18,
            compute_units=ct.ComputeUnit.ALL,
        )
        m.author = "converted from MediaPipe face_landmarks_detector.tflite"
        m.short_description = (
            "MediaPipe Face Landmarker v2 mesh model. Input: 256x256 RGB face crop. "
            "Output landmarks: 478x3 in crop pixel coords (x,y in 0..256, z relative depth); "
            "score: face presence in [0,1]."
        )
        m.input_description["image"] = (
            "RGB face crop 256x256" if input_kind == "image"
            else "RGB face crop, NCHW 1x3x256x256, values scaled to [0,1]"
        )
        path = os.path.join(OUT_DIR, "%s.mlpackage" % stem)
        m.save(path)
        print("saved", path)


if __name__ == "__main__":
    main()
