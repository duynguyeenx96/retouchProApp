import CoreGraphics
import Foundation
import RPEngine
import RPVision

/// Turns S1's 478-point mesh into the control points a face-reshape slider
/// would actually produce, so the warp benchmark measures a plausible
/// deformation instead of random handles.
///
/// Two sliders are modelled, both from `docs/PLAN.md` §1.3:
///  * **Bóp mặt** — the lower face-oval contour is pulled toward the face's
///    own midline, with the pull ramping from 0 at the eye line to full at the
///    chin;
///  * **Mắt to** — each eye ring is scaled about its own centroid.
///
/// Both deltas are expressed as a fraction of **face width**, which is what
/// PLAN §2 requires for a preset to transfer between images.
enum FaceReshape {
    /// MediaPipe Face Mesh `FACEMESH_FACE_OVAL`, in ring order.
    /// Verified geometrically rather than trusted — see ``check(_:)``.
    static let faceOval = [
        10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379,
        378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127,
        162, 21, 54, 103, 67, 109,
    ]
    /// MediaPipe `FACEMESH_LEFT_EYE` / `FACEMESH_RIGHT_EYE` rings (subject's
    /// left / right).
    static let leftEye = [362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398]
    static let rightEye = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
    /// Cheek extremes; the distance between them is the face width the sliders
    /// are relative to.
    static let cheekRight = 234
    static let cheekLeft = 454
    static let foreheadTop = 10
    static let chin = 152
    static let eyeOuterRight = 33
    static let eyeOuterLeft = 263

    struct Sliders {
        /// "Bóp mặt", 0…100. At 100 the jaw moves in by
        /// `maxSlimFraction × faceWidth`.
        var faceSlim: Double = 60
        /// "Mắt to", 0…100. At 100 each eye grows by `maxEyeGain`.
        var eyeEnlarge: Double = 40
        /// Chosen to be a visible but not cartoonish retouch — the same order of
        /// magnitude a retoucher uses. **Not tuned against anything**; this
        /// spike measures cost and accuracy, not taste.
        var maxSlimFraction: Double = 0.040
        var maxEyeGain: Double = 0.20
    }

    struct Result {
        var control: MLSDeformation.ControlPoints
        var faceWidth: Double
        var maxDisplacement: Double
        var checks: [String: Any]
    }

    /// Geometric sanity of the hard-coded index lists. A wrong index list still
    /// produces a warp, just of the wrong part of the face, so it is checked
    /// rather than assumed (same discipline as spike S2's class-index matrix).
    static func check(_ points: [CGPoint]) -> [String: Any] {
        var checks: [String: Any] = [:]

        // 1. The face oval must enclose essentially every other landmark.
        let ring = faceOval.map { points[$0] }
        var inside = 0
        for (i, p) in points.enumerated() where !faceOval.contains(i) {
            if pointInPolygon(p, ring) { inside += 1 }
        }
        let others = points.count - faceOval.count
        checks["oval_encloses_fraction"] = Double(inside) / Double(others)

        // 2. Eye rings must sit above the mouth and below the forehead point,
        //    and left must be on the opposite side of the midline from right.
        let leftCentre = centroid(leftEye.map { points[$0] })
        let rightCentre = centroid(rightEye.map { points[$0] })
        let top = points[foreheadTop]
        let bottom = points[chin]
        checks["left_eye_below_forehead"] = leftCentre.y > top.y
        checks["right_eye_below_forehead"] = rightCentre.y > top.y
        checks["left_eye_above_chin"] = leftCentre.y < bottom.y
        checks["right_eye_above_chin"] = rightCentre.y < bottom.y
        // Signed side of the forehead→chin midline.
        let axis = CGPoint(x: bottom.x - top.x, y: bottom.y - top.y)
        func side(_ p: CGPoint) -> Double {
            axis.x * (p.y - top.y) - axis.y * (p.x - top.x)
        }
        checks["eyes_on_opposite_sides_of_midline"] = side(leftCentre) * side(rightCentre) < 0
        // `Double(...)` on purpose: `hypot` on CGPoint components returns
        // CGFloat, and a CGFloat boxed in `Any` does **not** satisfy
        // `as? Double` — the implicit CGFloat/Double conversion Swift 5.5 added
        // is compile-time only, dynamic casts stay exact. Storing the CGFloat
        // made every aggregate over this key read 0.
        checks["eye_separation_over_face_width"] = Double(
            hypot(leftCentre.x - rightCentre.x, leftCentre.y - rightCentre.y)
                / hypot(points[cheekLeft].x - points[cheekRight].x,
                        points[cheekLeft].y - points[cheekRight].y))
        return checks
    }

    static func controlPoints(
        landmarks points: [CGPoint], imageSize: CGSize, sliders: Sliders = Sliders()
    ) -> Result {
        let faceWidth = hypot(
            points[cheekLeft].x - points[cheekRight].x,
            points[cheekLeft].y - points[cheekRight].y)
        let top = points[foreheadTop]
        let chinPoint = points[chin]
        let eyeLineY = (points[eyeOuterLeft].y + points[eyeOuterRight].y) / 2

        // Face midline as a parametric line from forehead to chin.
        let axis = CGPoint(x: chinPoint.x - top.x, y: chinPoint.y - top.y)
        let axisLength = hypot(axis.x, axis.y)
        let unit = CGPoint(x: axis.x / axisLength, y: axis.y / axisLength)
        func projectOntoMidline(_ p: CGPoint) -> CGPoint {
            let t = (p.x - top.x) * unit.x + (p.y - top.y) * unit.y
            return CGPoint(x: top.x + unit.x * t, y: top.y + unit.y * t)
        }

        var source: [CGPoint] = []
        var destination: [CGPoint] = []

        // Bóp mặt: pull the lower oval toward the midline.
        let slim = sliders.faceSlim / 100 * sliders.maxSlimFraction * faceWidth
        let span = max(1, chinPoint.y - eyeLineY)
        for index in faceOval {
            let p = points[index]
            source.append(p)
            guard p.y > eyeLineY else {
                destination.append(p)  // above the eye line: an identity handle
                continue
            }
            // Ramp 0 -> 1 from the eye line to the chin, squared so the jaw and
            // chin take most of the movement and the temples take none.
            let t = min(1, (p.y - eyeLineY) / span)
            let weight = t * t
            let onAxis = projectOntoMidline(p)
            let toAxis = CGPoint(x: onAxis.x - p.x, y: onAxis.y - p.y)
            let d = hypot(toAxis.x, toAxis.y)
            guard d > 1e-6 else {
                destination.append(p)
                continue
            }
            let move = slim * weight
            destination.append(
                CGPoint(x: p.x + toAxis.x / d * move, y: p.y + toAxis.y / d * move))
        }

        // Mắt to: scale each eye ring about its own centroid.
        let gain = 1 + sliders.eyeEnlarge / 100 * sliders.maxEyeGain
        for ring in [leftEye, rightEye] {
            let centre = centroid(ring.map { points[$0] })
            for index in ring {
                let p = points[index]
                source.append(p)
                destination.append(
                    CGPoint(
                        x: centre.x + (p.x - centre.x) * gain,
                        y: centre.y + (p.y - centre.y) * gain))
            }
        }

        var maxDisplacement = 0.0
        for i in 0..<source.count {
            maxDisplacement = max(
                maxDisplacement,
                hypot(destination[i].x - source[i].x, destination[i].y - source[i].y))
        }

        let control = MLSDeformation.ControlPoints(source: source, destination: destination)
            .pinningBorder(width: Double(imageSize.width), height: Double(imageSize.height))
        return Result(
            control: control, faceWidth: faceWidth, maxDisplacement: maxDisplacement,
            checks: check(points))
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / Double(points.count), y: sum.y / Double(points.count))
    }

    static func pointInPolygon(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
                p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
