import CoreGraphics
import Foundation

/// The SSD anchor grid `blaze_face_short_range.tflite` regresses against.
///
/// Reproduces MediaPipe's `SsdAnchorsCalculator` for
/// `face_detection_short_range_cpu.pbtxt`:
///
/// ```
/// num_layers: 4
/// min_scale: 0.1484375   max_scale: 0.75
/// input_size_width: 128  input_size_height: 128
/// anchor_offset_x: 0.5   anchor_offset_y: 0.5
/// strides: 8, 16, 16, 16
/// aspect_ratios: 1.0
/// fixed_anchor_size: true
/// ```
///
/// `fixed_anchor_size: true` makes every anchor 1.0 x 1.0, so only the **centres**
/// matter and the scale schedule drops out entirely — the only thing the four
/// layers still decide is how many anchors sit on each cell. The calculator merges
/// consecutive layers that share a stride, so layer 0 (stride 8) contributes
/// 1 aspect ratio + 1 interpolated scale = 2 anchors per cell on a 16x16 grid, and
/// layers 1-3 (stride 16) contribute 3 x 2 = 6 per cell on an 8x8 grid.
/// 16*16*2 + 8*8*6 = **896**, which is exactly the model's anchor axis — that
/// count is the check that this reconstruction is the right one, and
/// `BlazeFaceAnchorTests` asserts it plus the layout.
///
/// Order matters as much as the count: the model's rows are laid out grid row
/// (y) major, then column (x), then the anchors of that cell. Getting it wrong
/// still decodes into plausible boxes, just in the wrong place.
public enum BlazeFaceAnchors {
    /// The detector's square input side, in pixels.
    public static let inputSide = 128

    public static let count = 896

    /// (stride, anchors per cell) after merging equal strides.
    static let layers: [(stride: Int, perCell: Int)] = [(8, 2), (16, 6)]

    /// Anchor centres in 0…1 normalised coordinates, y down.
    public static let centers: [CGPoint] = {
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        for layer in layers {
            let fm = Int((Double(inputSide) / Double(layer.stride)).rounded(.up))
            for y in 0..<fm {
                for x in 0..<fm {
                    let point = CGPoint(
                        x: (CGFloat(x) + 0.5) / CGFloat(fm),
                        y: (CGFloat(y) + 0.5) / CGFloat(fm))
                    for _ in 0..<layer.perCell { out.append(point) }
                }
            }
        }
        return out
    }()
}
