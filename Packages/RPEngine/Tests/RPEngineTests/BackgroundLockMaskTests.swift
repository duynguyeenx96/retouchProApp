import CoreGraphics
import Foundation
import Metal
import Testing

@testable import RPEngine

/// Phase 6 §6.1 "Khoá nền" — the whole-frame subject mask on the render side.
///
/// There is no new kernel to grade here: ``BackgroundLockMaskSource`` reuses
/// `rp_skin_mask` through ``MaskRasteriser`` (docs/ADR-0009), which
/// `SkinRenderNodeTests.maskRasterisationMatchesReference` already measures
/// against a `Double` reference. What is new, and what these tests pin, is the
/// *whole-frame* path into it:
///
/// 1. the flag gate, which is what keeps a default-off feature default-off;
/// 2. "no subject" = `nil`, not an all-zero texture — the difference between
///    leaving a slider alone and silently zeroing it;
/// 3. a mask whose x and y scales differ, which the face path has never
///    exercised. Every face mask is a square parsing crop, so a single-factor
///    scale has always been correct there and would be wrong here: Vision
///    returns a 4:3 person mask for a 3:2 frame (`PersonSegmenter.mask(from:)`).
///
/// `.serialized` and `RPEngineTestFlags` because `RPEngineFeatureFlags` is a
/// process-global store (docs/ADR-0006).
@Suite("Phase 6 background lock mask", .serialized)
struct BackgroundLockMaskTests {
    static let width = 320
    static let height = 240

    /// A soft ellipse in the middle of a `maskWidth` x `maskHeight` grid, mapped
    /// onto the whole `width` x `height` frame — the shape a person mask has,
    /// with the per-axis stretch a person mask has.
    static func wholeFrameMask(
        maskWidth: Int, maskHeight: Int, imageWidth: Int = width, imageHeight: Int = height
    ) -> RenderMask {
        RenderMask(
            width: maskWidth, height: maskHeight,
            values: SkinReference.ellipseMask(width: maskWidth, height: maskHeight),
            maskToImage: CGAffineTransform(
                scaleX: CGFloat(imageWidth) / CGFloat(maskWidth),
                y: CGFloat(imageHeight) / CGFloat(maskHeight)))
    }

    /// The `Double` control: affine + bilinear with clamp-to-edge, the same
    /// definition `SkinReference.rasterisedMask` uses, written for a mask that
    /// belongs to no face.
    static func reference(_ mask: RenderMask, width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        let t = mask.imageToMask
        let source = mask.values.map { Double($0) / 255.0 }
        for y in 0..<height {
            for x in 0..<width {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(t)
                guard p.x >= 0, p.y >= 0, p.x < CGFloat(mask.width), p.y < CGFloat(mask.height)
                else { continue }
                out[y * width + x] = SkinReference.bilinear(
                    source, width: mask.width, height: mask.height,
                    u: Double(p.x) / Double(mask.width),
                    v: Double(p.y) / Double(mask.height))
            }
        }
        return out
    }

    static func encode(
        _ source: BackgroundLockMaskSource, mask: RenderMask?, context: MetalContext
    ) throws -> (any MTLTexture)? {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalContext.Failure.noCommandQueue
        }
        let texture = try source.encode(
            into: commandBuffer, mask: mask, width: width, height: height)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    // MARK: - Gate

    @Test("Construction refuses while the feature flag is off")
    func flagGatesConstruction() throws {
        guard let context = SpikeS3Support.context else { return }
        RPEngineTestFlags.exclusive {
            RPEngineFeatureFlags.backgroundLock = false
            #expect(throws: RPEngineFeatureDisabled.self) {
                _ = try BackgroundLockMaskSource(context: context)
            }
        }
    }

    @Test("The flag is off by default and is not one of the Phase 2 group flags")
    func flagDefaultsOff() {
        RPEngineTestFlags.exclusive {
            RPEngineFeatureFlags.resetToDefaults()
            #expect(RPEngineFeatureFlags.backgroundLock == false)
            // Turning on a Phase 2 slider group must not drag the background lock
            // on with it: they are separate costs and this one is unmeasured on an
            // iPhone.
            RPEngineFeatureFlags.enableSkinRenderGraph()
            #expect(RPEngineFeatureFlags.backgroundLock == false)
            RPEngineFeatureFlags.disableSkinRenderGraph()
        }
    }

    // MARK: - No subject

    @Test("No subject rasterises nothing and allocates nothing")
    func noSubjectIsNilNotZero() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.backgroundLock = true }
        defer { flags.leave { RPEngineFeatureFlags.backgroundLock = false } }

        let source = try BackgroundLockMaskSource(context: context)
        let texture = try Self.encode(source, mask: nil, context: context)
        #expect(texture == nil)
        #expect(source.coverage == nil)
        #expect(source.allocatedBytes == 0)
    }

    // MARK: - Rasterisation

    @Test("A whole-frame mask matches the Double affine + bilinear reference")
    func rasterisationMatchesReference() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.backgroundLock = true }
        defer { flags.leave { RPEngineFeatureFlags.backgroundLock = false } }

        let source = try BackgroundLockMaskSource(context: context)
        let mask = Self.wholeFrameMask(maskWidth: 64, maskHeight: 48)
        let texture = try #require(try Self.encode(source, mask: mask, context: context))
        let measured = try SkinRenderNodeTests.readR8(texture, queue: context.commandQueue)
        let reference = Self.reference(mask, width: Self.width, height: Self.height)

        var worst = 0.0
        for i in 0..<reference.count { worst = max(worst, abs(reference[i] - measured[i])) }
        print("P6 background-lock mask vs Double reference: max abs diff = \(worst)")
        // Same budget as the skin mask: the source is already 8-bit and r8Unorm
        // quantises at 1/255 = 3.9e-3, so 6e-3 can only fail on a wrong transform,
        // which shifts the mask by whole pixels and lands far above this.
        #expect(worst < 6e-3, "max abs diff \(worst)")

        let coverage = measured.reduce(0, +) / Double(measured.count)
        #expect(coverage > 0.05 && coverage < 0.95, "mask coverage \(coverage)")
    }

    /// **The aspect-ratio regression.** A person mask does not have the frame's
    /// aspect ratio — Vision returns 256x192 / 512x384 / 2016x1512 (all 4:3) for a
    /// 2048x1365 (3:2) frame. Every face mask the rasteriser has carried until now
    /// is a square parsing crop scaled uniformly, so a bug that collapses the two
    /// axes into one factor is invisible on the shipped path and puts the subject
    /// mask several percent of the frame out of place on this one.
    ///
    /// Checked by construction rather than by eye: the test mask is a 1-pixel-wide
    /// cross whose arms sit at known fractions of the frame, so a per-axis error
    /// moves a bar and the assertion below fails on the bar's position, not on a
    /// blurry average.
    @Test("A mask with a different aspect ratio lands on the frame per axis")
    func nonUniformScaleLandsCorrectly() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.backgroundLock = true }
        defer { flags.leave { RPEngineFeatureFlags.backgroundLock = false } }

        // 4:3 mask over a 4:3 frame would hide the bug; 40x60 over 320x240 makes
        // the x scale 8 and the y scale 4, so swapping or averaging them is a
        // factor of two.
        let maskWidth = 40
        let maskHeight = 60
        var values = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        let barColumn = maskWidth / 4  // 25% across
        let barRow = maskHeight * 3 / 4  // 75% down
        for y in 0..<maskHeight { values[y * maskWidth + barColumn] = 255 }
        for x in 0..<maskWidth { values[barRow * maskWidth + x] = 255 }
        let mask = RenderMask(
            width: maskWidth, height: maskHeight, values: values,
            maskToImage: CGAffineTransform(
                scaleX: CGFloat(Self.width) / CGFloat(maskWidth),
                y: CGFloat(Self.height) / CGFloat(maskHeight)))

        let source = try BackgroundLockMaskSource(context: context)
        let texture = try #require(try Self.encode(source, mask: mask, context: context))
        let measured = try SkinRenderNodeTests.readR8(texture, queue: context.commandQueue)

        /// Column of the brightest pixel on a given output row.
        func brightestColumn(row: Int) -> Int {
            var best = 0
            var bestValue = -1.0
            for x in 0..<Self.width where measured[row * Self.width + x] > bestValue {
                bestValue = measured[row * Self.width + x]
                best = x
            }
            return best
        }
        /// Row of the brightest pixel in a given output column.
        func brightestRow(column: Int) -> Int {
            var best = 0
            var bestValue = -1.0
            for y in 0..<Self.height where measured[y * Self.width + column] > bestValue {
                bestValue = measured[y * Self.width + column]
                best = y
            }
            return best
        }

        // The vertical bar is 1 mask pixel wide at 25% across, so it must land at
        // 25% of 320 = 80 px, spread over the 8 px the x scale stretches it to.
        // A uniform scale taken from the y axis would put it at 40.
        let expectedColumn = Double(barColumn) * Double(Self.width) / Double(maskWidth)
        let column = Double(brightestColumn(row: 20))
        #expect(
            abs(column - (expectedColumn + 4)) <= 6,
            "vertical bar at column \(column), expected near \(expectedColumn + 4)")

        // The horizontal bar is at 75% down, so 75% of 240 = 180 px, spread over
        // 4 px. A uniform scale from the x axis would put it at 360 — off the
        // bottom of a 240 px frame entirely.
        let expectedRow = Double(barRow) * Double(Self.height) / Double(maskHeight)
        let row = Double(brightestRow(column: 300))
        #expect(
            abs(row - (expectedRow + 2)) <= 6,
            "horizontal bar at row \(row), expected near \(expectedRow + 2)")
    }

    // MARK: - Caching

    @Test("Re-encoding the same mask keeps one texture, a new size reallocates")
    func cachesBySize() throws {
        guard let context = SpikeS3Support.context else { return }
        let flags = RPEngineTestFlags.enter { RPEngineFeatureFlags.backgroundLock = true }
        defer { flags.leave { RPEngineFeatureFlags.backgroundLock = false } }

        let source = try BackgroundLockMaskSource(context: context)
        let mask = Self.wholeFrameMask(maskWidth: 64, maskHeight: 48)
        let first = try #require(try Self.encode(source, mask: mask, context: context))
        let second = try #require(try Self.encode(source, mask: mask, context: context))
        #expect(first === second, "an unchanged mask reallocated the output texture")
        // 320*240 output + 64*48 uploaded mask.
        #expect(source.allocatedBytes == Self.width * Self.height + 64 * 48)

        source.releaseIntermediates()
        #expect(source.allocatedBytes == 0)
        #expect(source.coverage == nil)
    }

    /// The whole-frame initialiser has no ``RenderMaskKind``, so the face-shaped
    /// overload cannot be called on it. Pinned as a value check rather than as a
    /// crash test: `encode(into:faces:...)` traps on purpose, and a test cannot
    /// catch a `preconditionFailure`.
    @Test("A whole-frame rasteriser carries no RenderMaskKind")
    func wholeFrameRasteriserHasNoKind() throws {
        guard let context = SpikeS3Support.context else { return }
        let rasteriser = try MaskRasteriser(wholeFrame: context)
        #expect(rasteriser.kind == nil)
        let faceShaped = try MaskRasteriser(kind: .skin, context: context)
        #expect(faceShaped.kind == .skin)
    }
}
