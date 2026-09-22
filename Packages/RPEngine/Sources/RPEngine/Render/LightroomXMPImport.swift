import Foundation
import RPCore

/// The subset of a Lightroom / Camera Raw `.xmp` sidecar's `crs:` develop
/// settings this app knows how to read.
///
/// Only fields that have a real counterpart in ``ColorSliders`` are parsed:
/// Exposure/Contrast/Highlights/Shadows, white balance, Vibrance/Saturation and
/// the eight HSL saturation bands. Everything else a Lightroom sidecar can
/// carry — Texture, Clarity, Dehaze, Whites, Blacks, the tone curve,
/// sharpening, noise reduction, crop, lens corrections, masks, colour grading,
/// camera profile — has no slider to land on here, so it is left unparsed
/// rather than approximated onto something it does not mean.
public struct LightroomXMPSettings: Sendable, Equatable {
    public var exposure2012: Double?
    public var contrast2012: Double?
    public var highlights2012: Double?
    public var shadows2012: Double?
    /// Absolute Kelvin, the form a raw sidecar carries. `nil` when the file
    /// only has ``incrementalTemperature`` instead (a non-raw source).
    public var temperatureKelvin: Double?
    /// The non-raw, already-relative form of the same axis, roughly −100…100.
    public var incrementalTemperature: Double?
    /// Raw sidecar's green/magenta axis, roughly −150…150.
    public var tint: Double?
    /// The non-raw, already-relative form, roughly −100…100.
    public var incrementalTint: Double?
    public var vibrance: Double?
    public var saturation: Double?
    /// Keyed by the lowercase `HueBand` case name (`"red"`, `"orange"`, …).
    public var saturationAdjustment: [String: Double] = [:]

    public init(
        exposure2012: Double? = nil, contrast2012: Double? = nil, highlights2012: Double? = nil,
        shadows2012: Double? = nil, temperatureKelvin: Double? = nil,
        incrementalTemperature: Double? = nil, tint: Double? = nil, incrementalTint: Double? = nil,
        vibrance: Double? = nil, saturation: Double? = nil,
        saturationAdjustment: [String: Double] = [:]
    ) {
        self.exposure2012 = exposure2012
        self.contrast2012 = contrast2012
        self.highlights2012 = highlights2012
        self.shadows2012 = shadows2012
        self.temperatureKelvin = temperatureKelvin
        self.incrementalTemperature = incrementalTemperature
        self.tint = tint
        self.incrementalTint = incrementalTint
        self.vibrance = vibrance
        self.saturation = saturation
        self.saturationAdjustment = saturationAdjustment
    }

    public var isEmpty: Bool {
        exposure2012 == nil && contrast2012 == nil && highlights2012 == nil && shadows2012 == nil
            && temperatureKelvin == nil && incrementalTemperature == nil && tint == nil
            && incrementalTint == nil && vibrance == nil && saturation == nil
            && saturationAdjustment.isEmpty
    }
}

public enum LightroomXMPError: Error, Equatable {
    /// `XMLParser` itself failed — not XML at all, or truncated.
    case invalidXML
    /// Parsed fine but carried none of the fields above — not a Lightroom
    /// develop-settings sidecar, or one with nothing this app can use.
    case noDevelopSettings
}

extension LightroomXMPSettings {
    /// Parses a Lightroom / Camera Raw `.xmp` sidecar's `rdf:Description`.
    ///
    /// Handles both forms real exporters write: fields as attributes on
    /// `rdf:Description` (the common case) and fields as their own child
    /// elements with the value as text content (some tools' output, and how a
    /// hand-edited sidecar might look). Attribute values win if a field
    /// somehow appears both ways.
    public static func parse(_ data: Data) throws -> LightroomXMPSettings {
        let xmlParser = XMLParser(data: data)
        let delegate = ParserDelegate()
        xmlParser.delegate = delegate
        guard xmlParser.parse() else { throw LightroomXMPError.invalidXML }
        guard !delegate.settings.isEmpty else { throw LightroomXMPError.noDevelopSettings }
        return delegate.settings
    }

    /// `Data(contentsOf: url)` + ``parse(_:)``, for a caller that only has the
    /// file's location.
    ///
    /// Brackets the read in `startAccessingSecurityScopedResource()` — the
    /// same rule `RPImport.ShotIngestor` follows for every URL a `.fileImporter`
    /// hands back. Without it, a `.xmp` outside the sandbox container reads as
    /// a permission failure that looked, from the outside, exactly like a bad
    /// file: a user reported a preset that opens fine in Lightroom itself
    /// rejected here as "not a valid .xmp" (2026-09-22), and the sidecar
    /// parsed perfectly once read directly — the read never got that far in
    /// the app because nothing had asked for access to it yet.
    public static func parse(contentsOf url: URL) throws -> LightroomXMPSettings {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try parse(try Data(contentsOf: url))
    }

    fileprivate final class ParserDelegate: NSObject, XMLParserDelegate {
        private(set) var settings = LightroomXMPSettings()
        private var currentText = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String]
        ) {
            currentText = ""
            guard Self.localName(of: elementName) == "Description" else { return }
            for (attribute, value) in attributeDict {
                apply(localName: Self.localName(of: attribute), rawValue: value)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let localName = Self.localName(of: elementName)
            defer { currentText = "" }
            guard localName != "Description" else { return }
            apply(localName: localName, rawValue: currentText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// Strips a namespace prefix (`"crs:Temperature"` → `"Temperature"`);
        /// matching on the local name alone tolerates whatever prefix the
        /// sidecar declared for the `camera-raw-settings` namespace.
        private static func localName(of qualifiedName: String) -> String {
            guard let colon = qualifiedName.lastIndex(of: ":") else { return qualifiedName }
            return String(qualifiedName[qualifiedName.index(after: colon)...])
        }

        private func apply(localName: String, rawValue: String) {
            guard !rawValue.isEmpty, let number = Double(rawValue) else { return }
            switch localName {
            case "Exposure2012": settings.exposure2012 = settings.exposure2012 ?? number
            case "Contrast2012": settings.contrast2012 = settings.contrast2012 ?? number
            case "Highlights2012": settings.highlights2012 = settings.highlights2012 ?? number
            case "Shadows2012": settings.shadows2012 = settings.shadows2012 ?? number
            case "Temperature": settings.temperatureKelvin = settings.temperatureKelvin ?? number
            case "IncrementalTemperature":
                settings.incrementalTemperature = settings.incrementalTemperature ?? number
            case "Tint": settings.tint = settings.tint ?? number
            case "IncrementalTint": settings.incrementalTint = settings.incrementalTint ?? number
            case "Vibrance": settings.vibrance = settings.vibrance ?? number
            case "Saturation": settings.saturation = settings.saturation ?? number
            case "SaturationAdjustmentRed": settings.saturationAdjustment["red"] = number
            case "SaturationAdjustmentOrange": settings.saturationAdjustment["orange"] = number
            case "SaturationAdjustmentYellow": settings.saturationAdjustment["yellow"] = number
            case "SaturationAdjustmentGreen": settings.saturationAdjustment["green"] = number
            case "SaturationAdjustmentAqua": settings.saturationAdjustment["aqua"] = number
            case "SaturationAdjustmentBlue": settings.saturationAdjustment["blue"] = number
            case "SaturationAdjustmentPurple": settings.saturationAdjustment["purple"] = number
            case "SaturationAdjustmentMagenta": settings.saturationAdjustment["magenta"] = number
            default: break
            }
        }
    }
}

extension LightroomXMPSettings {
    /// Maps this sidecar onto ``ColorSliders``' keys, **at full strength** —
    /// what a 100 % "Cường độ" (intensity) means when the file is imported.
    /// Only keys this sidecar actually declared are present; a caller blends
    /// each one in from the shot's current value, and leaves every key that is
    /// absent here untouched at any intensity.
    ///
    /// Two axes carry a sign-convention or scale translation rather than a
    /// direct copy:
    ///
    /// * `highlights` is **negated** — `ColorSliders.highlights`' positive means
    ///   *recovery* (darker), the opposite of Lightroom's Highlights slider
    ///   (docs for `ColorSliders.highlights`).
    /// * `wbTemperature` goes through ``WhiteBalance/amount(declaringKelvin:neutralKelvin:)``
    ///   when the sidecar carries an absolute Kelvin (`temperatureKelvin`),
    ///   the real inverse of the same Bradford/mired math the "Nhiệt độ"
    ///   slider itself uses — not a linear rescale. A non-raw sidecar's already
    ///   relative `incrementalTemperature` is used directly instead.
    public func colorSliderOverrides(
        neutralKelvin: Double = WhiteBalance.defaultNeutralKelvin
    ) -> [String: Double] {
        var overrides: [String: Double] = [:]
        let range = Slider.signedRange

        if let exposure2012 {
            // ColorSliders.exposure is ±100 for ±5 EV.
            overrides[ColorSliders.Key.exposure] = Slider.clamp(exposure2012 / 5 * 100, to: range)
        }
        if let contrast2012 {
            overrides[ColorSliders.Key.contrast] = Slider.clamp(contrast2012, to: range)
        }
        if let highlights2012 {
            overrides[ColorSliders.Key.highlights] = Slider.clamp(-highlights2012, to: range)
        }
        if let shadows2012 {
            overrides[ColorSliders.Key.shadows] = Slider.clamp(shadows2012, to: range)
        }
        if let temperatureKelvin {
            let amount = WhiteBalance.amount(declaringKelvin: temperatureKelvin, neutralKelvin: neutralKelvin)
            overrides[ColorSliders.Key.wbTemperature] = Slider.clamp(amount * 100, to: range)
        } else if let incrementalTemperature {
            overrides[ColorSliders.Key.wbTemperature] = Slider.clamp(incrementalTemperature, to: range)
        }
        if let tint {
            // Raw sidecars carry Tint on a roughly ±150 scale; this slider is ±100.
            overrides[ColorSliders.Key.wbTint] = Slider.clamp(tint / 150 * 100, to: range)
        } else if let incrementalTint {
            overrides[ColorSliders.Key.wbTint] = Slider.clamp(incrementalTint, to: range)
        }
        if let vibrance {
            overrides[ColorSliders.Key.vibrance] = Slider.clamp(vibrance, to: range)
        }
        if let saturation {
            overrides[ColorSliders.Key.saturation] = Slider.clamp(saturation, to: range)
        }
        for band in HueBand.allCases {
            guard let value = saturationAdjustment[String(describing: band)] else { continue }
            overrides[band.key] = Slider.clamp(value, to: range)
        }
        return overrides
    }
}
