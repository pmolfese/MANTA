import Foundation
import Testing
import MANTAProcessing
@testable import MANTACore

struct ReconstructionCalibrationTests {
    @Test func optionalCalibrationRoundTripPreservesSourceAndDistortion() throws {
        var record = ReconstructionCameraRecord(sampleID: 12, imageFilename: "a.png", observationID: UUID(),
            cameraToWorld: Array(repeating: 1, count: 16), intrinsics: Array(repeating: 2, count: 9), imageOrientation: "up")
        record.estimated = EstimatedCalibration(modelFromCamera: Array(repeating: 3, count: 16), intrinsics: nil,
            distortionCenter: [400, 300], radialLookupTable: [0, 0.1, 0.2])
        let decoded = try JSONDecoder().decode(ReconstructionCameraRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.sampleID == 12)
        #expect(decoded.cameraToWorld == record.cameraToWorld)
        #expect(decoded.intrinsics == record.intrinsics)
        #expect(decoded.estimated?.intrinsics == nil)
        #expect(decoded.estimated?.radialLookupTable == [0, 0.1, 0.2])
    }

    #if os(macOS)
    @available(macOS 26.0, *)
    @Test func missingAndSkippedSamplesRemainMappedAndDuplicateIDsFail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let records = [2, 7].map { ReconstructionCameraRecord(sampleID: $0, imageFilename: "\($0).png",
            observationID: UUID(), cameraToWorld: [], intrinsics: [], imageOrientation: "up") }
        try JSONEncoder().encode(records).write(to: url)
        try ObjectCaptureCalibration.write(poses: nil, to: url, rejected: [7: "invalid image"], requestError: "unavailable")
        let result = try JSONDecoder().decode([ReconstructionCameraRecord].self, from: Data(contentsOf: url))
        #expect(result.map(\.sampleID) == [2, 7])
        #expect(result.map(\.observationID) == records.map(\.observationID))
        #expect(result.map(\.status) == ["unavailable", "rejected"])
        #expect(result.allSatisfy { $0.estimated == nil })
        try JSONEncoder().encode([records[0], records[0]]).write(to: url)
        #expect(throws: (any Error).self) {
            try ObjectCaptureCalibration.write(poses: nil, to: url, rejected: [:], requestError: nil)
        }
    }

    #endif

    @Test func labelMetricsDeduplicateAndDoNotInventEmptyDenominators() {
        #expect(LabelBenchmarkMetrics.predictedLabels(from: ["E1", "1 E2", "noise", "E999"], channelCount: 256) == ["E1", "E2"])
        let metrics = LabelBenchmarkMetrics(expected: ["E1", "E2"], predicted: ["E1", "E3"])
        #expect(metrics.precision == 0.5)
        #expect(metrics.recall == 0.5)
        #expect(metrics.falseNegatives == ["E2"])
        #expect(metrics.falsePositives == ["E3"])
        let empty = LabelBenchmarkMetrics(expected: [], predicted: [])
        #expect(empty.precision == nil)
        #expect(empty.recall == nil)
    }
}
