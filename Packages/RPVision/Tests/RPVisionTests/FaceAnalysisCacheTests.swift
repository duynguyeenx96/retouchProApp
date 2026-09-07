import CoreGraphics
import Foundation
import Testing

@testable import RPVision

@Suite("FaceAnalysis cache")
struct FaceAnalysisCacheTests {
    private func analysis(_ tag: Double) -> FaceAnalysis {
        FaceAnalysis(
            imageSize: CGSize(width: tag, height: tag), faces: [],
            options: FaceAnalyzerOptions())
    }

    private func key(_ hash: String, _ options: FaceAnalyzerOptions = FaceAnalyzerOptions())
        -> FaceAnalysisKey
    {
        FaceAnalysisKey(contentHash: hash, options: options)
    }

    @Test("Hits, misses and least-recently-used eviction")
    func lru() {
        var cache = FaceAnalysisCache(capacity: 2)
        #expect(cache.value(for: key("a")) == nil)
        #expect(cache.misses == 1)

        cache.store(analysis(1), for: key("a"))
        cache.store(analysis(2), for: key("b"))
        #expect(cache.value(for: key("a"))?.imageSize.width == 1)
        #expect(cache.hits == 1)

        // "a" was just read, so "b" is the least recently used and goes first.
        cache.store(analysis(3), for: key("c"))
        #expect(cache.count == 2)
        #expect(cache.evictions == 1)
        #expect(cache.peek(key("b")) == nil)
        #expect(cache.peek(key("a")) != nil)
        #expect(cache.peek(key("c")) != nil)
    }

    /// The failure mode this guards against is silent and wrong, not merely slow:
    /// an analysis produced without parsing must never be served to a caller that
    /// asked for parsing.
    @Test("Different options are a different key, not a hit")
    func optionsAreInTheKey() {
        var withParsing = FaceAnalyzerOptions()
        var withoutParsing = FaceAnalyzerOptions()
        withoutParsing.parsing = nil
        var otherScale = FaceAnalyzerOptions()
        otherScale.detectorRegionScale = 2.0
        withParsing.parsing = FaceAnalyzerOptions.ParsingOptions()

        #expect(key("h", withParsing) != key("h", withoutParsing))
        #expect(key("h", withParsing) != key("h", otherScale))
        #expect(key("h", withParsing) == key("h", FaceAnalyzerOptions()))
        #expect(key("h", withParsing) != key("other", withParsing))

        var cache = FaceAnalysisCache(capacity: 4)
        cache.store(analysis(1), for: key("h", withParsing))
        #expect(cache.peek(key("h", withoutParsing)) == nil)
    }

    /// `Hasher` is seeded per process, so a `hashValue`-based fingerprint would
    /// stop matching after a relaunch if the key is ever persisted. The fingerprint
    /// has to be a content digest.
    @Test("The options fingerprint is stable and content-derived")
    func fingerprintIsStable() {
        let a = FaceAnalyzerOptions().fingerprint
        let b = FaceAnalyzerOptions().fingerprint
        #expect(a == b)
        #expect(a.count == 16)
        var changed = FaceAnalyzerOptions()
        changed.landmarkROIScale = 1.4
        #expect(changed.fingerprint != a)
    }

    @Test("Pixel hash distinguishes images and survives a re-render")
    func pixelHash() throws {
        let url = try #require(Phase2Resources.detectorInput)
        let image = try #require(Phase2Resources.image(at: url))
        let again = try #require(Phase2Resources.image(at: url))
        #expect(FaceAnalysisKey.pixelHash(of: image) == FaceAnalysisKey.pixelHash(of: again))

        let cropped = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        #expect(FaceAnalysisKey.pixelHash(of: image) != FaceAnalysisKey.pixelHash(of: cropped))
    }

    @Test("removeAll empties the cache but keeps the counters")
    func removeAll() {
        var cache = FaceAnalysisCache(capacity: 2)
        cache.store(analysis(1), for: key("a"))
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.peek(key("a")) == nil)
        cache.resetStatistics()
        #expect(cache.hits == 0 && cache.misses == 0 && cache.evictions == 0)
    }
}

@Suite("ParsedFace mask helpers")
struct ParsedFaceTests {
    private func mask(_ labels: [UInt8], side: Int) -> ParsedFace {
        ParsedFace(
            mask: FaceParsingMask(width: side, height: side, labels: labels),
            region: CropRegion(
                center: CGPoint(x: 100, y: 100), side: 200, rotation: 0, outputSide: side))
    }

    @Test("Feathering softens the boundary and preserves the interior")
    func feathering() {
        // 32x32 with a 12x12 block of eye pixels in the middle (rows/cols 10..21).
        // Two box passes of radius r reach +-2r, so with r = 2 the ramp is 4 px wide
        // on each side and anything further in or out is untouched.
        let side = 32
        let radius = 2
        let reach = 2 * radius
        var labels = [UInt8](repeating: 0, count: side * side)
        for y in 10..<22 {
            for x in 10..<22 { labels[y * side + x] = FaceParsingClass.leftEye.rawValue }
        }
        let parsed = mask(labels, side: side)
        let hard = parsed.hardMask(for: .eyes)
        let soft = parsed.feathered(.eyes, radius: radius)
        let row = 16 * side

        #expect(hard[row + 16] == 255)
        #expect(soft[row + 16] == 255)  // deep interior stays fully covered
        // A pixel just outside the hard mask is zero there and non-zero here: that
        // is the whole point (spike S2 §4, eye IoU 0.84 is a +-1 px boundary error).
        #expect(hard[row + 22] == 0)
        #expect(soft[row + 22] > 0)
        // Coverage falls off monotonically going outwards, and reaches zero once
        // past the blur's support.
        let profile = (20...(21 + reach + 1)).map { soft[row + $0] }
        #expect(zip(profile, profile.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(soft[row + 21 + reach + 1] == 0)
        #expect(profile.first! > profile.last!)
    }

    @Test("Eye-adjacent groups are marked as needing a feathered mask")
    func featherAdvice() {
        #expect(FaceParsingGroup.eyes.requiresFeatheredMask)
        #expect(FaceParsingGroup.mouth.requiresFeatheredMask)
        #expect(FaceParsingGroup.lips.requiresFeatheredMask)
        #expect(!FaceParsingGroup.skin.requiresFeatheredMask)
        #expect(FaceParsingGroup.eyes.recommendedFeatherRadius >= 3)
    }

    /// CelebAMask-HQ has no teeth class (spike S2 §3c), so `FaceAnalysis` must not
    /// pretend it does. `FaceParsingGroup` has no `teeth` case and `ParsedFace`
    /// exposes the mouth interior under that name instead.
    @Test("There is no teeth group, only the mouth interior")
    func noTeethClass() {
        #expect(!FaceParsingGroup.allCases.contains { $0.rawValue.contains("teeth") })
        #expect(!FaceParsingClass.allCases.contains { $0.celebAMaskName.contains("teeth") })
        #expect(FaceParsingGroup.mouth.classes == [.mouth])

        let side = 4
        var labels = [UInt8](repeating: 0, count: side * side)
        labels[5] = FaceParsingClass.mouth.rawValue
        let parsed = mask(labels, side: side)
        #expect(parsed.mouthInterior()[5] == 255)
        #expect(parsed.mouthInterior().count(where: { $0 == 255 }) == 1)
    }

    @Test("partsPresent is false when the parse collapsed into flat skin")
    func partsPresent() {
        let side = 32
        // Everything skin: exactly the failure spike S2 §5 saw on the two most
        // rolled a6300 frames.
        let collapsed = mask(
            [UInt8](repeating: FaceParsingClass.skin.rawValue, count: side * side), side: side)
        #expect(!collapsed.partsPresent())
        #expect(collapsed.coverage()[Int(FaceParsingClass.skin.rawValue)] == 1.0)

        var labels = [UInt8](repeating: 0, count: side * side)
        var index = 0
        for cls: FaceParsingClass in [
            .skin, .hair, .nose, .leftBrow, .rightBrow, .upperLip, .lowerLip, .eyeglasses,
        ] {
            for _ in 0..<8 {
                labels[index] = cls.rawValue
                index += 1
            }
        }
        #expect(mask(labels, side: side).partsPresent())
    }
}
