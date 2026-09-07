import Foundation

/// Default-off switches for RPVision code that has a measurement but is not yet
/// wired into the product (docs/PLAN.md §2, "measure before ship").
///
/// Phase 0 spike S1 added the 478-point face landmark path. It is off until the
/// Phase 2 `FaceAnalyzer` work lands, so nothing can accidentally start loading a
/// Core ML model on a code path that has not been benchmarked on a real device.
public enum RPVisionFeatureFlags {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [String: Bool] = [:]

    private static func value(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] ?? false
    }

    private static func setValue(_ key: String, _ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = newValue
    }

    /// Spike S1: MediaPipe Face Landmarker 478 points converted to Core ML.
    /// Off by default; the spike harness and its tests turn it on explicitly.
    public static var faceLandmarks478: Bool {
        get { value("faceLandmarks478") }
        set { setValue("faceLandmarks478", newValue) }
    }

    /// Spike S2: BiSeNet CelebAMask-HQ 19-class face parsing converted to Core ML.
    /// Off by default for the same reason as `faceLandmarks478` — the plan's
    /// < 150 ms bar (docs/PLAN.md §3) has only been measured on the iOS Simulator.
    public static var faceParsing19: Bool {
        get { value("faceParsing19") }
        set { setValue("faceParsing19", newValue) }
    }

    /// Phase 2: MediaPipe's `blaze_face_short_range` detector converted to Core ML
    /// (`Research/spikes/S1-landmark/convert_blazeface_to_coreml.py`). Off by
    /// default like the other two model wrappers — it exists so `FaceAnalyzer` can
    /// build the ROI the mesh model was trained on instead of Vision's, which
    /// spike S1 §4a measured at 1.399 px on real a6300 frames against a < 1 px bar.
    public static var blazeFaceShortRange: Bool {
        get { value("blazeFaceShortRange") }
        set { setValue("blazeFaceShortRange", newValue) }
    }

    /// Phase 2: the whole `FaceAnalyzer` pipeline (Vision rough box → BlazeFace ROI
    /// → 478-point mesh → 19-class parsing, cached by content hash).
    ///
    /// Separate from the three per-model flags on purpose: those say "this Core ML
    /// conversion is unverified", this one says "the *composition* of them is
    /// unverified". Enabling it does **not** enable the model flags — nothing here
    /// writes to another flag, because this storage is process-global and a
    /// concurrent suite would see the write. `FaceAnalyzer.init` throws
    /// `RPVisionFeatureDisabled` naming whichever model flag is still off.
    public static var faceAnalyzer: Bool {
        get { value("faceAnalyzer") }
        set { setValue("faceAnalyzer", newValue) }
    }

    /// Restores **every** flag to its shipping default.
    ///
    /// Not a per-test teardown hook: this storage is process-global, so a suite
    /// calling it while another suite has its own flag on switches that other suite
    /// off mid-run. That is exactly what happened when spike S2 added a second flag
    /// — the S1 and S2 benchmarks run concurrently and S1's teardown disabled
    /// `faceParsing19` under S2's feet. Tests now restore only the flag they set;
    /// use this for whole-process reset only.
    public static func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

/// Thrown when a caller reaches a feature-flagged path that is switched off.
public struct RPVisionFeatureDisabled: Error, CustomStringConvertible {
    public let feature: String
    public init(feature: String) { self.feature = feature }
    public var description: String {
        "RPVision feature '\(feature)' is disabled. Enable RPVisionFeatureFlags.\(feature) first."
    }
}
