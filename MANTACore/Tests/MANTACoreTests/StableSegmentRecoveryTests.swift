#if os(macOS)
import Compression
import Foundation
import Testing
import simd
@testable import MANTACore
import MANTAProcessing

struct StableSegmentRecoveryTests {
    @Test func derivesUsablePackageWithoutChangingSources() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture(in: root, offset: 0)
        let second = try fixture(in: root, offset: 0.09)
        let originals = try [first, second].map { try Data(contentsOf: URL(fileURLWithPath: $0.bundlePath).appendingPathComponent("capture.json")) }
        let output = root.appendingPathComponent("derived")
        let request = StableSegmentRecoveryRequest(acquisitionGroupID: "synthetic-same-head", segments: [first, second])
        let report = try StableSegmentRecovery.run(request, output: output, emitDerived: true)
        #expect(report.accepted)
        #expect(report.entries.allSatisfy { $0.rejectedFrameIDs.isEmpty && $0.captureSHA256.count == 64 })
        let package = try #require(FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).first { $0.pathExtension == "manta" })
        let bundle = try MANTABundleValidator().validate(directory: package)
        #expect(bundle.integrityWarnings.isEmpty)
        #expect(bundle.capture.observations.count == 8)
        #expect(bundle.capture.fiducials == nil && bundle.capture.electrodes == nil)
        try CaptureMotionPolicy.requireStationary(bundle.capture.observations.map(\.quality))
        for observation in bundle.capture.observations {
            #expect(observation.quality?.motionAssessment?.state == .suspected)
            let correction = try #require(observation.quality?.motionCorrection)
            #expect(correction.runID == report.runID)
            #expect(abs(observation.cameraToWorld[12]) < 0.001)
            if correction.sourceSegmentID == second.segmentID {
                #expect(abs(correction.originalCameraToWorld[12] - 0.09) < 0.00001)
                #expect(abs(correction.referenceFromSource[12] + 0.09) < 0.001)
            }
        }
        for (index, source) in [first, second].enumerated() {
            #expect(try Data(contentsOf: URL(fileURLWithPath: source.bundlePath).appendingPathComponent("capture.json")) == originals[index])
            let originalBundle = try MANTABundleValidator().validate(directory: URL(fileURLWithPath: source.bundlePath))
            #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireStationary(originalBundle.capture.observations.map(\.quality)) }
        }
        #expect(throws: (any Error).self) { try StableSegmentRecovery.run(request, output: output, emitDerived: true) }
        #expect(throws: (any Error).self) { try StableSegmentRecovery.run(request, output: URL(fileURLWithPath: first.bundlePath).appendingPathComponent("inside")) }
        // A changed derived pose cannot silently retain the correction's provenance.
        var corrupt = bundle.capture
        corrupt.observations[0].cameraToWorld[12] += 0.02
        try MANTAJSON.canonicalData(corrupt).write(to: package.appendingPathComponent("capture.json"))
        #expect(throws: (any Error).self) { try MANTABundleValidator().validate(directory: package) }
    }

    @Test func rejectsUnstableFrameEvenWhenAggregateHasOverlap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture(in: root, offset: 0)
        let second = try fixture(in: root, offset: 0.09, movedFrame: true)
        let output = root.appendingPathComponent("rejected")
        let report = try StableSegmentRecovery.run(.init(acquisitionGroupID: "synthetic", segments: [first, second]), output: output, emitDerived: true)
        #expect(!report.accepted)
        #expect(!report.entries[1].rejectedFrameIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("registration.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).allSatisfy { !$0.hasSuffix(".manta") })
    }

    @Test func requiresReviewAndNearbyDepthForStills() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture(in: root, offset: 0)
        var second = try fixture(in: root, offset: 0.09, distantStill: true)
        let output = root.appendingPathComponent("invalid")
        #expect(throws: (any Error).self) {
            try StableSegmentRecovery.run(.init(acquisitionGroupID: "synthetic", segments: [first, second]), output: output)
        }
        second.observationIDs.removeLast()
        second.reviewedStable = false
        #expect(throws: (any Error).self) {
            try StableSegmentRecovery.run(.init(acquisitionGroupID: "synthetic", segments: [first, second]), output: output)
        }
        second.reviewedStable = true
        let report = try StableSegmentRecovery.run(.init(acquisitionGroupID: "synthetic", segments: [first, second]), output: output)
        #expect(report.accepted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).allSatisfy { !$0.hasSuffix(".manta") })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(in root: URL, offset: Double, movedFrame: Bool = false, distantStill: Bool = false) throws -> StableSegmentRecoveryRequest.Segment {
        let segmentID = UUID()
        let staging = root.appendingPathComponent(segmentID.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let values: [Float] = (0..<1024).map { i in
            let x = Float(i % 32) / 31
            let y = Float(i / 32) / 31
            return 0.47 + 0.025 * sin(x * 5) + 0.02 * cos(y * 4)
        }
        let depthData = values.withUnsafeBytes { Data($0) }
        let depthURL = staging.appendingPathComponent("depth.zlib")
        let confidenceURL = staging.appendingPathComponent("confidence.zlib")
        let imageURL = staging.appendingPathComponent("image.png")
        try compressed(depthData).write(to: depthURL)
        try compressed(Data(repeating: 2, count: 1024)).write(to: confidenceURL)
        // Image pixels are not decoded by registration. Keep a real tiny PNG as provenance.
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF4sAAAAASUVORK5CYII=")!.write(to: imageURL)
        var observations: [MANTACaptureObservation] = []
        for index in 0..<4 {
            var pose = matrix_identity_float4x4
            pose.columns.3.x = Float(offset)
            if movedFrame && index == 2 { pose.columns.3.z = 0.1 }
            var quality = CaptureQualityMetrics(arFrameTimestamp: Double(index), worldMappingStatus: "mapped",
                ambientIntensity: nil, ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0,
                brightPixelFraction: 0, sharpnessScore: 1, translationFromPreviousSampleMeters: nil,
                rotationFromPreviousSampleDegrees: nil, coverageSector: "front")
            quality.motionAssessment = .init(segmentID: segmentID, state: .suspected)
            let time = distantStill && index == 3 ? 100.0 : Double(index) * 0.2
            observations.append(.init(id: UUID(), capturedAt: Date(timeIntervalSince1970: time), imagePath: "image.png",
                imageDimensions: .init(width: 32, height: 32), intrinsics: [120,0,0, 0,120,0, 16,16,1],
                cameraToWorld: SegmentRegistration.flatten(pose).map(Double.init),
                depth: index < 3 ? .init(path: "depth.zlib", confidencePath: "confidence.zlib", dimensions: .init(width: 32, height: 32)) : nil,
                trackingState: "normal", quality: quality))
        }
        let capture = MANTACaptureDocument(schema: MANTABundleFormat.captureSchema, sessionID: UUID(), captureMode: "both",
            layoutID: "hydrocel-128", coordinateSystems: [.init(id: "arkit-world", handedness: "right", units: .meters, description: "synthetic")],
            observations: observations)
        let package = try MANTABundleFinalizer().finalize(.init(capture: capture,
            producer: .init(application: "test", version: "1", build: "1", platform: "test", operatingSystemVersion: "test", deviceModel: "test"),
            createdAt: Date(), finalizedAt: Date(), files: [
                .init(path: "image.png", sourceURL: imageURL, mediaType: "image/png", role: "camera-image"),
                .init(path: "depth.zlib", sourceURL: depthURL, mediaType: "application/octet-stream", role: "metric-depth"),
                .init(path: "confidence.zlib", sourceURL: confidenceURL, mediaType: "application/octet-stream", role: "depth-confidence")
            ]), in: staging, preferDirectoryPackage: true)
        let landmarks: [[Float]] = [[-0.05, -0.05, -0.5], [0.05,-0.05,-0.5], [0,0.05,-0.48], [0,0,-0.44]]
        return .init(bundlePath: package.archiveURL.path, segmentID: segmentID, observationIDs: observations.map(\.id), reviewedStable: true,
            headBounds: .init(center: .init(x: offset, y: 0, z: -0.45)),
            landmarks: landmarks.enumerated().map { index, p in .init(name: "landmark-\(index)", coordinate: [p[0] + Float(offset),p[1],p[2]]) })
    }

    private func compressed(_ data: Data) throws -> Data {
        var buffer = Data(count: data.count * 2 + 128)
        let capacity = buffer.count
        let count = buffer.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        } }
        #expect(count > 0)
        return buffer.prefix(count)
    }
}
#endif
