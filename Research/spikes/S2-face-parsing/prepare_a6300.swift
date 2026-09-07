// S2 spike — builds the real-camera set from the user's Sony a6300 ARW files.
//
//   for f in ../../data/*.ARW; do
//     sips -s format jpeg -s formatOptions best "$f" \
//          --out "a6300/images/full/$(basename "${f%.ARW}").jpg"
//   done
//   swift prepare_a6300.swift a6300/images/full a6300/images/raw
//
// Same idea as S1's script (EXIF orientation baked in, square crop around Vision's
// largest face, native resolution) with one difference that matters for parsing:
// **the framing is matched to CelebAMask-HQ**, not to S1's landmark ROI.
//
// Measured on the 30 CelebAMask-HQ test frames used in this spike
// (`evaluate_iou.py` data set): the ground-truth face bounding box is 0.535 of the
// frame width, i.e. the frame is 1.87 x face width, and the face centre sits at
// 54.4 % of the frame height — CelebA-HQ leaves more room above the face (hair)
// than below. S1's crops are 3.5 x face width and centred, which would show the
// model a face 3.4x smaller in area than anything it was trained on and make a
// "does it generalise" question unanswerable. Defaults here: k = 1.87,
// face centre at 0.544 of the crop height.
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
let positional = CommandLine.arguments.dropFirst(3).filter { !$0.hasPrefix("--") }
let k = CGFloat(positional.count > 0 ? Double(positional[positional.startIndex])! : 1.87)
let faceCentreY = CGFloat(
    positional.count > 1 ? Double(positional[positional.startIndex + 1])! : 0.544)
// `--upright` rotates the crop by -roll (Vision's estimate) before writing it, to
// test whether the parser's failures on rolled heads are a roll problem.
let derotate = CommandLine.arguments.contains("--upright")
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
    let faces = obs.sorted {
        $0.boundingBox.toImageCoordinates(size, origin: .upperLeft).width
            > $1.boundingBox.toImageCoordinates(size, origin: .upperLeft).width
    }
    let boxes = faces.map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
    guard let box = boxes.first, let face = faces.first else {
        print("\(url.lastPathComponent) no face")
        continue
    }
    let roll = CGFloat(face.roll.converted(to: .radians).value)
    var side = (max(box.width, box.height) * k).rounded()
    side = min(side, min(size.width, size.height))
    var x = (box.midX - side / 2).rounded()
    var y = (box.midY - side * faceCentreY).rounded()
    x = min(max(0, x), size.width - side)
    y = min(max(0, y), size.height - side)
    var cropped: CGImage?
    if derotate && abs(roll) > 0.005 {
        // Rotate about the face centre, then cut the same square out of the
        // rotated frame. Sampling once (rotate + crop in one CI pass) keeps this
        // to a single resample.
        let centre = CGPoint(x: box.midX, y: box.midY)
        let ci = CIImage(cgImage: image)
        // Core Image is y-up, the boxes here are y-down: flip, rotate, flip back.
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        // Sign checked against the rendered crops, not derived: Vision's roll is
        // positive for the head tilting one way and this chain rotates in the
        // y-down frame, so undoing it takes `+roll` here. Rotating by `-roll`
        // doubles the tilt instead — visible immediately in
        // a6300_upright/images/raw, and it dropped the parts-present count from
        // 9/11 to 7/11, which is how the sign error was caught.
        let rotate = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: CGFloat(roll))
            .translatedBy(x: -centre.x, y: -centre.y)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let rotated = ci.transformed(
            by: flipIn.concatenating(rotate).concatenating(flipOut),
            highQualityDownsample: true)
        let ciRect = CGRect(x: x, y: size.height - y - side, width: side, height: side)
        cropped = ciContext.createCGImage(rotated, from: ciRect)
    } else {
        cropped = image.cropping(to: CGRect(x: x, y: y, width: side, height: side))
    }
    guard let cropped else {
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
        "vision_roll_rad": Double(roll),
        "derotated": derotate,
        "crop_scale_k": Double(k),
        "face_centre_y_fraction": Double(faceCentreY),
    ])
    print(
        "\(url.lastPathComponent) or=\(orientation) img=\(image.width)x\(image.height) "
            + "faces=\(boxes.count) box=\(Int(box.width)) crop=\(Int(side)) at (\(Int(x)),\(Int(y)))")
}

let manifestURL = outDir.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("manifest.json")
let payload: [String: Any] = [
    "source": "Sony a6300 ARW in Research/data/, decoded with sips (ImageIO RAW), then "
        + "orientation-baked and cut to a square of k x face width around Vision's largest "
        + "face, framed to match CelebAMask-HQ (k = 1.87, face centre at 0.544 of height).",
    "crop_scale_k": Double(k),
    "face_centre_y_fraction": Double(faceCentreY),
    "derotated": derotate,
    "framing_source": "measured on the 30 CelebAMask-HQ test frames in images/gt",
    "images": manifest,
]
try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    .write(to: manifestURL)
print("wrote \(manifestURL.path) (\(manifest.count) images)")
