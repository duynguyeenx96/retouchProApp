/* =====================================================================
 *  skincore-js-fixture.js — regenerates
 *  Packages/RPEngine/Tests/RPEngineTests/SkinCoreJSFixture.swift
 *
 *  docs/PLAN.md §6.2 "Sửa da" needs a whole-frame skin mask, and
 *  .claude/agents/coder.md §"Reuse before writing" says the maths is the
 *  UXP panel's skincore.js ported "with identical numerics; verify against
 *  panelpts/research/eval.js outputs".
 *
 *  This is that verification, turned into something that runs in CI on a
 *  machine with no Node and no panelpts checkout: it executes the *shipped*
 *  skincore.js on a fixed synthetic frame and writes its inputs and outputs
 *  into a Swift file as base64. `SkinCoreTests` then runs the Swift port on
 *  the same bytes and requires an exact match — not "close", exact, because
 *  every step of the pipeline is integer or Double arithmetic that both
 *  languages perform identically.
 *
 *  The frame is synthetic rather than one of the four photos in
 *  panelpts/research/data/: it is 64x48 (9 KB of base64 in the Swift file
 *  instead of 800 KB) and it is *built* to exercise every branch —
 *      - two skin-toned ellipses far enough apart to be separate connected
 *        components, one of them big and one of them under the 2 % floor,
 *        so keepBigComponents actually drops something;
 *      - a wood/rattan patch, which the G-B yellowness penalty must pull
 *        down but the Kovac rules alone do not;
 *      - a deep-shadow skin patch, for the luminance knees at 90 / 135;
 *      - noise everywhere, so no two neighbouring pixels are equal and a
 *        box-blur off-by-one cannot hide.
 *  Coverage of the branches is asserted in the generated file's header
 *  comment (stats.learned must be true, componentsTotal > componentsKept).
 *
 *  Usage:
 *      node Scripts/skincore-js-fixture.js [path/to/panelpts]
 *  Default panelpts path: ../panelpts relative to this repo's parent.
 * ===================================================================== */

const fs = require("fs");
const path = require("path");

const REPO = path.resolve(__dirname, "..");
/* Walk up from the repo looking for a sibling panelpts checkout. More than one
   level because this repo is often checked out as a git worktree under
   .claude/worktrees/<name>/, three levels below the real parent directory. */
const candidates = process.argv[2]
    ? [path.resolve(process.argv[2])]
    : [1, 2, 3, 4].map(n => path.resolve(REPO, ...Array(n).fill(".."), "panelpts"));
const CORE = candidates
    .map(p => path.join(p, "RetouchProUXP", "skincore.js"))
    .find(fs.existsSync);
if (!CORE) {
    console.error(`skincore.js not found. Looked in:\n  ${candidates.join("\n  ")}\n` +
                  `Usage: node Scripts/skincore-js-fixture.js [path/to/panelpts]`);
    process.exit(1);
}
const core = require(CORE);

const W = 64, H = 48;

/* A tiny LCG so the frame is byte-identical on every machine and every Node
   version. Plain 32-bit integer maths; Math.imul keeps it exact. */
let seed = 20260911;
function rnd() {
    seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff;
    return seed;
}

function ellipse(x, y, cx, cy, rx, ry) {
    const dx = (x - cx) / rx, dy = (y - cy) / ry;
    return dx * dx + dy * dy <= 1;
}

const buf = new Uint8Array(W * H * 3);
for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
        let R, G, B;
        if (ellipse(x, y, 20, 20, 13, 16)) {
            R = 214; G = 168; B = 146;                    /* lit skin, big blob */
        } else if (ellipse(x, y, 54, 9, 2, 2)) {
            R = 208; G = 160; B = 138;                    /* skin speck, under the 2 % floor */
        } else if (ellipse(x, y, 46, 36, 10, 8)) {
            R = 121; G = 86; B = 71;                       /* skin deep in shadow */
        } else if (x > 40 && y < 20) {
            R = 196; G = 150; B = 96;                      /* rattan / wood: yellower than skin */
        } else {
            R = 62; G = 78; B = 96;                        /* cool background */
        }
        const n = (rnd() % 11) - 5;
        const i = (y * W + x) * 3;
        buf[i] = Math.max(0, Math.min(255, R + n));
        buf[i + 1] = Math.max(0, Math.min(255, G + ((rnd() % 11) - 5)));
        buf[i + 2] = Math.max(0, Math.min(255, B + ((rnd() % 11) - 5)));
    }
}

const res = core.classify({ buf, comp: 3, sw: W, sh: H }, { tolerance: 50 });
const mask = core.skinMaskSmall(res);

/* A spread of RGB triples for skinScore on its own, including every early
   return (R<=95, G<=40, B<=20, R<=G, R<=B, low saturation, outside the CbCr
   ellipse) and a run across the soft edge of the ellipse. */
const probes = [];
for (let i = 0; i < 96; i++) {
    probes.push([rnd() % 256, rnd() % 256, rnd() % 256]);
}
for (const t of [[255, 255, 255], [0, 0, 0], [96, 41, 21], [95, 40, 20],
                 [200, 200, 180], [220, 150, 120], [180, 120, 100],
                 [150, 110, 95], [130, 95, 80], [240, 200, 190],
                 [210, 160, 140], [100, 60, 40], [250, 128, 114]]) {
    probes.push(t);
}
const scores = probes.map(([r, g, b]) => core.skinScore(r, g, b));

const b64 = a => Buffer.from(a).toString("base64");
function wrap(s, indent) {
    const width = 92 - indent.length;
    const parts = [];
    for (let i = 0; i < s.length; i += width) parts.push(s.slice(i, i + width));
    return parts.map(p => `${indent}"${p}"`).join("\n            + ");
}

const st = res.stats;
if (!st.learned) throw new Error("fixture must exercise the back-projection branch");
if (!(st.componentsTotal > st.components)) {
    console.error("stats:", JSON.stringify(st));
    throw new Error("fixture must drop a component (the 2 % floor never fired)");
}

const swift = `// GENERATED by Scripts/skincore-js-fixture.js — do not hand-edit.
//
// The inputs and outputs of the **shipped** UXP panel maths,
// panelpts/RetouchProUXP/skincore.js, captured by running it under Node. It is
// the same file panelpts/research/eval.js scores, so pinning \`SkinCore\` to these
// bytes is what .claude/agents/coder.md §"Reuse before writing" asks for:
// "port to SkinCore.swift with identical numerics; verify against
// panelpts/research/eval.js outputs".
//
// Regenerate with:  node Scripts/skincore-js-fixture.js [path/to/panelpts]
//
// Branch coverage of the 64x48 frame below, asserted by the generator:
//   stats.learned        = ${st.learned}   (the CbCr back-projection ran)
//   componentsTotal      = ${st.componentsTotal}      (found)
//   componentsKept       = ${st.components}      (kept — so the 2 % floor dropped ${st.componentsTotal - st.components})
//   rawPct / finalPct    = ${st.rawPct} / ${st.finalPct}
//   gain                 = ${st.gain}
//
// Node ${process.version}.
enum SkinCoreJSFixture {
    static let width = ${W}
    static let height = ${H}

    /// Interleaved RGB, row-major, row 0 at the top — \`classify\`'s \`buf\`.
    static let imageBase64 =
        ${wrap(b64(buf), "").trimStart()}

    /// \`skinMaskSmall(classify(...))\`, i.e. the coverage map the panel writes
    /// into a layer mask. \`width * height\` bytes.
    static let maskBase64 =
        ${wrap(b64(mask), "").trimStart()}

    /// RGB triples fed to \`skinScore\` on its own.
    static let probes: [(Double, Double, Double)] = [
${probes.map(([r, g, b]) => `        (${r}, ${g}, ${b}),`).join("\n")}
    ]

    /// \`skinScore\` of each probe, from the JS.
    static let probeScores: [Int] = [
${(() => {
    const out = [];
    for (let i = 0; i < scores.length; i += 12) {
        out.push("        " + scores.slice(i, i + 12).join(", ") + ",");
    }
    return out.join("\n");
})()}
    ]

    // MARK: - classify() statistics, from the JS

    static let rawPercent = ${st.rawPct}
    static let finalPercent = ${st.finalPct}
    static let learned = ${st.learned}
    /// JS \`stats.learnedCb\` / \`learnedCr\` — the medians the back-projection
    /// learned, which is what \`SkinCore.Stats.medianCb\` / \`medianCr\` carry.
    static let learnedCb = ${st.learnedCb}
    static let learnedCr = ${st.learnedCr}
    static let componentsKept = ${st.components}
    static let componentsTotal = ${st.componentsTotal}
    static let gain = ${st.gain}
}
`;

const out = path.join(REPO, "Packages/RPEngine/Tests/RPEngineTests/SkinCoreJSFixture.swift");
fs.writeFileSync(out, swift);
console.log(`wrote ${out}`);
console.log(`  stats: raw ${st.rawPct}% final ${st.finalPct}% learned ${st.learned} ` +
            `components ${st.components}/${st.componentsTotal} gain ${st.gain}`);
