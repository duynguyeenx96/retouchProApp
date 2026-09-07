import Foundation

// Spike S3 measurement harness.
//
//   swift run -c release s3harness controlpoints ..   # RPVision -> control/*.json
//   swift run -c release s3harness bench         ..   # results/bench_macos.json
//   swift run -c release s3harness accuracy      ..   # results/accuracy.json
//   swift run -c release s3harness mlsgpu        ..   # results/mls_gpu_vs_cpu.json
//   swift run -c release s3harness mps           ..   # results/mps_control.json
//
// Everything writes JSON under <root>/results/. Nothing here concludes anything
// from an image: there is no image output at all, only numbers.

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "help"

do {
    switch command {
    case "controlpoints":
        try await ControlPointsCommand.run(arguments)
    case "bench":
        try BenchCommand.run(arguments)
    case "accuracy":
        try AccuracyCommand.run(arguments)
    case "mlsgpu":
        try MLSGPUAccuracyCommand.run(arguments)
    case "mps":
        try MPSControlCommand.run(arguments)
    default:
        print("usage: s3harness <controlpoints|bench|accuracy|mlsgpu|mps> <root>")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
