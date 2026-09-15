#!/usr/bin/env python3
"""An independent reference for RPEngine's `HairBoundary` trace.

`HairBoundary.swift` traces the outer boundary of the largest connected hair
region with a **Moore-neighbour walk** (breadth-first component labelling, then
an 8-neighbourhood ring walk with Jacob's stopping criterion). That code is
ours, so its doc comment promises it is "verified against something
independent". This script is that something, and it is deliberately a
*different* algorithm end to end:

  * components by **iterative label propagation** over whole NumPy arrays
    (labels start as the row-major index and are repeatedly min-ed with their
    four shifted neighbours until nothing changes) — no queue, no stack, no
    per-pixel traversal order, so a bug in the Swift BFS cannot be reproduced
    here by sharing a mistake;
  * the boundary as **per-row and per-column extremes** of that component —
    for each row the leftmost and rightmost member column, for each column the
    topmost and bottommost member row — which never walks a ring at all.

The two meet at a theorem rather than at an implementation: the leftmost member
of a row is reachable from outside the component by walking west, so it lies on
the component's **outer** boundary, and likewise for the other three extremes.
So every extreme this script reports must appear in the Swift ring, and the
ring's own per-row/column extremes must be exactly these numbers. That
comparison is what `HeadReshapeGeometryTests` runs. It is also why the
comparison is not "same set of boundary pixels": a hole inside the hair has a
boundary too, and the Swift trace deliberately returns only the outer ring.

Inputs
------
The 11 real a6300 frames parsed by the BiSeNet model in spike S2 (docs/ADR-0006),
as 512x512 class-index PNGs:

    Research/spikes/S2-face-parsing/a6300_upright/results/coreml_labels/*.png

`hair` is class 17 (`RPVision.FaceParsingClass.hair`). Class 18 is `hat`, and is
deliberately **not** included: a subject in a hat has no hair silhouette, which
is a documented limitation of the "Đầu" group rather than something to paper
over here.

Plus seven synthetic shapes built by rule below. They are emitted as run-length
rows in the JSON so the Swift test reconstructs the identical bitmap instead of
re-deriving one from a prose description of a circle.

Output
------
    Research/bench/p6-head-hairline-reference.json

Usage:  python3 Research/bench/hair-boundary-reference.py [--out PATH]
Needs:  numpy, pillow
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image

HAIR_CLASS = 17
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LABELS = os.path.join(
    REPO, "Research/spikes/S2-face-parsing/a6300_upright/results/coreml_labels"
)


# --- components ------------------------------------------------------------


def largest_component(member: np.ndarray) -> tuple[np.ndarray, int]:
    """(membership of the largest 4-connected component, number of components).

    Label propagation, not a traversal: every member pixel starts with its own
    row-major index as a label and each sweep replaces a label with the minimum
    of itself and its four neighbours' labels. Non-members are held at a
    sentinel larger than any real label. The fixpoint gives every component the
    smallest row-major index it contains, which is also exactly the pixel
    `HairBoundary.largestComponent` starts its trace from.
    """
    h, w = member.shape
    big = h * w + 1
    labels = np.where(member, np.arange(h * w).reshape(h, w), big)
    while True:
        previous = labels
        candidate = labels.copy()
        # north / south / west / east, each padded with the sentinel.
        candidate[1:, :] = np.minimum(candidate[1:, :], labels[:-1, :])
        candidate[:-1, :] = np.minimum(candidate[:-1, :], labels[1:, :])
        candidate[:, 1:] = np.minimum(candidate[:, 1:], labels[:, :-1])
        candidate[:, :-1] = np.minimum(candidate[:, :-1], labels[:, 1:])
        labels = np.where(member, candidate, big)
        if np.array_equal(labels, previous):
            break
    roots = labels[member]
    if roots.size == 0:
        return np.zeros_like(member), 0
    values, counts = np.unique(roots, return_counts=True)
    winner = values[int(np.argmax(counts))]
    return labels == winner, int(values.size)


def extremes(component: np.ndarray) -> dict:
    """Per-row and per-column extremes of a component."""
    h, w = component.shape
    rows = []
    for y in range(h):
        xs = np.flatnonzero(component[y])
        if xs.size:
            rows.append([y, int(xs[0]), int(xs[-1])])
    cols = []
    for x in range(w):
        ys = np.flatnonzero(component[:, x])
        if ys.size:
            cols.append([x, int(ys[0]), int(ys[-1])])
    return {"rows": rows, "cols": cols}


def describe(member: np.ndarray) -> dict:
    h, w = member.shape
    component, component_count = largest_component(member)
    total = int(member.sum())
    count = int(component.sum())
    result = {
        "size": [w, h],
        "mask_pixels": total,
        "component_pixels": count,
        "component_count": component_count,
        "largest_component_fraction": (count / total) if total else 0.0,
    }
    if count == 0:
        result["empty"] = True
        return result
    ys, xs = np.nonzero(component)
    result["bbox"] = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
    first = int(np.flatnonzero(component.reshape(-1))[0])
    result["start_pixel"] = [first % w, first // w]
    result["touches_edge"] = {
        "left": bool(component[:, 0].any()),
        "right": bool(component[:, w - 1].any()),
        "top": bool(component[0, :].any()),
        "bottom": bool(component[h - 1, :].any()),
    }
    result["edge_pixels"] = int(
        component[0, :].sum()
        + component[h - 1, :].sum()
        + component[:, 0].sum()
        + component[:, w - 1].sum()
        - component[0, 0]
        - component[0, w - 1]
        - component[h - 1, 0]
        - component[h - 1, w - 1]
    )
    result.update(extremes(component))
    return result


# --- synthetic shapes ------------------------------------------------------
#
# Every shape is a rule, and the rule is reproduced in the JSON as run-length
# rows so the Swift side builds the identical bitmap. The set covers the cases
# the trace can get wrong: a smooth convex ring, a hole, two components, a
# component cut by the frame edge, a single pixel, a one-pixel-wide bridge
# (where a Moore walk crosses the same pixel twice) and a concave comb (where
# per-column extremes and the ring disagree unless the trace really follows the
# outline).


def disc(w, h, cx, cy, r, into=None, value=True):
    grid = np.zeros((h, w), bool) if into is None else into
    ys, xs = np.mgrid[0:h, 0:w]
    hit = (xs - cx) ** 2 + (ys - cy) ** 2 <= r * r
    grid[hit] = value
    return grid


def synthetic_shapes() -> dict[str, np.ndarray]:
    shapes: dict[str, np.ndarray] = {}

    shapes["disc"] = disc(64, 64, 32, 32, 20)

    annulus = disc(64, 64, 32, 32, 24)
    disc(64, 64, 32, 32, 10, into=annulus, value=False)
    shapes["annulus"] = annulus

    blobs = disc(64, 64, 20, 32, 14)
    disc(64, 64, 52, 10, 5, into=blobs)
    shapes["two_blobs"] = blobs

    bar = np.zeros((48, 48), bool)
    bar[0:20, 0:30] = True  # touches the top and left edges
    shapes["clipped_bar"] = bar

    single = np.zeros((16, 16), bool)
    single[8, 5] = True
    shapes["single_pixel"] = single

    hourglass = np.zeros((40, 40), bool)
    hourglass[4:18, 6:20] = True
    hourglass[22:36, 20:34] = True
    # A one-pixel-wide 4-connected bridge: column 19 from the bottom of the
    # first square to the top row of the second, whose leftmost column is 20 and
    # therefore horizontally adjacent to (19, 22). A Moore walk has to go up and
    # back down this bridge, visiting each of its pixels twice.
    hourglass[18:23, 19] = True
    shapes["hourglass"] = hourglass

    comb = np.zeros((40, 48), bool)
    comb[6:16, 4:44] = True
    for x0 in (8, 22, 36):
        comb[16:30, x0 : x0 + 4] = True
    shapes["comb"] = comb

    return shapes


def rle(mask: np.ndarray) -> list[list[int]]:
    """One entry per row that has any member: [y, start, length, start, length…]."""
    out = []
    h, w = mask.shape
    for y in range(h):
        row = mask[y]
        if not row.any():
            continue
        runs = [y]
        x = 0
        while x < w:
            if row[x]:
                start = x
                while x < w and row[x]:
                    x += 1
                runs.extend([start, x - start])
            else:
                x += 1
        out.append(runs)
    return out


# --- main ------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out",
        default=os.path.join(REPO, "Research/bench/p6-head-hairline-reference.json"),
    )
    args = parser.parse_args()

    document = {
        "what": (
            "Independent reference for RPEngine HairBoundary: largest 4-connected "
            "component by NumPy label propagation, boundary as per-row/column "
            "extremes. Compared in RPEngineTests/HeadReshapeGeometryTests."
        ),
        "generator": "Research/bench/hair-boundary-reference.py",
        "numpy": np.__version__,
        "hair_class": HAIR_CLASS,
        "coverage_threshold": 128,
        "labels_dir": os.path.relpath(LABELS, REPO),
        "synthetic": [],
        "real": [],
    }

    for name, mask in sorted(synthetic_shapes().items()):
        entry = {"name": name, "rle": rle(mask)}
        entry.update(describe(mask))
        document["synthetic"].append(entry)

    if os.path.isdir(LABELS):
        for file in sorted(os.listdir(LABELS)):
            if not file.endswith(".png"):
                continue
            labels = np.array(Image.open(os.path.join(LABELS, file)))
            entry = {"image": file}
            entry.update(describe(labels == HAIR_CLASS))
            document["real"].append(entry)
    else:
        document["real_skipped"] = f"{LABELS} not present"

    # Written compact rather than pretty-printed: the per-row/column extremes of
    # eleven 512² frames are ~40 000 small integers, and an indented dump is
    # three quarters whitespace. This file is read by a test, not by a person —
    # the explanation is this script.
    with open(args.out, "w") as handle:
        json.dump(document, handle, separators=(",", ":"), sort_keys=False)
        handle.write("\n")
    print(f"wrote {args.out}")
    print(
        f"  {len(document['synthetic'])} synthetic shapes, "
        f"{len(document['real'])} real frames"
    )
    for entry in document["real"]:
        touches = entry.get("touches_edge", {})
        print(
            f"  {entry['image']}: hair={entry['mask_pixels']} "
            f"largest={entry['largest_component_fraction']:.4f} "
            f"components={entry['component_count']} "
            f"edges={''.join(k[0] for k, v in touches.items() if v) or '-'}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
