import Foundation
import Testing

@testable import RPEngine

/// Parsing a Lightroom / Camera Raw `.xmp` sidecar and mapping it onto
/// ``ColorSliders``' keys (`LightroomXMPImport.swift`).
@Suite("Lightroom .xmp import")
struct LightroomXMPImportTests {

    /// The attribute form real Lightroom exports write: every `crs:` field is
    /// an attribute on `rdf:Description`.
    static let attributeForm = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            crs:Version="17.0"
            crs:ProcessVersion="15.4"
            crs:Temperature="5000"
            crs:Tint="+15"
            crs:Exposure2012="+1.25"
            crs:Contrast2012="+20"
            crs:Highlights2012="-30"
            crs:Shadows2012="+40"
            crs:Vibrance="+18"
            crs:Saturation="-5"
            crs:SaturationAdjustmentRed="+10"
            crs:SaturationAdjustmentAqua="-20"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

    /// The child-element form some tools write instead: same fields, as their
    /// own elements with the value as text content.
    static let elementForm = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
           <crs:Exposure2012>+0.50</crs:Exposure2012>
           <crs:Contrast2012>-10</crs:Contrast2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """

    // MARK: - Parsing

    @Test("Reads every field off rdf:Description's attributes")
    func parsesAttributeForm() throws {
        let settings = try LightroomXMPSettings.parse(Data(Self.attributeForm.utf8))
        #expect(settings.exposure2012 == 1.25)
        #expect(settings.contrast2012 == 20)
        #expect(settings.highlights2012 == -30)
        #expect(settings.shadows2012 == 40)
        #expect(settings.temperatureKelvin == 5000)
        #expect(settings.tint == 15)
        #expect(settings.vibrance == 18)
        #expect(settings.saturation == -5)
        #expect(settings.saturationAdjustment["red"] == 10)
        #expect(settings.saturationAdjustment["aqua"] == -20)
    }

    @Test("Reads fields written as child elements instead of attributes")
    func parsesElementForm() throws {
        let settings = try LightroomXMPSettings.parse(Data(Self.elementForm.utf8))
        #expect(settings.exposure2012 == 0.5)
        #expect(settings.contrast2012 == -10)
        #expect(settings.temperatureKelvin == nil)
    }

    @Test("Not XML throws invalidXML")
    func garbageThrowsInvalidXML() {
        #expect(throws: LightroomXMPError.invalidXML) {
            try LightroomXMPSettings.parse(Data("not xml at all <<<".utf8))
        }
    }

    @Test("Valid XML with none of the known fields throws noDevelopSettings")
    func unrelatedXMLThrowsNoDevelopSettings() {
        let xml = "<a><b>1</b></a>"
        #expect(throws: LightroomXMPError.noDevelopSettings) {
            try LightroomXMPSettings.parse(Data(xml.utf8))
        }
    }

    // MARK: - Mapping onto ColorSliders

    @Test("Exposure2012 (±5 EV) maps onto the ±100 exposure slider")
    func mapsExposure() {
        let settings = LightroomXMPSettings(exposure2012: 2.5)
        let overrides = settings.colorSliderOverrides()
        #expect(overrides[ColorSliders.Key.exposure] == 50)
    }

    @Test("Contrast, Shadows carry straight over; Highlights is negated")
    func mapsToneSignConventions() {
        let settings = LightroomXMPSettings(contrast2012: 20, highlights2012: -30, shadows2012: 40)
        let overrides = settings.colorSliderOverrides()
        #expect(overrides[ColorSliders.Key.contrast] == 20)
        #expect(overrides[ColorSliders.Key.highlights] == 30)
        #expect(overrides[ColorSliders.Key.shadows] == 40)
    }

    @Test("An absolute Kelvin temperature goes through WhiteBalance.amount, not a linear rescale")
    func mapsAbsoluteTemperatureThroughWhiteBalance() {
        let neutral = 6500.0
        let settings = LightroomXMPSettings(temperatureKelvin: 5000)
        let overrides = settings.colorSliderOverrides(neutralKelvin: neutral)
        let expected =
            WhiteBalance.amount(declaringKelvin: 5000, neutralKelvin: neutral) * 100
        #expect(overrides[ColorSliders.Key.wbTemperature] == expected)
        // 5000 K is cooler than the 6500 K neutral, so the slider should move
        // toward the "cooler" (negative) side.
        #expect(expected < 0)
    }

    @Test("A non-raw sidecar's already-relative IncrementalTemperature is used directly")
    func mapsIncrementalTemperatureDirectly() {
        let settings = LightroomXMPSettings(incrementalTemperature: 42)
        let overrides = settings.colorSliderOverrides()
        #expect(overrides[ColorSliders.Key.wbTemperature] == 42)
    }

    @Test("Raw Tint (±150) rescales onto the ±100 slider")
    func mapsRawTint() {
        let settings = LightroomXMPSettings(tint: 75)
        let overrides = settings.colorSliderOverrides()
        #expect(overrides[ColorSliders.Key.wbTint] == 50)
    }

    @Test("HSL saturation-adjustment bands map straight onto the matching HueBand key")
    func mapsHSLBands() {
        let settings = LightroomXMPSettings(saturationAdjustment: ["red": 10, "aqua": -20])
        let overrides = settings.colorSliderOverrides()
        #expect(overrides[HueBand.red.key] == 10)
        #expect(overrides[HueBand.aqua.key] == -20)
        #expect(overrides[HueBand.blue.key] == nil)
    }

    @Test("A field the sidecar never carried is absent from the overrides, not defaulted to 0")
    func absentFieldsAreNotOverrides() {
        let settings = LightroomXMPSettings(exposure2012: 1)
        let overrides = settings.colorSliderOverrides()
        #expect(overrides[ColorSliders.Key.exposure] != nil)
        #expect(overrides[ColorSliders.Key.contrast] == nil)
        #expect(overrides[ColorSliders.Key.curves] == nil)
    }

    @Test("Out-of-range values still clamp to the slider's own −100…100")
    func clampsExtremeValues() {
        let settings = LightroomXMPSettings(contrast2012: 500, vibrance: -900)
        let overrides = settings.colorSliderOverrides()
        #expect(overrides[ColorSliders.Key.contrast] == 100)
        #expect(overrides[ColorSliders.Key.vibrance] == -100)
    }
}
