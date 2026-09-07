#!/usr/bin/env python
"""
Phase 2 prerequisite (docs/PLAN.md §3, "Từ S1"): convert MediaPipe's
blaze_face_short_range.tflite (the face *detector*) to Core ML.

S1 measured that feeding Apple Vision's face box straight into the 478-point mesh
costs 1.399 px mean error on the user's real a6300 frames (bar: < 1 px), because
Vision's ROI differs from BlazeFace's in size, centre *and* roll. The fix the spike
report prescribes is a two-stage detector: Vision locates the face roughly, a
face-centred crop is handed to BlazeFace, and BlazeFace's box + eye keypoints build
the ROI the mesh model was trained for.

This script is the same hand-written TFLite-flatbuffer -> MIL translation as
`convert_tflite_to_coreml.py` (see docs/ADR-0005 for why not tf2onnx). It reuses
that file's `TFLiteGraph` reader and activation helper verbatim, and adds the three
ops the detector graph uses that the mesh graph does not:

    RELU            standalone (the mesh model only ever fuses it)
    CONCATENATION   axis in NHWC terms, on already-flattened rank-3 tensors
    RESHAPE         with `new_shape` in the builtin options instead of a 2nd input

Op histogram of the detector graph: DEQUANTIZE 74 (constant fp16 weights),
CONV_2D 21, RELU 17, DEPTHWISE_CONV_2D 16, ADD 16, PAD 11 (all channel-axis, i.e.
the residual zero-pad), RESHAPE 4, MAX_POOL_2D 3, CONCATENATION 2.

Outputs of the graph, unchanged from TFLite:
    regressors      1 x 896 x 16   raw box + 6 keypoint offsets per anchor
    classificators  1 x 896 x 1    raw score **logit** (no sigmoid in the graph)

The anchor decode, sigmoid, score clipping and weighted NMS are deliberately *not*
folded in: MediaPipe does them in `TensorsToDetectionsCalculator` on the CPU, they
are a few hundred microseconds of scalar maths, and keeping them in Swift means
`BlazeFaceDecoder` can be unit-tested without Core ML.

Usage:
    .venv/bin/python convert_blazeface_to_coreml.py
"""
import os

import numpy as np
import tflite
from tflite.ConcatenationOptions import ConcatenationOptions
from tflite.Conv2DOptions import Conv2DOptions
from tflite.DepthwiseConv2DOptions import DepthwiseConv2DOptions
from tflite.Pool2DOptions import Pool2DOptions
from tflite.ReshapeOptions import ReshapeOptions

import coremltools as ct
from coremltools.converters.mil import Builder as mb

from convert_tflite_to_coreml import TFLiteGraph, apply_activation, PAD_SAME

HERE = os.path.dirname(os.path.abspath(__file__))
TFLITE = os.path.join(HERE, "models", "blaze_face_short_range.tflite")
OUT_DIR = os.path.join(HERE, "models")
SIDE = 128


def build(tg):
    g = tg.g
    in_idx = int(g.Inputs(0))
    n, h, w, c = tg.shape(in_idx)
    assert (n, h, w, c) == (1, SIDE, SIDE, 3), tg.shape(in_idx)

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
                wt = get(ins[1])[0]  # [Cout, kh, kw, Cin]
                bias = get(ins[2])[0].astype(np.float32)
                wt = np.transpose(wt.astype(np.float32), (0, 3, 1, 2))
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
                wt = get(ins[1])[0]  # [1, kh, kw, Cout]
                bias = get(ins[2])[0].astype(np.float32)
                cout = wt.shape[3]
                assert o.DepthMultiplier() == 1, "depth_multiplier %d unsupported" % o.DepthMultiplier()
                wt = np.transpose(wt.astype(np.float32), (3, 0, 1, 2))
                y = mb.conv(
                    x=x, weight=wt, bias=bias,
                    strides=[o.StrideH(), o.StrideW()],
                    pad_type="same" if o.Padding() == PAD_SAME else "valid",
                    dilations=[o.DilationHFactor(), o.DilationWFactor()],
                    groups=cout, name=nm,
                )
                y = apply_activation(y, o.FusedActivationFunction(), nm + "_act")
                vars_[outs[0]] = (y, "nchw")

            elif kind == "RELU":
                x, layout = get(ins[0])
                vars_[outs[0]] = (mb.relu(x=x, name=nm), layout)

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
                pads = get(ins[1])[0].astype(np.int32)
                assert layout == "nchw" and pads.shape == (4, 2)
                assert pads[0].tolist() == [0, 0], "batch padding unsupported"
                cpad, hpad, wpad = pads[3], pads[1], pads[2]
                y = x
                if hpad.any() or wpad.any():
                    y = mb.pad(
                        x=y,
                        pad=[int(hpad[0]), int(hpad[1]), int(wpad[0]), int(wpad[1])],
                        mode="constant", constant_val=0.0, name=nm + "_hw")
                if cpad.any():
                    # Same iOS-Simulator workaround as the mesh converter: mb.pad on
                    # the channel axis produces a model.mil the Simulator's Core ML
                    # runtime rejects with error -7. Materialise the zero block.
                    n_, h_, w_, _c = tg.shape(ins[0])
                    parts = []
                    if int(cpad[0]):
                        parts.append(np.zeros((n_, int(cpad[0]), h_, w_), dtype=np.float32))
                    parts.append(y)
                    if int(cpad[1]):
                        parts.append(np.zeros((n_, int(cpad[1]), h_, w_), dtype=np.float32))
                    y = mb.concat(values=parts, axis=1, name=nm + "_cpad")
                vars_[outs[0]] = (mb.identity(x=y, name=nm), "nchw")

            elif kind == "RESHAPE":
                x, layout = get(ins[0])
                if len(ins) > 1 and tg.const(ins[1]) is not None:
                    target = tg.const(ins[1]).astype(np.int32).tolist()
                else:
                    # The detector graph carries the target in the builtin options
                    # rather than as a second input tensor.
                    o = ReshapeOptions()
                    o.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
                    target = [int(v) for v in o.NewShapeAsNumpy()]
                if layout == "nchw":
                    x = mb.transpose(x=x, perm=[0, 2, 3, 1], name=nm + "_nhwc")
                vars_[outs[0]] = (mb.reshape(x=x, shape=target, name=nm), "raw")

            elif kind == "CONCATENATION":
                o = ConcatenationOptions()
                o.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
                parts = [get(i) for i in ins]
                layouts = {l for _, l in parts}
                # Both concats in this graph join rank-3 [1, N, C] tensors that have
                # already been reshaped out of NHWC, so the TFLite axis needs no
                # NCHW remapping. Assert rather than assume.
                assert layouts == {"raw"}, "concat on %s layout not supported" % layouts
                axis = int(o.Axis())
                y = mb.concat(values=[p for p, _ in parts], axis=axis, name=nm)
                y = apply_activation(y, o.FusedActivationFunction(), nm + "_act")
                vars_[outs[0]] = (y, "raw")

            else:
                raise NotImplementedError("op %s at %d" % (kind, oi))

        # TFLite output order: regressors [1,896,16], classificators [1,896,1].
        out_idx = [int(g.Outputs(i)) for i in range(g.OutputsLength())]
        reg, reg_layout = vars_[out_idx[0]]
        cls, cls_layout = vars_[out_idx[1]]
        assert reg_layout == "raw" and cls_layout == "raw"
        regressors = mb.reshape(x=reg, shape=[896, 16], name="regressors")
        # No sigmoid here on purpose: MediaPipe clips the logit to +-100 *before*
        # the sigmoid (score_clipping_thresh: 100), and doing that in Swift keeps
        # the clip and the threshold in one readable place.
        classificators = mb.reshape(x=cls, shape=[896], name="score_logits")
        return regressors, classificators

    return prog


def main():
    tg = TFLiteGraph(TFLITE)
    # Same three-artefact shape as the mesh conversion:
    #   *_fp32 / *_fp16   MultiArray input, for the exact numeric check vs TFLite
    #   BlazeFaceShortRange  fp16 + image input, the one RPVision loads
    variants = [
        (ct.precision.FLOAT32, "BlazeFaceShortRange_fp32", None),
        (ct.precision.FLOAT16, "BlazeFaceShortRange_fp16", None),
        (ct.precision.FLOAT16, "BlazeFaceShortRange", "image"),
        # Image-input fp32 as well, so the end-to-end harness can answer "does the
        # fp16 detector cost landmark accuracy" with a control run instead of an
        # argument. The MultiArray builds above cannot be used for that: RPVision
        # hands the model a CVPixelBuffer.
        (ct.precision.FLOAT32, "BlazeFaceShortRange_fp32_image", "image"),
    ]
    for precision, stem, input_kind in variants:
        # Rebuild the MIL program per variant. `ct.convert` **mutates** the program
        # it is given: an ImageType input prepends the scale/bias `mul`+`add` pair to
        # the graph, so converting the same `prog` twice with an image input applies
        # the [-1,1] normalisation twice. Caught by the end-to-end harness — the
        # second image build detected no face in any of the 31 test frames — and it
        # is invisible in the model spec unless you count the ops.
        prog = build(tg)
        inputs = None
        if input_kind == "image":
            # MediaPipe's ImageToTensorCalculator for this graph uses
            # output_tensor_float_range { min: -1.0 max: 1.0 }, i.e. x/127.5 - 1.
            inputs = [ct.ImageType(name="image", shape=(1, 3, SIDE, SIDE),
                                   scale=2.0 / 255.0, bias=[-1.0, -1.0, -1.0],
                                   color_layout=ct.colorlayout.RGB)]
        m = ct.convert(
            prog,
            inputs=inputs,
            convert_to="mlprogram",
            compute_precision=precision,
            minimum_deployment_target=ct.target.iOS18,
            compute_units=ct.ComputeUnit.ALL,
        )
        m.author = "converted from MediaPipe blaze_face_short_range.tflite"
        m.short_description = (
            "MediaPipe BlazeFace (short range) detector. Input: 128x128 RGB. "
            "regressors: 896x16 raw anchor offsets (box cx,cy,w,h then 6 keypoints, "
            "x before y); score_logits: 896 raw logits, apply clip(+-100)+sigmoid."
        )
        m.input_description["image"] = (
            "RGB image 128x128" if input_kind == "image"
            else "RGB image, NCHW 1x3x128x128, values scaled to [-1,1]"
        )
        m.user_defined_metadata["rp.source"] = (
            "blaze_face_short_range.tflite "
            "sha256:b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f")
        path = os.path.join(OUT_DIR, "%s.mlpackage" % stem)
        m.save(path)
        print("saved", path)


if __name__ == "__main__":
    main()
