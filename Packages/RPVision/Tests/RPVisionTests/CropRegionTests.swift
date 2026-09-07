import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing

@testable import RPVision

@Suite("CropRegion geometry")
struct CropRegionTests {
    @Test("A CropRegion at 256 is the same map as the FaceCrop it came from")
    func agreesWithFaceCrop() {
        let crop = FaceCrop(center: CGPoint(x: 640, y: 480), side: 333, rotation: 0.37)
        let region = CropRegion(crop)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 12), CGPoint(x: 128, y: 200)] {
            let a = crop.imagePoint(fromCrop: point)
            let b = region.imagePoint(fromOutput: point)
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9)
        }
        #expect(region.faceCrop == crop)
    }

    @Test("Normalised mapping is independent of the output side")
    func normalisedMapping() {
        let a = CropRegion(
            center: CGPoint(x: 100, y: 200), side: 512, rotation: 0.2, outputSide: 128)
        let b = CropRegion(
            center: CGPoint(x: 100, y: 200), side: 512, rotation: 0.2, outputSide: 512)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.3, y: 0.9)] {
            let pa = a.imagePoint(fromNormalized: point)
            let pb = b.imagePoint(fromNormalized: point)
            #expect(abs(pa.x - pb.x) < 1e-9 && abs(pa.y - pb.y) < 1e-9)
        }
        // ... and it agrees with the output-pixel mapping.
        let viaOutput = a.imagePoint(fromOutput: CGPoint(x: 128 * 0.25, y: 128 * 0.75))
        let viaNormalised = a.imagePoint(fromNormalized: CGPoint(x: 0.25, y: 0.75))
        #expect(abs(viaOutput.x - viaNormalised.x) < 1e-9)
        #expect(abs(viaOutput.y - viaNormalised.y) < 1e-9)
    }

    @Test("outputToImage round-trips at every output side")
    func roundTrip() {
        for side in [128, 256, 512] {
            let region = CropRegion(
                center: CGPoint(x: 3, y: -7), side: 91, rotation: -1.1, outputSide: side)
            let point = CGPoint(x: CGFloat(side) * 0.31, y: CGFloat(side) * 0.62)
            let back = region.outputPoint(fromImage: region.imagePoint(fromOutput: point))
            #expect(abs(back.x - point.x) < 1e-6 && abs(back.y - point.y) < 1e-6)
        }
    }
}

@Suite("CropRegionRenderer")
struct CropRegionRendererTests {
    private func bytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        return Array(
            UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self), count: stride * height))
    }

    /// The reason `CropRegionRenderer` can be used for the mesh path at all: it has
    /// to be the same resampler spike S1 calibrated `FaceCrop.visionBoxScale` and
    /// measured 0.193 px with. Byte equality, not a tolerance.
    @Test("At 256 it is byte-identical to FaceCropRenderer")
    func matchesFaceCropRenderer() throws {
        let inputURL = try #require(Phase2Resources.detectorInput)
        let image = try #require(Phase2Resources.image(at: inputURL))
        let crop = FaceCrop(center: CGPoint(x: 60, y: 70), side: 96, rotation: 0.3)

        let context = CIContextBox.shared
        let a = try FaceCropRenderer(context: context).render(image, crop: crop)
        let b = try CropRegionRenderer(context: context).render(image, region: CropRegion(crop))
        #expect(CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b))
        #expect(bytes(a) == bytes(b))
    }

    @Test("Renders the side the region asks for")
    func honoursOutputSide() throws {
        let inputURL = try #require(Phase2Resources.detectorInput)
        let image = try #require(Phase2Resources.image(at: inputURL))
        let renderer = CropRegionRenderer()
        for side in [128, 256, 512] {
            let region = CropRegion(
                center: CGPoint(x: 64, y: 64), side: 128, rotation: 0, outputSide: side)
            let buffer = try renderer.render(image, region: region)
            #expect(CVPixelBufferGetWidth(buffer) == side)
            #expect(CVPixelBufferGetHeight(buffer) == side)
            #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        }
    }
}

/// One `CIContext` for the equality test — two contexts can pick different GPU
/// paths and produce pixels that differ in the last bit, which would make the
/// byte-equality assertion above flaky for a reason that has nothing to do with
/// the code under test.
enum CIContextBox {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}
