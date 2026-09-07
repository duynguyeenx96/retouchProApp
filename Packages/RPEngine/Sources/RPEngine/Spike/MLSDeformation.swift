import CoreGraphics
import Foundation

/// Moving Least Squares image deformation (Schaefer, McPhail & Warren,
/// *Image Deformation Using Moving Least Squares*, SIGGRAPH 2006) — the CPU,
/// `Double`-precision reference.
///
/// docs/PLAN.md §1.3: the face-reshape sliders (bóp mặt, gò má, cằm, mũi, mắt
/// to, miệng, môi) are "mesh warp Moving Least Squares từ 478 landmark; slider =
/// delta tương đối theo face width". This type is the deformation itself; the
/// GPU version lives in `Shaders.metal` and `MLSMeshWarp`, and
/// `MLSMeshWarpTests` checks the two agree.
///
/// **Coordinates are image pixels, origin top-left, y down** — the same frame
/// `RPVision.FaceLandmarks478.imagePoints` produces, so landmarks can be used as
/// control points with no conversion and no flip.
public enum MLSDeformation {
    /// Which class of local transform the deformation is allowed to use.
    public enum Variant: String, Sendable, CaseIterable, Codable {
        /// Rotation + uniform scale + translation. Needed by any slider that
        /// makes something bigger or smaller (mắt to, thu nhỏ mũi).
        case similarity
        /// Rotation + translation only. Cannot scale, so it cannot introduce the
        /// "melted" look, but it also cannot express an enlargement.
        case rigid
    }

    public struct Options: Sendable, Equatable, Codable {
        public var variant: Variant
        /// Weight exponent: `w_i = 1 / |p_i - v|^(2 alpha)`. Larger = more local.
        ///
        /// **Not measured by spike S3.** The paper uses 1.0; 2.0 is the value
        /// face-retouch implementations commonly use because a face has dozens
        /// of control points a few pixels apart and alpha = 1 lets a jaw handle
        /// tug on an eyelid. Which one *looks* right is a Phase 2 decision with
        /// a human in the loop, not a number this spike can produce.
        public var alpha: Double
        /// Mesh vertices across and down. Cells = grid − 1.
        public var gridWidth: Int
        public var gridHeight: Int

        public init(
            variant: Variant = .similarity, alpha: Double = 2.0,
            gridWidth: Int = 65, gridHeight: Int = 65
        ) {
            self.variant = variant
            self.alpha = alpha
            self.gridWidth = gridWidth
            self.gridHeight = gridHeight
        }
    }

    /// Handles: `source[i]` is dragged to `destination[i]`.
    public struct ControlPoints: Sendable, Equatable, Codable {
        public var source: [CGPoint]
        public var destination: [CGPoint]

        public init(source: [CGPoint], destination: [CGPoint]) {
            precondition(source.count == destination.count)
            self.source = source
            self.destination = destination
        }

        public var count: Int { source.count }

        /// Identity handles pinning the image border, so a face-local
        /// deformation cannot drag the whole frame. MLS's far field converges to
        /// a single similarity transform fitted to every handle, which without
        /// these would shift the background by a visible amount.
        public static func borderAnchors(
            width: Double, height: Double, perEdge: Int = 4
        ) -> [CGPoint] {
            var points: [CGPoint] = []
            let n = max(1, perEdge)
            for i in 0...n {
                let t = Double(i) / Double(n)
                points.append(CGPoint(x: t * width, y: 0))
                points.append(CGPoint(x: t * width, y: height))
            }
            for i in 1..<n {
                let t = Double(i) / Double(n)
                points.append(CGPoint(x: 0, y: t * height))
                points.append(CGPoint(x: width, y: t * height))
            }
            return points
        }

        /// `self` plus identity handles on the image border.
        public func pinningBorder(width: Double, height: Double, perEdge: Int = 4)
            -> ControlPoints
        {
            let anchors = Self.borderAnchors(width: width, height: height, perEdge: perEdge)
            return ControlPoints(
                source: source + anchors, destination: destination + anchors)
        }
    }

    /// `f(v)` for one point.
    ///
    /// Implemented with complex arithmetic, which makes the similarity case
    /// exact in two lines: minimising `Σ w_i |a·p̂_i − q̂_i|²` over a complex `a`
    /// gives `a = Σ w_i conj(p̂_i) q̂_i / Σ w_i |p̂_i|²` and
    /// `f(v) = q* + a·(v − p*)`. The rigid case is the same numerator normalised
    /// to unit modulus, which is the paper's eq. (8) rewritten.
    ///
    /// `scale` only affects floating-point conditioning: the deformation is
    /// exactly invariant to a uniform rescale of all coordinates, and the GPU
    /// kernel divides by the image's long edge so `1/d⁴` stays near 1 rather
    /// than near 1e−15 at 6000 px. The CPU reference does the same so the two
    /// can be compared without a precision excuse.
    public static func evaluate(
        _ v: CGPoint, control: ControlPoints, options: Options, scale: Double = 1
    ) -> CGPoint {
        let n = control.count
        guard n > 0, scale > 0 else { return v }
        let vx = Double(v.x) / scale
        let vy = Double(v.y) / scale

        var wsum = 0.0
        var pStarX = 0.0, pStarY = 0.0, qStarX = 0.0, qStarY = 0.0
        var weights = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let px = Double(control.source[i].x) / scale
            let py = Double(control.source[i].y) / scale
            let dx = px - vx, dy = py - vy
            let d2 = dx * dx + dy * dy
            if d2 < 1e-14 { return control.destination[i] }
            let w = pow(d2, -options.alpha)
            weights[i] = w
            wsum += w
            pStarX += w * px
            pStarY += w * py
            qStarX += w * Double(control.destination[i].x) / scale
            qStarY += w * Double(control.destination[i].y) / scale
        }
        guard wsum > 0, wsum.isFinite else { return v }
        pStarX /= wsum
        pStarY /= wsum
        qStarX /= wsum
        qStarY /= wsum

        var aRe = 0.0, aIm = 0.0, mu = 0.0
        for i in 0..<n {
            let w = weights[i]
            let phx = Double(control.source[i].x) / scale - pStarX
            let phy = Double(control.source[i].y) / scale - pStarY
            let qhx = Double(control.destination[i].x) / scale - qStarX
            let qhy = Double(control.destination[i].y) / scale - qStarY
            aRe += w * (phx * qhx + phy * qhy)
            aIm += w * (phx * qhy - phy * qhx)
            mu += w * (phx * phx + phy * phy)
        }

        var cRe = 1.0, cIm = 0.0
        switch options.variant {
        case .rigid:
            let m = (aRe * aRe + aIm * aIm).squareRoot()
            if m > 1e-20 {
                cRe = aRe / m
                cIm = aIm / m
            }
        case .similarity:
            if mu > 1e-20 {
                cRe = aRe / mu
                cIm = aIm / mu
            }
        }

        let dx = vx - pStarX
        let dy = vy - pStarY
        let mx = qStarX + (cRe * dx - cIm * dy)
        let my = qStarY + (cRe * dy + cIm * dx)
        return CGPoint(x: mx * scale, y: my * scale)
    }

    /// `f` sampled on the `gridWidth × gridHeight` lattice spanning
    /// `0…imageSize`, row-major, in image pixels.
    public static func grid(
        control: ControlPoints, options: Options, imageSize: CGSize
    ) -> [CGPoint] {
        let scale = max(Double(imageSize.width), Double(imageSize.height))
        let cellsX = Double(max(1, options.gridWidth - 1))
        let cellsY = Double(max(1, options.gridHeight - 1))
        var out = [CGPoint](repeating: .zero, count: options.gridWidth * options.gridHeight)
        for y in 0..<options.gridHeight {
            for x in 0..<options.gridWidth {
                let v = CGPoint(
                    x: Double(x) / cellsX * Double(imageSize.width),
                    y: Double(y) / cellsY * Double(imageSize.height))
                out[y * options.gridWidth + x] = evaluate(
                    v, control: control, options: options, scale: scale)
            }
        }
        return out
    }

    /// Bilinear interpolation of a deformed grid at an arbitrary image point —
    /// i.e. exactly what the rasteriser does between mesh vertices. Used to
    /// measure how much geometric accuracy the mesh gives up against `evaluate`.
    public static func interpolate(
        grid: [CGPoint], gridWidth: Int, gridHeight: Int, at point: CGPoint, imageSize: CGSize
    ) -> CGPoint {
        let cellsX = Double(max(1, gridWidth - 1))
        let cellsY = Double(max(1, gridHeight - 1))
        let gx = min(max(0, Double(point.x) / Double(imageSize.width) * cellsX), cellsX)
        let gy = min(max(0, Double(point.y) / Double(imageSize.height) * cellsY), cellsY)
        let x0 = min(Int(gx), gridWidth - 2 < 0 ? 0 : gridWidth - 2)
        let y0 = min(Int(gy), gridHeight - 2 < 0 ? 0 : gridHeight - 2)
        let tx = gx - Double(x0)
        let ty = gy - Double(y0)
        func at(_ x: Int, _ y: Int) -> CGPoint { grid[y * gridWidth + x] }
        let p00 = at(x0, y0), p10 = at(x0 + 1, y0)
        let p01 = at(x0, y0 + 1), p11 = at(x0 + 1, y0 + 1)
        let top = CGPoint(
            x: Double(p00.x) * (1 - tx) + Double(p10.x) * tx,
            y: Double(p00.y) * (1 - tx) + Double(p10.y) * tx)
        let bottom = CGPoint(
            x: Double(p01.x) * (1 - tx) + Double(p11.x) * tx,
            y: Double(p01.y) * (1 - tx) + Double(p11.y) * tx)
        return CGPoint(
            x: Double(top.x) * (1 - ty) + Double(bottom.x) * ty,
            y: Double(top.y) * (1 - ty) + Double(bottom.y) * ty)
    }
}
