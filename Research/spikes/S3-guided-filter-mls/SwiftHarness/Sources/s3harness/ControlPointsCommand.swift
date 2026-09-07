import CoreGraphics
import Foundation
import RPEngine
import RPVision

/// `s3harness controlpoints <root>` — runs S1's Vision → 478-point landmark
/// pipeline on every full-resolution a6300 frame, builds a realistic face
/// reshape from the mesh, and writes the handles to `control/*.json`.
enum ControlPointsCommand {
    static func run(_ arguments: [String]) async throws {
        let paths = Harness.paths(arguments)
        guard FileManager.default.fileExists(atPath: paths.landmarkModel.path) else {
            throw Harness.Failure.missing(
                "S1 landmark model at \(paths.landmarkModel.path) — run spike S1's converter first")
        }
        RPVisionFeatureFlags.faceLandmarks478 = true
        defer { RPVisionFeatureFlags.faceLandmarks478 = false }
        let detector = try FaceLandmarkDetector(modelURL: paths.landmarkModel)

        var summary: [[String: Any]] = []
        for url in try Harness.imageURLs(paths) {
            let name = url.deletingPathExtension().lastPathComponent
            let image = try Harness.loadUpright(url)
            let size = CGSize(width: image.width, height: image.height)

            let meshes = try await detector.landmarks(in: image)
            // S1 §6: DSC05403 has two faces. Take the largest, the way an editor
            // would default to the subject.
            guard let mesh = meshes.max(by: { $0.crop.side < $1.crop.side }) else {
                FileHandle.standardError.write(Data("\(name): no face\n".utf8))
                continue
            }
            let points = mesh.imagePoints
            let reshape = FaceReshape.controlPoints(landmarks: points, imageSize: size)

            let file = ControlPointFile(
                image: name,
                imageWidth: image.width,
                imageHeight: image.height,
                faceWidth: reshape.faceWidth,
                maxDisplacementPx: reshape.maxDisplacement,
                sliders: [
                    "faceSlim": FaceReshape.Sliders().faceSlim,
                    "eyeEnlarge": FaceReshape.Sliders().eyeEnlarge,
                    "maxSlimFraction": FaceReshape.Sliders().maxSlimFraction,
                    "maxEyeGain": FaceReshape.Sliders().maxEyeGain,
                ],
                source: reshape.control.source.map { [Double($0.x), Double($0.y)] },
                destination: reshape.control.destination.map { [Double($0.x), Double($0.y)] })

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: paths.control, withIntermediateDirectories: true)
            let out = paths.control.appendingPathComponent("\(name).json")
            try encoder.encode(file).write(to: out)

            var record: [String: Any] = [
                "image": name,
                "image_size": [image.width, image.height],
                "faces_detected": meshes.count,
                "face_presence_score": Double(mesh.score),
                "face_width_px": reshape.faceWidth,
                "face_width_fraction_of_long_edge":
                    reshape.faceWidth / Double(max(image.width, image.height)),
                "control_points": reshape.control.count,
                "max_displacement_px": reshape.maxDisplacement,
                "max_displacement_over_face_width":
                    reshape.maxDisplacement / reshape.faceWidth,
            ]
            for (key, value) in reshape.checks { record["check_" + key] = value }
            summary.append(record)
            print(
                "\(name) faces=\(meshes.count) faceWidth=\(Int(reshape.faceWidth)) "
                    + "handles=\(reshape.control.count) maxMove=\(String(format: "%.1f", reshape.maxDisplacement))px")
        }

        // Aggregate the index-list checks so a single number says whether the
        // hard-coded MediaPipe rings are the rings they claim to be.
        let enclosing = summary.compactMap { $0["check_oval_encloses_fraction"] as? Double }
        let booleanChecks = [
            "check_left_eye_below_forehead", "check_right_eye_below_forehead",
            "check_left_eye_above_chin", "check_right_eye_above_chin",
            "check_eyes_on_opposite_sides_of_midline",
        ]
        var aggregate: [String: Any] = [
            "images": summary.count,
            "oval_encloses_fraction_min": enclosing.min() ?? 0,
            "oval_encloses_fraction_mean": Harness.mean(enclosing),
        ]
        for key in booleanChecks {
            aggregate[key + "_pass_count"] =
                summary.filter { ($0[key] as? Bool) == true }.count
        }
        aggregate["eye_separation_over_face_width_mean"] = Harness.mean(
            summary.compactMap { $0["check_eye_separation_over_face_width"] as? Double })

        try Harness.write(
            [
                "source": "Sony a6300 ARW in Research/data/, sips-decoded, EXIF orientation baked, "
                    + "RPVision Vision→FaceLandmark478 (spike S1) on the full-resolution frame.",
                "sliders": "faceSlim 60 / eyeEnlarge 40, deltas relative to face width",
                "environment": Harness.environment,
                "index_list_checks": aggregate,
                "images": summary,
            ] as [String: Any],
            to: paths.results.appendingPathComponent("control_points.json"))
    }
}
