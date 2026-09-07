import CoreGraphics
import Foundation
import Testing

@testable import RPVision

@Suite("FaceCrop geometry")
struct FaceCropTests {
    @Test("Crop centre maps to the ROI centre and the corners span the square")
    func cropToImageMapping() {
        let crop = FaceCrop(center: CGPoint(x: 100, y: 200), side: 512, rotation: 0)
        let center = crop.imagePoint(fromCrop: CGPoint(x: 128, y: 128))
        #expect(abs(center.x - 100) < 1e-9)
        #expect(abs(center.y - 200) < 1e-9)

        let topLeft = crop.imagePoint(fromCrop: .zero)
        #expect(abs(topLeft.x - (100 - 256)) < 1e-9)
        #expect(abs(topLeft.y - (200 - 256)) < 1e-9)

        let bottomRight = crop.imagePoint(fromCrop: CGPoint(x: 256, y: 256))
        #expect(abs(bottomRight.x - (100 + 256)) < 1e-9)
        #expect(abs(bottomRight.y - (200 + 256)) < 1e-9)
    }

    @Test("Rotation is clockwise in the y-down frame")
    func rotationDirection() {
        // 90 degrees: the crop's +x axis should point along image +y.
        let crop = FaceCrop(center: .zero, side: 256, rotation: .pi / 2)
        let right = crop.imagePoint(fromCrop: CGPoint(x: 256, y: 128))
        #expect(abs(right.x) < 1e-9)
        #expect(abs(right.y - 128) < 1e-9)
    }

    @Test("imageToCrop is the inverse of cropToImage")
    func roundTrip() {
        let crop = FaceCrop(center: CGPoint(x: 640, y: 480), side: 333, rotation: 0.37)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 12), CGPoint(x: 128, y: 200)] {
            let back = crop.cropPoint(fromImage: crop.imagePoint(fromCrop: point))
            #expect(abs(back.x - point.x) < 1e-6)
            #expect(abs(back.y - point.y) < 1e-6)
        }
    }

    @Test("mediaPipeStyle squares the long side, scales it and reads roll off the eyes")
    func mediaPipeROI() {
        let box = CGRect(x: 100, y: 50, width: 200, height: 300)
        let crop = FaceCrop.mediaPipeStyle(
            boundingBox: box,
            rightEye: CGPoint(x: 150, y: 100),
            leftEye: CGPoint(x: 250, y: 200),
            scale: 1.5)
        #expect(abs(crop.side - 450) < 1e-9)  // max(200, 300) * 1.5
        #expect(abs(crop.center.x - 200) < 1e-9)
        #expect(abs(crop.center.y - 200) < 1e-9)
        #expect(abs(crop.rotation - .pi / 4) < 1e-9)
    }

    @Test("Missing eye landmarks give an upright ROI instead of failing")
    func mediaPipeROIWithoutEyes() {
        let crop = FaceCrop.mediaPipeStyle(
            boundingBox: CGRect(x: 0, y: 0, width: 100, height: 100),
            rightEye: nil, leftEye: nil)
        #expect(crop.rotation == 0)
    }

    @Test("normalizeRadians wraps to (-pi, pi]")
    func normalizeRadians() {
        #expect(abs(FaceCrop.normalizeRadians(3 * .pi / 2) - (-.pi / 2)) < 1e-9)
        #expect(abs(FaceCrop.normalizeRadians(-3 * .pi / 2) - (.pi / 2)) < 1e-9)
        #expect(abs(FaceCrop.normalizeRadians(0.5) - 0.5) < 1e-9)
    }

    @Test("The Vision ROI scale is the value measured in spike S1")
    func visionScaleIsCalibrated() {
        // Changing this constant invalidates Research/spikes/S1-landmark/results/
        // accuracy_vs_mediapipe.json and a6300/results/{accuracy_vs_mediapipe,
        // roi_scale_pooled}.json — re-run both sweeps before you touch it.
        // 1.40 is the point-weighted minimum over the stock and the real-a6300
        // sets together (spike report §4 and §4a).
        #expect(FaceCrop.visionBoxScale == 1.40)
    }

    @Test("imagePoints applies the crop transform to every landmark")
    func imagePointsMapping() {
        let crop = FaceCrop(center: CGPoint(x: 10, y: 20), side: 256, rotation: 0)
        let result = FaceLandmarks478(
            cropPoints: [CGPoint(x: 128, y: 128), CGPoint(x: 0, y: 0)],
            depths: [0, 0], score: 1, crop: crop)
        #expect(result.imagePoints[0] == CGPoint(x: 10, y: 20))
        #expect(result.imagePoints[1] == CGPoint(x: -118, y: -108))
    }
}
