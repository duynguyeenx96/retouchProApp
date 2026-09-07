import Foundation
import RPCore

/// The little strings the library screens draw over a thumbnail — the format
/// tag, the EXIF rows — derived from `Shot` and nothing else.
///
/// Pure functions on value types so they can be checked without a view: the
/// mockup's `RAW` / `HEIC` chip and the info panel's `ISO 400 · f/1.8 · 1/200`
/// have to come from the real `CaptureMetadata`, not from a placeholder
/// (docs/design/SPEC.md screen 2c: *"Số mặt nhận diện — the last one is a real
/// FaceAnalyzer output, not decorative"*).
public enum ShotDisplay {

    /// Extensions the app treats as camera RAW. A subset of
    /// `ProjectBundle.importableExtensions`, so a format added there without a
    /// decision about RAW-ness simply shows its own extension.
    public static let rawExtensions: Set<String> = [
        "arw", "dng", "cr2", "cr3", "nef", "raf", "orf", "rw2", "srw", "pef",
    ]

    public static func isRaw(_ shot: Shot) -> Bool {
        rawExtensions.contains(
            (shot.originalFileName as NSString).pathExtension.lowercased())
    }

    /// `"RAW"` for a camera raw file, otherwise the uppercased extension with
    /// the two common aliases folded (`jpg` → `JPEG`, `heif` → `HEIC`).
    public static func formatTag(_ shot: Shot) -> String {
        let ext = (shot.originalFileName as NSString).pathExtension.lowercased()
        if rawExtensions.contains(ext) { return "RAW" }
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "heic", "heif": return "HEIC"
        case "tif", "tiff": return "TIFF"
        case "": return "—"
        default: return ext.uppercased()
        }
    }

    /// The file's own extension, uppercased — what the info panel's "Định dạng"
    /// row shows (`ARW`, not `RAW`).
    public static func fileExtension(_ shot: Shot) -> String {
        let ext = (shot.originalFileName as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "—" : ext
    }

    public static func pixelSize(_ shot: Shot) -> String {
        guard let width = shot.capture.pixelWidth, let height = shot.capture.pixelHeight,
            width > 0, height > 0
        else { return "—" }
        return "\(width)×\(height)"
    }

    public static func iso(_ shot: Shot) -> String {
        shot.capture.iso.map(String.init) ?? "—"
    }

    public static func aperture(_ shot: Shot) -> String {
        guard let value = shot.capture.aperture, value > 0 else { return "—" }
        return "f/" + String(format: value < 10 ? "%.1f" : "%.0f", value)
    }

    /// `"1/200"` under a second, `"2s"` over it — the way a camera shows it.
    public static func shutter(_ shot: Shot) -> String {
        guard let seconds = shot.capture.shutterSpeedSeconds, seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%gs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }
}
