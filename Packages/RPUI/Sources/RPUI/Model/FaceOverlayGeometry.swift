import CoreGraphics
import Foundation
import RPEngine

/// Where the face outlines go on the canvas, and which one a tap hit.
///
/// Pure functions over value types, deliberately separate from
/// ``LivePreviewController``: the controller needs a Metal device to exist and
/// this arithmetic does not, so the hit-testing can be tested on any machine —
/// including the iOS Simulator, where the whole point is that a tap lands on the
/// face the user aimed at.
public enum FaceOverlayGeometry {

    /// How much of the face width is added around the landmark bounding box, so
    /// the outline sits around the head instead of cutting through the eyebrows.
    /// The 478-point mesh covers the face, not the hair or the chin's shadow.
    public static let padding: CGFloat = 0.12

    /// Bounding box of a face's mesh, in the image pixels the mesh is in.
    /// `nil` for a face with no landmarks (the Da group alone does not need
    /// them, so an empty mesh is legal — `FaceRenderInput.landmarks`).
    public static func box(of face: FaceRenderInput) -> CGRect? {
        guard let first = face.landmarks.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in face.landmarks {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let pad = face.faceWidth * padding
        let rect = CGRect(
            x: minX - pad, y: minY - pad,
            width: (maxX - minX) + 2 * pad, height: (maxY - minY) + 2 * pad)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// Which face a point (in image pixels) is inside.
    ///
    /// The **smallest** containing box wins, so a child standing in front of an
    /// adult — a small box inside a large one — is still selectable. Picking the
    /// first match instead would make the face behind unhittable.
    public static func index(at point: CGPoint, in faces: [FaceRenderInput]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for index in faces.indices {
            guard let box = box(of: faces[index]), box.contains(point) else { continue }
            let area = box.width * box.height
            if best == nil || area < best!.area { best = (index, area) }
        }
        return best?.index
    }

    /// Image-pixel rectangle → view coordinates, using the same frame the
    /// picture is drawn with (`CanvasViewport.imageFrame`), so an outline cannot
    /// drift from the face under it at any zoom or pan.
    public static func viewRect(
        imageRect: CGRect, imageSize: CGSize, frame: CGRect
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let sx = frame.width / imageSize.width
        let sy = frame.height / imageSize.height
        return CGRect(
            x: frame.minX + imageRect.minX * sx,
            y: frame.minY + imageRect.minY * sy,
            width: imageRect.width * sx,
            height: imageRect.height * sy)
    }

    /// The inverse: a point in view coordinates back to image pixels. What a tap
    /// on the canvas needs.
    public static func imagePoint(
        viewPoint: CGPoint, imageSize: CGSize, frame: CGRect
    ) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(
            x: (viewPoint.x - frame.minX) * imageSize.width / frame.width,
            y: (viewPoint.y - frame.minY) * imageSize.height / frame.height)
    }
}
