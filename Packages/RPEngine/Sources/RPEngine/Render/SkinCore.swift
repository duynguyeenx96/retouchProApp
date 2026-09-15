import Foundation

/// The skin-colour classifier from the UXP panel, ported to Swift with the
/// **same numerics**.
///
/// Source: `panelpts/RetouchProUXP/skincore.js` (`classify`, `skinScore`,
/// `boxBlur`, `areaDown`, `keepBigComponents`, `median`, `skinMaskSmall`). That
/// file is the one the panel shipped *and* the one `panelpts/research/eval.js`
/// scored, so porting it — rather than inventing thresholds — is what
/// `.claude/agents/coder.md` §"Reuse before writing" asks for. Every constant
/// below (the Kovac RGB rules, the CbCr ellipse centre 102/153 with radii 28/22,
/// the 1.35 distance cut-off, the ×1.6 gain, the 0.35 back-projection gamma, the
/// 135/90/45 luminance knees, the 6/12 yellowness knee, the 2 % component floor,
/// the top-5 % normalisation) is transcribed, not re-derived.
///
/// ## What this is for (docs/PLAN.md §6.2 "Sửa da")
/// The eight "Da" sliders drive a mask that comes from BiSeNet face parsing,
/// which only runs on a **crop around the face**. On a beauty portrait that
/// leaves smoothed, evened face skin next to untouched neck / shoulder / arm
/// skin. This classifier produces the *whole-frame* skin coverage those same
/// slider values are then applied through — see ``BodySkinMask`` for the
/// `RenderMask` wrapper and ``SkinRenderNode`` for the union.
///
/// It is classical CV on purpose: colour thresholds plus a per-image
/// back-projection, no Core ML model, no new download, no new 150 MB of weights.
///
/// ## What was deliberately left out of the port
/// * **`ps` (Photoshop "Skin Tones") and `subj` (subject mask) priors.** There is
///   no Photoshop here, and the person-segmentation prior is docs/PLAN.md §6.1
///   ("Khoá nền", `VNGeneratePersonSegmentationRequest`), which the §6.2 row
///   itself calls an *optional v2 upgrade* rather than a blocker. Both enter
///   `classify` as per-pixel multipliers, so adding them later is a multiply on
///   ``Result/coverage`` and changes nothing else here.
/// * **The texture penalty** (`TEXTURE` / `texturePenalty`). It is
///   `enabled: false` in skincore.js — the panel shipped it off, with the comment
///   that it had no ground truth — so shipping it on here would be shipping an
///   unmeasured change. The functions it needs are not ported; if it is ever
///   wanted, it multiplies ``Result/coverage`` in exactly the same place.
///
/// Pure Swift: no Metal, no Core Graphics, no platform types. It runs in a unit
/// test on a machine with no GPU, which is how the IoU number in
/// `Research/bench/p6-skin-sync-*.json` is produced.
public enum SkinCore {

    // MARK: - Per-pixel score

    /// "How skin-like is this RGB", 0…255 — skincore.js `skinScore`.
    ///
    /// Kovac's RGB rules as a hard gate, then a soft fall-off with distance from
    /// the centre of the CbCr skin ellipse, so the edge of the decision is a
    /// ramp rather than a cut.
    ///
    /// - Parameters: 0…255 channel values.
    public static func skinScore(_ red: Double, _ green: Double, _ blue: Double) -> Int {
        let mx = max(red, max(green, blue))
        let mn = min(red, min(green, blue))
        if red <= 95 || green <= 40 || blue <= 20 { return 0 }
        if red <= green || red <= blue { return 0 }
        if (mx - mn) <= 15 { return 0 }

        let cb = 128 - 0.168736 * red - 0.331264 * green + 0.5 * blue
        let cr = 128 + 0.5 * red - 0.418688 * green - 0.081312 * blue

        let dCb = abs(cb - 102) / 28  // centre 102, radius 28
        let dCr = abs(cr - 153) / 22  // centre 153, radius 22
        let dist = (dCb * dCb + dCr * dCr).squareRoot()
        if dist >= 1.35 { return 0 }

        let rg = min(1, abs(red - green) / 22)  // small |R-G| → less certain
        let s = (1 - min(1, dist / 1.35)) * rg
        return jsRound(255 * min(1, s * 1.6))
    }

    // MARK: - Options

    public struct Options: Sendable, Equatable {
        /// Panel "dung sai", 20–90. 50 is the panel default and maps to `tol == 1`.
        public var tolerance: Double
        /// A connected component smaller than this fraction of the *total* skin
        /// area is dropped (sand, wood, a stray beige pixel). skincore.js: 0.02.
        public var minComponentRatio: Double
        /// Coverage above which a pixel joins a connected component. skincore.js: 60.
        public var componentThreshold: Int
        /// Final smoothing of the coverage map, in working-grid pixels.
        public var blurRadius: Int
        public var blurPasses: Int

        public init(
            tolerance: Double = 50, minComponentRatio: Double = 0.02,
            componentThreshold: Int = 60, blurRadius: Int = 2, blurPasses: Int = 2
        ) {
            self.tolerance = tolerance
            self.minComponentRatio = minComponentRatio
            self.componentThreshold = componentThreshold
            self.blurRadius = blurRadius
            self.blurPasses = blurPasses
        }

        public static let `default` = Options()
    }

    /// Everything `classify` learned about the picture, for the bench JSON and
    /// for a caller that wants to know whether the per-image step actually ran.
    public struct Stats: Sendable, Equatable {
        /// Percentage of pixels the raw colour rules scored above 40, before the
        /// per-image back-projection and the component filter.
        public var rawPercent: Int
        /// Percentage of pixels left above 120 at the end.
        public var finalPercent: Int
        /// `false` when the picture had fewer than 40 confident skin pixels, in
        /// which case the back-projection step was skipped entirely and the
        /// output is the plain colour rules.
        public var learned: Bool
        public var medianCb: Double
        public var medianCr: Double
        public var componentsKept: Int
        public var componentsTotal: Int
        /// The gain the top-5 % normalisation applied (1 when it did not fire).
        public var gain: Double
    }

    public struct Result: Sendable, Equatable {
        /// Smoothed coverage, `width * height` bytes, row-major, row 0 at the
        /// top, 0 = not skin, 255 = skin. This is skincore.js's `skinMaskSmall`.
        public var coverage: [UInt8]
        public var width: Int
        public var height: Int
        public var stats: Stats
    }

    // MARK: - classify

    /// The port of skincore.js `classify` + `skinMaskSmall`, on an RGB(A) buffer
    /// that is **already at the working resolution** (skincore.js's `sw × sh`;
    /// the panel and `eval.js` both work at 320 px wide).
    ///
    /// - Parameters:
    ///   - rgb: interleaved 8-bit channels, row-major, row 0 at the top.
    ///   - componentsPerPixel: 3 or 4.
    public static func classify(
        rgb: [UInt8], componentsPerPixel: Int, width: Int, height: Int,
        options: Options = .default
    ) -> Result {
        precondition(componentsPerPixel == 3 || componentsPerPixel == 4)
        precondition(rgb.count >= width * height * componentsPerPixel)
        let n = width * height
        var skin = [Int](repeating: 0, count: n)
        var lum = [Int](repeating: 0, count: n)
        // **`Float`, not `Double`, on purpose.** skincore.js holds these in a
        // `Float32Array`, so every later use — the medians reported as
        // `learnedCb`/`learnedCr`, and the `Math.round(Cb / 2)` histogram bin —
        // sees a value already rounded to single precision. Keeping them as
        // `Double` here agreed with the JS on the fixture frame (the 128-bin
        // histogram is coarse enough to absorb 1e-7) but differed in the sixth
        // decimal of the reported medians, and a bin boundary is exactly where
        // that difference would eventually land on a different picture. "Identical
        // numerics" has to include the storage width.
        var cbs = [Float](repeating: 0, count: n)
        var crs = [Float](repeating: 0, count: n)
        var gbs = [Int](repeating: 0, count: n)

        // 2 — score every pixel.
        var hit = 0
        var p = 0
        for i in 0..<n {
            let r = Double(rgb[p]), g = Double(rgb[p + 1]), b = Double(rgb[p + 2])
            p += componentsPerPixel
            lum[i] = Int(0.2126 * r + 0.7152 * g + 0.0722 * b)  // JS `| 0`: truncation
            cbs[i] = Float(128 - 0.168736 * r - 0.331264 * g + 0.5 * b)
            crs[i] = Float(128 + 0.5 * r - 0.418688 * g - 0.081312 * b)
            gbs[i] = Int(g) - Int(b)
            let score = skinScore(r, g, b)
            skin[i] = score
            if score > 40 { hit += 1 }
        }
        let rawPercent = jsRound(Double(hit) * 100 / Double(n))

        // 4 — learn this picture's own skin tone (2D CbCr back-projection).
        var confidentCb: [Double] = []
        var confidentCr: [Double] = []
        var confidentLum: [Double] = []
        var confidentGb: [Double] = []
        for i in 0..<n where skin[i] > 60 {
            // Widened back to `Double` exactly as a JS `Array.push` of a
            // `Float32Array` element does.
            confidentCb.append(Double(cbs[i]))
            confidentCr.append(Double(crs[i]))
            confidentLum.append(Double(lum[i]))
            confidentGb.append(Double(gbs[i]))
        }
        var learned = false
        var medCb = 102.0, medCr = 153.0, medLum = 128.0, medGb = 12.0
        let tol = max(0.4, min(1.8, (options.tolerance.isFinite ? options.tolerance : 50) / 50))

        if confidentCb.count >= 40 {
            learned = true
            medCb = median(confidentCb)
            medCr = median(confidentCr)
            medLum = median(confidentLum)
            medGb = median(confidentGb)

            let q = 2.0, sz = 128
            var hist = [Double](repeating: 0, count: sz * sz)
            for i in 0..<n where skin[i] > 60 {
                let bx = min(sz - 1, max(0, jsRound(Double(cbs[i]) / q)))
                let by = min(sz - 1, max(0, jsRound(Double(crs[i]) / q)))
                hist[by * sz + bx] += Double(skin[i]) / 255
            }
            var smoothed = [Double](repeating: 0, count: sz * sz)
            var hmax = 0.0
            for y in 0..<sz {
                for x in 0..<sz {
                    var acc = 0.0
                    var k = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let yy = y + dy, xx = x + dx
                            if yy < 0 || xx < 0 || yy >= sz || xx >= sz { continue }
                            acc += hist[yy * sz + xx]
                            k += 1
                        }
                    }
                    let v = acc / Double(k)
                    smoothed[y * sz + x] = v
                    if v > hmax { hmax = v }
                }
            }
            let gamma = 0.35 / max(0.4, tol)

            for i in 0..<n where skin[i] != 0 {
                let bx = min(sz - 1, max(0, jsRound(Double(cbs[i]) / q)))
                let by = min(sz - 1, max(0, jsRound(Double(crs[i]) / q)))
                var score = hmax > 0 ? pow(smoothed[by * sz + bx] / hmax, gamma) : 0

                let dl = abs(Double(lum[i]) - medLum)
                if dl > 135 {
                    score = 0
                } else if dl > 90 {
                    score *= 1 - (dl - 90) / 45
                }

                // Rattan / wood / sand are yellower than skin; only the
                // yellower-than-skin side is penalised.
                let dy = Double(gbs[i]) - medGb
                if dy > 6 { score *= max(0, 1 - (dy - 6) / 12) }

                skin[i] = jsRound(Double(skin[i]) * min(1, score))
            }
        }

        // 5 — drop small disconnected blobs.
        let components = keepBigComponents(
            skin, width: width, height: height, threshold: options.componentThreshold,
            minRatio: options.minComponentRatio)
        skin = components.mask

        // 6 — normalise: the most confident 5 % of the skin reaches 255.
        var hi = 0
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<n where skin[i] != 0 { histogram[skin[i]] += 1 }
        var total = 0
        for v in 1..<256 { total += histogram[v] }
        if total > 0 {
            var acc = 0
            var v = 255
            while v >= 1 {
                acc += histogram[v]
                if Double(acc) >= Double(total) * 0.05 {
                    hi = v
                    break
                }
                v -= 1
            }
            if hi > 20 && hi < 250 {
                let g = 255 / Double(hi)
                for i in 0..<n where skin[i] != 0 {
                    skin[i] = min(255, jsRound(Double(skin[i]) * g))
                }
            }
        }
        let gain = hi != 0 ? 255 / Double(hi) : 1

        // 7 — statistics.
        var confident = 0
        for i in 0..<n where skin[i] > 120 { confident += 1 }

        let bytes = skin.map { UInt8(clamping: $0) }
        let smooth = boxBlur(
            bytes, width: width, height: height, radius: options.blurRadius,
            passes: options.blurPasses)

        return Result(
            coverage: smooth, width: width, height: height,
            stats: Stats(
                rawPercent: rawPercent,
                finalPercent: jsRound(Double(confident) * 100 / Double(n)),
                learned: learned, medianCb: medCb, medianCr: medCr,
                componentsKept: components.kept, componentsTotal: components.total,
                gain: gain))
    }

    // MARK: - Building blocks (ported verbatim, exposed for the tests)

    /// skincore.js `boxBlur`: separable, clamped at the edges, `passes` times,
    /// and — like the JS, which writes a float into a `Uint8Array` — **truncating**
    /// on store rather than rounding.
    public static func boxBlur(
        _ source: [UInt8], width: Int, height: Int, radius: Int, passes: Int
    ) -> [UInt8] {
        guard radius > 0, passes > 0, width > 0, height > 0 else { return source }
        var a = source
        var b = [UInt8](repeating: 0, count: width * height)
        for _ in 0..<passes {
            for y in 0..<height {  // horizontal
                var sum = 0
                let count = 2 * radius + 1
                for x in (-radius)...radius {
                    let xx = max(0, min(width - 1, x))
                    sum += Int(a[y * width + xx])
                }
                for x in 0..<width {
                    // `b[...] = sum / cnt` into a Uint8Array truncates; integer
                    // division here is the same operation.
                    b[y * width + x] = UInt8(clamping: sum / count)
                    let out = max(0, min(width - 1, x - radius))
                    let inn = max(0, min(width - 1, x + radius + 1))
                    sum += Int(a[y * width + inn]) - Int(a[y * width + out])
                }
            }
            swap(&a, &b)
            for x in 0..<width {  // vertical
                var sum = 0
                let count = 2 * radius + 1
                for y in (-radius)...radius {
                    let yy = max(0, min(height - 1, y))
                    sum += Int(a[yy * width + x])
                }
                for y in 0..<height {
                    b[y * width + x] = UInt8(clamping: sum / count)
                    let out = max(0, min(height - 1, y - radius))
                    let inn = max(0, min(height - 1, y + radius + 1))
                    sum += Int(a[inn * width + x]) - Int(a[out * width + x])
                }
            }
            swap(&a, &b)
        }
        return a
    }

    /// skincore.js `keepBigComponents`: 4-connected flood fill over pixels above
    /// `threshold`, keeping components whose area is at least `minRatio` of the
    /// **total** skin area (not of the largest component — a face separated from
    /// the hands by hair would otherwise be dropped).
    public static func keepBigComponents(
        _ mask: [Int], width: Int, height: Int, threshold: Int, minRatio: Double
    ) -> (mask: [Int], kept: Int, total: Int) {
        let n = width * height
        var label = [Int](repeating: -1, count: n)
        var stack = [Int]()
        stack.reserveCapacity(n)
        var areas: [Int] = []
        for start in 0..<n {
            if mask[start] <= threshold || label[start] >= 0 { continue }
            let id = areas.count
            var area = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            label[start] = id
            while let c = stack.popLast() {
                area += 1
                let cx = c % width, cy = c / width
                if cx > 0, mask[c - 1] > threshold, label[c - 1] < 0 {
                    label[c - 1] = id
                    stack.append(c - 1)
                }
                if cx < width - 1, mask[c + 1] > threshold, label[c + 1] < 0 {
                    label[c + 1] = id
                    stack.append(c + 1)
                }
                if cy > 0, mask[c - width] > threshold, label[c - width] < 0 {
                    label[c - width] = id
                    stack.append(c - width)
                }
                if cy < height - 1, mask[c + width] > threshold, label[c + width] < 0 {
                    label[c + width] = id
                    stack.append(c + width)
                }
            }
            areas.append(area)
        }
        if areas.isEmpty { return (mask, 0, 0) }
        let totalArea = areas.reduce(0, +)
        // Kept as a Double, like the JS: `Math.max(12, totalArea * minRatio)` is
        // not an integer and rounding it here would move the cut-off.
        let minArea = max(12, Double(totalArea) * minRatio)
        var out = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let id = label[i]
            if id >= 0, Double(areas[id]) >= minArea { out[i] = mask[i] }
        }
        return (out, areas.filter { Double($0) >= minArea }.count, areas.count)
    }

    /// skincore.js `areaDown`, generalised to an interleaved RGB(A) buffer:
    /// every source pixel is accumulated into the target cell
    /// `floor(x * sw / w)`, then averaged. Deliberately the same mapping as the
    /// JS so the working grid a mask is computed on is the one `eval.js` scored.
    public static func areaDownRGB(
        _ rgb: [UInt8], componentsPerPixel: Int, width: Int, height: Int,
        targetWidth: Int, targetHeight: Int
    ) -> [UInt8] {
        precondition(targetWidth > 0 && targetHeight > 0)
        let cells = targetWidth * targetHeight
        var sums = [Double](repeating: 0, count: cells * 3)
        var counts = [Double](repeating: 0, count: cells)
        for y in 0..<height {
            let ty = min(targetHeight - 1, y * targetHeight / height)
            for x in 0..<width {
                let tx = min(targetWidth - 1, x * targetWidth / width)
                let cell = ty * targetWidth + tx
                let source = (y * width + x) * componentsPerPixel
                sums[cell * 3] += Double(rgb[source])
                sums[cell * 3 + 1] += Double(rgb[source + 1])
                sums[cell * 3 + 2] += Double(rgb[source + 2])
                counts[cell] += 1
            }
        }
        var out = [UInt8](repeating: 0, count: cells * 3)
        for cell in 0..<cells {
            let c = counts[cell]
            guard c > 0 else { continue }
            for k in 0..<3 {
                out[cell * 3 + k] = UInt8(clamping: jsRound(sums[cell * 3 + k] / c))
            }
        }
        return out
    }

    /// skincore.js `median`: sorts ascending and takes `a[length >> 1]` — the
    /// **upper** median for an even count, not the average of the two middles.
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count >> 1]
    }

    /// `Math.round`: half rounds **up** (towards +∞), not away from zero. Every
    /// value it is applied to in this file is ≥ 0, but the rule is written out so
    /// a future negative argument does not silently diverge from the JS.
    @inline(__always)
    static func jsRound(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value + 0.5).rounded(.down))
    }
}
