#if os(macOS)
import Foundation
import RealityKit
import MANTACore

@available(macOS 26.0, *)
public enum ObjectCaptureCalibration {
    /// Join solely on explicit sample IDs, including missing and skipped records.
    public static func write(poses: PhotogrammetrySession.Poses?, to url: URL,
                             rejected: [Int: String], requestError: String?) throws {
        var records = try JSONDecoder().decode([ReconstructionCameraRecord].self, from: Data(contentsOf: url))
        let known = Set(records.map(\.sampleID))
        guard known.count == records.count else {
            throw NSError(domain: "MANTA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Duplicate reconstruction sample IDs."])
        }
        if let poses, !Set(poses.posesBySample.keys).isSubset(of: known) {
            throw NSError(domain: "MANTA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Object Capture returned unknown sample IDs."])
        }
        for i in records.indices {
            let id = records[i].sampleID
            if let reason = rejected[id] {
                records[i].status = "rejected"; records[i].statusDetail = reason
            } else if let pose = poses?.posesBySample[id] {
                let matrix = pose.transform.matrix
                let k = pose.intrinsics
                let distortion = pose.lensDistortionData
                records[i].estimated = EstimatedCalibration(
                    modelFromCamera: (0..<4).flatMap { c in (0..<4).map { Double(matrix[c][$0]) } },
                    intrinsics: k.map { matrix in (0..<3).flatMap { c in (0..<3).map { Double(matrix[c][$0]) } } },
                    distortionCenter: distortion.map { [Double($0.center.x), Double($0.center.y)] },
                    radialLookupTable: distortion.map { $0.radialLookupTable.map(Double.init) })
                records[i].status = "estimated"
            } else {
                records[i].status = "unavailable"
                records[i].statusDetail = requestError ?? "No pose returned for this sample."
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}
#endif
