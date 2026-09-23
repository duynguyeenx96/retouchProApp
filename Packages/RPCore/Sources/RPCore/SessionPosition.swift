import Foundation

/// Where the user was in a project when they left it — `session.json` at the
/// bundle root (docs/ADR-0025, "a project is a session").
///
/// Opening the project restores it: the open shot, the filmstrip's batch
/// selection, the canvas zoom/pan and which tab (library / editor) was showing.
///
/// Plain values only. RPCore knows nothing about SwiftUI, so the tab is its raw
/// string (RPUI's `EditorChrome.Tab.rawValue`) and the viewport is three
/// numbers and a flag (RPUI's `CanvasViewport`). Every field is optional on
/// decode: a missing or partial file means "start where a fresh open starts",
/// never "refuse to open".
public struct SessionPosition: Sendable, Hashable {
    public static let currentFormatVersion = 1

    public struct Viewport: Sendable, Hashable, Codable {
        /// Display scale relative to image pixels (1 = 100 %).
        public var zoom: Double
        /// Image centre offset from the view centre, in points.
        public var offsetX: Double
        public var offsetY: Double
        /// `true` when the canvas was following the window size ("vừa khung").
        public var fitsWindow: Bool

        public init(zoom: Double, offsetX: Double, offsetY: Double, fitsWindow: Bool) {
            self.zoom = zoom
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.fitsWindow = fitsWindow
        }
    }

    public var activeShotID: ShotID?
    /// The batch selection, in no particular order (the filmstrip re-derives
    /// project order).
    public var selectedShotIDs: [ShotID]
    public var tab: String?
    public var viewport: Viewport?

    public init(
        activeShotID: ShotID? = nil, selectedShotIDs: [ShotID] = [], tab: String? = nil,
        viewport: Viewport? = nil
    ) {
        self.activeShotID = activeShotID
        self.selectedShotIDs = selectedShotIDs
        self.tab = tab
        self.viewport = viewport
    }
}

extension SessionPosition: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, activeShotID, selectedShotIDs, tab, viewport
    }

    /// Tolerant by design: an id that is not a valid identifier is dropped
    /// rather than failing the file, and a viewport that does not decode is
    /// treated as absent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard version <= Self.currentFormatVersion else {
            throw ProjectStoreError.unsupportedFormatVersion(
                found: version, supported: Self.currentFormatVersion)
        }
        activeShotID = (try? container.decodeIfPresent(String.self, forKey: .activeShotID))
            .flatMap { $0 }.flatMap(ShotID.init)
        let selected = (try? container.decodeIfPresent([String].self, forKey: .selectedShotIDs)) ?? nil
        selectedShotIDs = (selected ?? []).compactMap(ShotID.init)
        tab = (try? container.decodeIfPresent(String.self, forKey: .tab)) ?? nil
        viewport = (try? container.decodeIfPresent(Viewport.self, forKey: .viewport)) ?? nil
        if let viewport, !(viewport.zoom.isFinite && viewport.offsetX.isFinite && viewport.offsetY.isFinite) {
            self.viewport = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encodeIfPresent(activeShotID, forKey: .activeShotID)
        try container.encode(selectedShotIDs.sorted(), forKey: .selectedShotIDs)
        try container.encodeIfPresent(tab, forKey: .tab)
        try container.encodeIfPresent(viewport, forKey: .viewport)
    }
}
