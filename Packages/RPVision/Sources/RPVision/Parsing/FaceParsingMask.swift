import Foundation

/// A dense per-pixel class map: one `FaceParsingClass` raw value per pixel,
/// row-major, `width * height` bytes.
///
/// Kept as plain bytes rather than a `CVPixelBuffer` so it is `Sendable`, cheap to
/// hash for the Phase 2 analysis cache, and usable from tests with no GPU.
public struct FaceParsingMask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let labels: [UInt8]

    public init(width: Int, height: Int, labels: [UInt8]) {
        precondition(labels.count == width * height, "label buffer size mismatch")
        self.width = width
        self.height = height
        self.labels = labels
    }

    public subscript(x: Int, y: Int) -> FaceParsingClass {
        FaceParsingClass(rawValue: labels[y * width + x]) ?? .background
    }

    /// 0/255 coverage for one class union. 255 = member.
    public func binaryMask(for group: FaceParsingGroup) -> [UInt8] {
        binaryMask(for: group.classes)
    }

    public func binaryMask(for classes: [FaceParsingClass]) -> [UInt8] {
        var lookup = [UInt8](repeating: 0, count: 256)
        for c in classes { lookup[Int(c.rawValue)] = 255 }
        return labels.map { lookup[Int($0)] }
    }

    /// Pixel count per class, index = raw value. Used by the spike harness and by
    /// `FaceParsingModelTests` to assert the class mapping is the expected one.
    public func histogram() -> [Int] {
        var counts = [Int](repeating: 0, count: 19)
        for value in labels where value < 19 { counts[Int(value)] += 1 }
        return counts
    }

    /// Intersection-over-union of one class union against another mask of the same
    /// size. Returns `nil` when neither mask contains the class at all (IoU is
    /// undefined there, and averaging a 0 in would be a lie).
    public func intersectionOverUnion(
        _ other: FaceParsingMask, classes: [FaceParsingClass]
    ) -> Double? {
        precondition(width == other.width && height == other.height)
        var lookup = [Bool](repeating: false, count: 256)
        for c in classes { lookup[Int(c.rawValue)] = true }
        var intersection = 0
        var union = 0
        for i in 0..<labels.count {
            let a = lookup[Int(labels[i])]
            let b = lookup[Int(other.labels[i])]
            if a && b { intersection += 1 }
            if a || b { union += 1 }
        }
        return union == 0 ? nil : Double(intersection) / Double(union)
    }
}
