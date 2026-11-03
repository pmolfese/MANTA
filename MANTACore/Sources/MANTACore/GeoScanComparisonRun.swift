import Foundation
import CryptoKit

/// Shared CLI/GUI report envelope, hashing the exact bytes compared.
public struct GeoScanComparisonRun: Encodable, Sendable {
    public let referenceSHA256: String
    public let candidateSHA256: String
    public let generatedAt: Date
    public let operatingSystem: String
    public let comparison: GeoScanComparisonReport

    public static func make(reference: Data, referenceUnit: DistanceUnit,
                            candidate: Data, candidateUnit: DistanceUnit) throws -> Self {
        guard let r = String(data: reference, encoding: .utf8),
              let c = String(data: candidate, encoding: .utf8) else {
            throw GeoScanError(message: "Input must be UTF-8 text.")
        }
        let comparison = try GeoScanComparison.compare(
            reference: GeoScanImporter.parse(r, unit: referenceUnit),
            candidate: GeoScanImporter.parse(c, unit: candidateUnit))
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        return Self(referenceSHA256: hash(reference), candidateSHA256: hash(candidate),
                    generatedAt: Date(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    comparison: comparison)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
