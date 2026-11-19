import Foundation
import MANTACore

/// A conservative display/placement screening rule, not a validated accuracy claim.
/// Keep the threshold in one place for new solves and saved automatic fits.
nonisolated enum ReceiverAlignmentPolicy {
    static let maximumAutomaticRMSMeters: Float = 0.010

    static func acceptsAutomatic(symmetricRMS: Float?) -> Bool {
        guard let rms = symmetricRMS else { return false }
        return rms.isFinite && rms >= 0 && rms <= maximumAutomaticRMSMeters
    }

    enum Assessment: Equatable, Sendable {
        case unavailable, unverified, manual
        case automatic(Float)
        case rejected(Float?)

        var rejectsTransform: Bool {
            if case .rejected = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .unavailable: "No model-to-world alignment"
            case .unverified: "Alignment unverified · inspect before use"
            case .manual: "Manual alignment · inspect before use"
            case .automatic(let rms):
                String(format: "Automatic fit: %.1f mm RMS · screening only", rms * 1_000)
            case .rejected(let rms):
                if let rms, rms.isFinite {
                    String(format: "Overlay blocked: %.1f mm RMS · automatic limit 10 mm", rms * 1_000)
                } else {
                    "Overlay blocked: automatic alignment evidence is missing or invalid"
                }
            }
        }
    }

    private struct Evidence: Decodable {
        var alignmentSymmetricRMSMeters: Float?
        var alignmentAccepted: Bool?
    }

    static func assessment(for bundle: MANTAValidatedBundle, modelURLOverride: URL? = nil) -> Assessment {
        let reconstruction = bundle.capture.reconstruction
        guard let model = modelURLOverride ?? reconstruction?.objectCaptureModelPath.map({ bundle.rootDirectory.appendingPathComponent($0) }) else {
            return .unavailable
        }
        let latestAlignment = bundle.changeLog?.changes.last {
            $0.category == "manual-world-alignment" || $0.category == "photogrammetry-reconstruction"
        }
        // A subsequent manual review supersedes the original automatic fit.
        // Unrelated later edits must not resurrect that older automatic result.
        if modelURLOverride == nil, latestAlignment?.category == "manual-world-alignment",
           reconstruction?.modelToWorld != nil {
            return .manual
        }
        let diagnostics = model.deletingPathExtension()
        let evidenceURL = diagnostics.deletingLastPathComponent()
            .appendingPathComponent(diagnostics.lastPathComponent + "_diagnostics.json")
        if let data = try? Data(contentsOf: evidenceURL) {
            guard let evidence = try? MANTAJSON.makeDecoder().decode(Evidence.self, from: data) else {
                return .rejected(nil)
            }
            guard evidence.alignmentAccepted == true,
                  acceptsAutomatic(symmetricRMS: evidence.alignmentSymmetricRMSMeters) else {
                return .rejected(evidence.alignmentSymmetricRMSMeters)
            }
            return .automatic(evidence.alignmentSymmetricRMSMeters!)
        }
        if modelURLOverride != nil || latestAlignment?.category == "photogrammetry-reconstruction" {
            return .rejected(nil)
        }
        return reconstruction?.modelToWorld == nil ? .unavailable : .unverified
    }

    /// Suppress rejected historical placements in memory without rewriting source
    /// or derivative files. The model remains available for separate inspection.
    static func applying(to bundle: MANTAValidatedBundle) -> MANTAValidatedBundle {
        guard assessment(for: bundle).rejectsTransform else { return bundle }
        var capture = bundle.capture
        capture.reconstruction?.modelToWorld = nil
        return MANTAValidatedBundle(rootDirectory: bundle.rootDirectory, manifest: bundle.manifest,
            capture: capture, changeLog: bundle.changeLog, integrityWarnings: bundle.integrityWarnings)
    }
}
