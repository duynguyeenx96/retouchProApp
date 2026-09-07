// S1 spike — builds the real-camera test set from the user's Sony a6300 ARW files.
//
//   Scripts/…: sips -s format jpeg -s formatOptions best Research/data/DSC*.ARW \
//                  --out a6300/images/full/DSC*.jpg          (ImageIO RAW decode, 6000x4000)
//   swift prepare_a6300.swift a6300/images/full a6300/images/raw 3.5
//
// What this does and why:
//  * bakes the EXIF orientation into the pixels (the a6300 writes orientation 8 for
//    portrait frames — Core Graphics ignores it, OpenCV applies it, so without this
//    the Swift and the Python side disagree about what "x, y" means);
//  * takes Vision's largest face box and cuts a square of `k` x face width around it,
//    at native resolution, no resampling.
//
// The crop is needed because MediaPipe's `blaze_face_short_range` detector — the one
// that produces the reference landmarks — sees the whole frame at 128x128 and misses a
// face that is only ~6..20 % of a 6000 px frame: on the full a6300 frames it found no
// face at all in DSC05193 / DSC05239 / DSC05259 / DSC05403 and no landmarks in
// DSC05146, at every scale from full-res down to 1400 px. Both pipelines are then fed
// exactly the same cropped pixels, so the comparison stays fair; the crop only decides
// the framing, which is what a tighter portrait lens would have given anyway.
//
// Writes <outDir>/../manifest.json with the provenance of every image.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let inDir = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let k = CGFloat(CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3])! : 3.5)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let urls = try FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "jpg" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

func upright(_ image: CGImage, _ orientation: UInt32) -> CGImage {
    if orientation <= 1 { return image }
    let ci = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
    return ciContext.createCGImage(ci, from: ci.extent) ?? image
}

var manifest: [[String: Any]] = []

for url in urls {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let raw = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        print("decode fail \(url.lastPathComponent)")
        continue
    }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
    let image = upright(raw, orientation)
    let size = CGSize(width: image.width, height: image.height)
    let request = DetectFaceRectanglesRequest()
    let obs = try await request.perform(on: image)
    let boxes = obs.map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
        .sorted { $0.width > $1.width }
    guard let box = boxes.first else {
        print("\(url.lastPathComponent) no face")
        continue
    }
    var side = (max(box.width, box.height) * k).rounded()
    side = min(side, min(size.width, size.height))
    var x = (box.midX - side / 2).rounded()
    var y = (box.midY - side / 2).rounded()
    x = min(max(0, x), size.width - side)
    y = min(max(0, y), size.height - side)
    guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
        print("crop fail \(url.lastPathComponent)")
        continue
    }
    let out = outDir.appendingPathComponent(url.lastPathComponent)
    guard
        let dest = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else {
        print("dest fail \(url.lastPathComponent)")
        continue
    }
    CGImageDestinationAddImage(
        dest, cropped, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        print("write fail \(url.lastPathComponent)")
        continue
    }
    manifest.append([
        "image": url.lastPathComponent,
        "source_raw": "Research/data/" + url.deletingPathExtension().lastPathComponent + ".ARW",
        "exif_orientation": Int(orientation),
        "upright_size": [image.width, image.height],
        "vision_faces": boxes.count,
        "vision_largest_box": [
            Double(box.origin.x), Double(box.origin.y), Double(box.width), Double(box.height),
        ],
        "crop_rect": [Double(x), Double(y), Double(side), Double(side)],
        "crop_scale_k": Double(k),
    ])
    print(
        "\(url.lastPathComponent) or=\(orientation) img=\(image.width)x\(image.height) "
            + "faces=\(boxes.count) box=\(Int(box.width)) crop=\(Int(side)) at (\(Int(x)),\(Int(y)))")
}

let manifestURL = outDir.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("manifest.json")
let payload: [String: Any] = [
    "source": "Sony a6300 ARW in Research/data/, decoded with sips (ImageIO RAW), then "
        + "orientation-baked and cut to a square of k x face width around Vision's largest face.",
    "crop_scale_k": Double(k),
    "images": manifest,
]
try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    .write(to: manifestURL)
print("wrote \(manifestURL.path) (\(manifest.count) images)")
