import CoreGraphics
import Foundation

/// Which of the two operating points the graph is running at.
///
/// The numbers here are **not** taste. Every one of them is a bar spike S3
/// measured and `docs/ADR-0007` records as mandatory for Phase 2:
///
/// * `guidedSubsample = 4` — the exact filter's float32 intermediates are
///   **2.3 GB** at 24 MP (`GuidedFilter.Resources.byteCount`), which is not
///   runnable on an iPhone. `s = 4` costs 144 MB and sits 59.8 dB from the exact
///   filter.
/// * `meshGrid` 65 preview / 129 export — grid 33 drops to 43.8 dB against a
///   1025-vertex reference on the worst of the 11 a6300 frames, i.e. below the
///   plan's 45 dB golden bar. 65 is the smallest grid that clears it everywhere;
///   129 costs 0.12 ms more at 24 MP so export takes it.
/// * `pixelSpace = .sRGBEncoded` — with the same ε, filtering in linear light
///   smooths the darkest luminance decile **2.58×** harder, which is the wrong
///   way round for skin. It also matches `panelpts/RetouchProUXP/commands.js`,
///   the 8-bit display-referred code this retouch logic is ported from.
public enum RenderQuality: String, Sendable, CaseIterable, Codable {
    /// Interactive canvas, ~2048 px long edge (docs/PLAN.md §1.4).
    case preview
    /// Full-resolution render for export.
    case export

    /// Fast-guided-filter subsampling factor. Fixed at 4 in both modes — see the
    /// memory note above; this is a constant, not a tuning knob.
    public var guidedSubsample: Int { 4 }

    /// MLS lattice density (vertices per side).
    public var meshGrid: Int {
        switch self {
        case .preview: 65
        case .export: 129
        }
    }

    /// The value space every node in the graph works in.
    public var pixelSpace: SpikeTextureIO.PixelSpace { .sRGBEncoded }

    /// Longest edge the graph prefers at this quality. `nil` for `.export`,
    /// which renders whatever it is handed.
    public var preferredLongEdge: Int? {
        switch self {
        case .preview: 2048
        case .export: nil
        }
    }
}
