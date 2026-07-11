//
//  SyntheticScanGenerator.swift
//  MANTATests
//
//  Generates a virtual scan of a known electrode net so the full detection
//  pipeline can be measured against ground truth without a device.
//
//  The real 3D electrode positions (from coordinates_*.xml) are treated as
//  truth. Synthetic cameras orbit the head; each electrode facing a camera is
//  projected with `PinholeCamera`, then emitted as a noisy "OCR read" (with
//  configurable pixel/depth noise, dropout, and label misreads). Those reads are
//  fed through the real `OCRElectrodeDetectionPipeline` via a combined
//  provider/recognizer, and the recovered positions are compared to truth.
//
//  Everything is seeded, so runs are reproducible.
//

import CoreGraphics
import Foundation
import simd
@testable import MANTA

/// Reproducible RNG (SplitMix64) so synthetic scans are deterministic.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SeededGenerator {
    /// Standard-normal sample via Box-Muller.
    mutating func nextGaussian() -> Float {
        let u1 = Float.random(in: 1e-6...1, using: &self)
        let u2 = Float.random(in: 0...1, using: &self)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// Knobs for how degraded the synthetic capture is.
struct SyntheticScanConfig {
    var pixelNoise: Float = 0        // std dev, pixels
    var depthNoise: Float = 0        // std dev, meters
    var dropoutRate: Float = 0       // fraction of visible disks not read
    var misreadRate: Float = 0       // fraction of reads given a wrong label
    var readConfidence: Float = 0.9
    var seed: UInt64 = 42
    /// Camera orbit.
    var azimuthStepDegrees: Float = 30
    /// Azimuth sweep of the orbit; narrow it to simulate a partial (e.g.
    /// front-only) scan that leaves some disks never seen.
    var azimuthRangeDegrees: ClosedRange<Float> = 0...360
    var elevationsDegrees: [Float] = [-10, 20, 50]
    var cameraDistance: Float = 0.30 // meters from head center
    /// Facing test: cos of the max angle between a disk's outward normal and the
    /// direction to the camera for it to be considered visible.
    var facingCosineThreshold: Float = 0.35
}

/// Output of a synthetic scan: pipeline inputs plus ground truth.
struct SyntheticScan {
    var observations: [CaptureObservation]
    var source: SyntheticFrameSource
    /// Electrode number -> true world position (meters, head-centered).
    var truth: [Int: SIMD3<Float>]
    /// Electrode numbers that were read at least once (correctly labeled).
    var emitted: Set<Int>
}

/// Combined frame provider + text recognizer backing a synthetic scan. Reads are
/// keyed by the per-frame `CGImage` identity so the pipeline's provider and
/// recognizer calls line up.
final class SyntheticFrameSource: DetectionFrameProvider, TextRecognizing {
    private var frames: [UUID: DetectionFrame] = [:]
    private var reads: [ObjectIdentifier: [RecognizedText]] = [:]

    func register(observationID: UUID, frame: DetectionFrame, reads recognized: [RecognizedText]) {
        frames[observationID] = frame
        reads[ObjectIdentifier(frame.image)] = recognized
    }

    func frame(for observation: CaptureObservation) -> DetectionFrame? {
        frames[observation.id]
    }

    func recognize(in image: CGImage, imageSize: SIMD2<Float>) throws -> [RecognizedText] {
        reads[ObjectIdentifier(image)] ?? []
    }
}

/// Returns the true depth for an emitted read (exact-match nearest lookup).
private struct SyntheticDepthSampler: DepthSampler {
    var samples: [(pixel: SIMD2<Float>, depth: Float)]

    func depth(atImagePixel pixel: SIMD2<Float>) -> Float? {
        var best: Float?
        var bestDistance = Float.greatestFiniteMagnitude
        for sample in samples {
            let distance = simd_distance(sample.pixel, pixel)
            if distance < bestDistance {
                bestDistance = distance
                best = sample.depth
            }
        }
        return best
    }
}

enum SyntheticScanGenerator {
    private static let imageWidth = 1920
    private static let imageHeight = 1440
    private static let fx: Float = 1400
    private static let fy: Float = 1400

    static func generate(layout: ElectrodeLayout, config: SyntheticScanConfig = SyntheticScanConfig()) -> SyntheticScan {
        var rng = SeededGenerator(seed: config.seed)
        let truth = headCenteredTruth(from: layout)
        let validNumbers = Array(truth.keys)

        let source = SyntheticFrameSource()
        var observations: [CaptureObservation] = []
        var emitted: Set<Int> = []

        for cameraToWorld in cameraPoses(config: config) {
            let cameraPosition = SIMD3<Float>(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
            let intrinsicsArray: [Float] = [fx, 0, 0, 0, fy, 0, Float(imageWidth) / 2, Float(imageHeight) / 2, 1]
            let transformArray = flatten(cameraToWorld)
            guard let camera = PinholeCamera(intrinsics: intrinsicsArray, transform: transformArray) else { continue }

            var reads: [RecognizedText] = []
            var depthSamples: [(pixel: SIMD2<Float>, depth: Float)] = []

            for (number, position) in truth {
                // Occlusion: the disk must face the camera.
                let outwardNormal = simd_normalize(position)
                let toCamera = simd_normalize(cameraPosition - position)
                guard simd_dot(outwardNormal, toCamera) > config.facingCosineThreshold else { continue }

                guard let projection = camera.project(position) else { continue }
                let pixel = projection.pixel
                guard pixel.x >= 0, pixel.x < Float(imageWidth), pixel.y >= 0, pixel.y < Float(imageHeight) else { continue }

                if Float.random(in: 0...1, using: &rng) < config.dropoutRate { continue }

                let noisyPixel = SIMD2<Float>(
                    pixel.x + rng.nextGaussian() * config.pixelNoise,
                    pixel.y + rng.nextGaussian() * config.pixelNoise
                )
                let noisyDepth = projection.depth + rng.nextGaussian() * config.depthNoise

                let isMisread = Float.random(in: 0...1, using: &rng) < config.misreadRate
                let labelNumber = isMisread ? wrongNumber(for: number, valid: validNumbers, rng: &rng) : number

                reads.append(RecognizedText(
                    text: String(labelNumber),
                    imageCenter: noisyPixel,
                    confidence: config.readConfidence
                ))
                depthSamples.append((noisyPixel, noisyDepth))
                if !isMisread { emitted.insert(number) }
            }

            let image = makeUniqueImage()
            let frame = DetectionFrame(image: image, camera: camera, depthSampler: SyntheticDepthSampler(samples: depthSamples))
            let observation = makeObservation(intrinsics: intrinsicsArray, transform: transformArray)
            source.register(observationID: observation.id, frame: frame, reads: reads)
            observations.append(observation)
        }

        return SyntheticScan(observations: observations, source: source, truth: truth, emitted: emitted)
    }

    // MARK: - Truth

    /// Electrode positions in meters, centered on the head centroid and scaled so
    /// the head radius is ~9 cm regardless of the source file's units.
    private static func headCenteredTruth(from layout: ElectrodeLayout) -> [Int: SIMD3<Float>] {
        let raw = layout.electrodes.reduce(into: [Int: SIMD3<Float>]()) { result, electrode in
            let c = electrode.coordinatePrior
            result[electrode.number] = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        }
        guard !raw.isEmpty else { return [:] }

        let centroid = raw.values.reduce(SIMD3<Float>(repeating: 0), +) / Float(raw.count)
        let radius = raw.values.map { simd_distance($0, centroid) }.max() ?? 1
        let scale = radius > 0 ? 0.09 / radius : 1

        return raw.mapValues { ($0 - centroid) * scale }
    }

    // MARK: - Cameras

    private static func cameraPoses(config: SyntheticScanConfig) -> [simd_float4x4] {
        var poses: [simd_float4x4] = []
        var azimuth: Float = config.azimuthRangeDegrees.lowerBound
        while azimuth < config.azimuthRangeDegrees.upperBound {
            for elevation in config.elevationsDegrees {
                let az = azimuth * .pi / 180
                let el = elevation * .pi / 180
                let position = SIMD3<Float>(
                    config.cameraDistance * cos(el) * sin(az),
                    config.cameraDistance * sin(el),
                    config.cameraDistance * cos(el) * cos(az)
                )
                poses.append(lookAt(position: position))
            }
            azimuth += config.azimuthStepDegrees
        }
        return poses
    }

    /// Camera-to-world for a camera at `position` looking at the origin.
    /// ARKit convention: camera looks down its -z, so +z points back toward the
    /// camera (away from the target).
    private static func lookAt(position: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(position) // origin -> camera is +z
        var up = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(up, z)) > 0.99 { up = SIMD3<Float>(0, 0, 1) }
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(
            SIMD4<Float>(x, 0),
            SIMD4<Float>(y, 0),
            SIMD4<Float>(z, 0),
            SIMD4<Float>(position, 1)
        )
    }

    // MARK: - Helpers

    private static func wrongNumber(for number: Int, valid: [Int], rng: inout SeededGenerator) -> Int {
        guard valid.count > 1 else { return number }
        var candidate = number
        while candidate == number {
            candidate = valid[Int.random(in: 0..<valid.count, using: &rng)]
        }
        return candidate
    }

    private static func flatten(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
        ]
    }

    private static func makeUniqueImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private static func makeObservation(intrinsics: [Float], transform: [Float]) -> CaptureObservation {
        CaptureObservation(
            capturedAt: Date(),
            cameraTransform: transform,
            cameraIntrinsics: intrinsics,
            imageResolution: ImageResolution(width: imageWidth, height: imageHeight),
            hasSceneDepth: true,
            meshAnchorCount: 0,
            trackingSummary: "Normal",
            cameraSnapshotFilename: "synthetic.jpg",
            depthSnapshotFilename: nil,
            rawDepthFilename: nil,
            rawDepthFormat: nil,
            rawConfidenceFilename: nil,
            rawConfidenceFormat: nil,
            confidenceSummary: nil,
            depthSummary: nil
        )
    }
}

/// Error statistics of recovered electrodes vs. truth.
struct DetectionAccuracy {
    var recoveredCount: Int
    var emittedCount: Int
    var meanErrorMeters: Float
    var medianErrorMeters: Float
    var maxErrorMeters: Float
    /// Recovered electrodes whose position error exceeds a gross threshold
    /// (e.g. a surviving misread), count.
    var grossErrorCount: Int
    /// Gross-error electrodes still marked `.detected` — i.e. missed by both
    /// fusion and neighbor validation.
    var grossErrorAmongDetectedCount: Int

    static func compare(
        annotations: [ElectrodeAnnotation],
        truth: [Int: SIMD3<Float>],
        grossThresholdMeters: Float = 0.01
    ) -> DetectionAccuracy {
        var errors: [Float] = []
        var gross = 0
        var grossAmongDetected = 0

        for annotation in annotations {
            guard annotation.label.hasPrefix("E"), let number = Int(annotation.label.dropFirst()),
                  let truePosition = truth[number] else { continue }
            let recovered = SIMD3<Float>(
                Float(annotation.coordinate.x),
                Float(annotation.coordinate.y),
                Float(annotation.coordinate.z)
            )
            let error = simd_distance(recovered, truePosition)
            errors.append(error)
            if error > grossThresholdMeters {
                gross += 1
                if annotation.state == .detected { grossAmongDetected += 1 }
            }
        }

        let sorted = errors.sorted()
        let mean = errors.isEmpty ? 0 : errors.reduce(0, +) / Float(errors.count)
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]

        return DetectionAccuracy(
            recoveredCount: errors.count,
            emittedCount: errors.count,
            meanErrorMeters: mean,
            medianErrorMeters: median,
            maxErrorMeters: sorted.last ?? 0,
            grossErrorCount: gross,
            grossErrorAmongDetectedCount: grossAmongDetected
        )
    }
}
