import CryptoKit
import Foundation
import Testing
@testable import MANTACore

struct MANTABundleValidatorTests {
    @Test func validatesMinimalFixture() throws {
        let fixture = try #require(Bundle.module.url(forResource: "Minimal128", withExtension: nil, subdirectory: "Fixtures"))
        let bundle = try MANTABundleValidator().validate(directory: fixture)

        #expect(bundle.manifest.schemaVersion == "1.0.0")
        #expect(bundle.capture.layoutID == "egi-hydrocel-128")
        #expect(bundle.capture.observations.count == 2)
    }

    @Test func rejectsUnsupportedMajorVersion() throws {
        let directory = try copyFixture()
        try replace(in: directory.appendingPathComponent("manifest.json"), from: "\"1.0.0\"", to: "\"2.0.0\"")

        #expect(throws: MANTABundleValidationError.unsupportedMajorVersion(2)) {
            try MANTABundleValidator().validate(directory: directory)
        }
    }

    @Test func rejectsHashMismatch() throws {
        let directory = try copyFixture()
        let captureURL = directory.appendingPathComponent("capture.json")
        var data = try Data(contentsOf: captureURL)
        data[data.startIndex] = 0x5B
        try data.write(to: captureURL)

        #expect(throws: MANTABundleValidationError.hashMismatch("capture.json")) {
            try MANTABundleValidator().validate(directory: directory)
        }
    }

    @Test func JSONDatesEncodeWithFractionalSecondsAndRoundTrip() throws {
        let source = try #require(Bundle.module.url(forResource: "Minimal128", withExtension: nil, subdirectory: "Fixtures"))
        let data = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        var manifest = try MANTAJSON.makeDecoder().decode(MANTABundleManifest.self, from: data)
        manifest.createdAt = Date(timeIntervalSince1970: 1_784_035_822.125)

        let encoded = try MANTAJSON.makeEncoder().encode(manifest)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains(".125Z"))
        let decoded = try MANTAJSON.makeDecoder().decode(MANTABundleManifest.self, from: encoded)
        #expect(decoded.createdAt == manifest.createdAt)
    }

    @Test func rejectsTraversalPath() throws {
        let directory = try copyFixture()
        try replace(in: directory.appendingPathComponent("manifest.json"), from: "capture.json", to: "../capture.json")

        #expect(throws: MANTABundleValidationError.invalidPath("../capture.json")) {
            try MANTABundleValidator().validate(directory: directory)
        }
    }

    @Test func rejectsUndeclaredFile() throws {
        let directory = try copyFixture()
        try Data("unexpected".utf8).write(to: directory.appendingPathComponent("extra.txt"))

        #expect(throws: MANTABundleValidationError.undeclaredFile("extra.txt")) {
            try MANTABundleValidator().validate(directory: directory)
        }
    }

    @Test func semanticVersionsCompareNumerically() throws {
        let one = try #require(MANTASemanticVersion("1.2.9"))
        let two = try #require(MANTASemanticVersion("1.10.0"))
        #expect(one < two)
        #expect(MANTASemanticVersion("1.0") == nil)
    }

    @Test func timestampedFilenameUsesUTCAndContainsNoPHI() {
        let date = Date(timeIntervalSince1970: 1_784_035_822)
        #expect(MANTABundleFilename.timestamped(for: date) == "20260714_133022.manta")
    }

    @Test func validatesDerivedBundleLineage() throws {
        let directory = try makeDerivedBundle()
        let bundle = try MANTABundleValidator().validate(directory: directory)

        #expect(bundle.manifest.parentBundleID == UUID(uuidString: "86b20bb6-f31e-4b0b-b423-cf93ae2742bc"))
        #expect(bundle.changeLog?.changes.count == 1)
        #expect(bundle.changeLog?.changes.first?.category == "electrode-review")
    }

    @Test func rejectsLineageMismatch() throws {
        let directory = try makeDerivedBundle()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try MANTAJSON.makeDecoder().decode(
            MANTABundleManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        manifest.parentBundleID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        try MANTAJSON.makeEncoder().encode(manifest).write(to: manifestURL)

        #expect(throws: MANTABundleValidationError.invalidLineage("change-log parentBundleID does not match manifest")) {
            try MANTABundleValidator().validate(directory: directory)
        }
    }

    private func copyFixture() throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "Minimal128", withExtension: nil, subdirectory: "Fixtures"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func makeDerivedBundle() throws -> URL {
        let directory = try copyFixture()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try MANTAJSON.makeDecoder().decode(
            MANTABundleManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let parentID = manifest.bundleID
        let derivedID = UUID(uuidString: "c69e776c-551e-4a68-b837-f9a0357df3ce")!
        let changedAt = Date(timeIntervalSince1970: 1_784_035_825.5)
        let log = MANTAChangeLogDocument(
            schema: "https://manta.local/schemas/change-log-1.0.0.json",
            bundleID: derivedID,
            parentBundleID: parentID,
            createdAt: changedAt,
            producer: manifest.producer,
            changes: [
                MANTAChangeRecord(
                    id: UUID(uuidString: "918521d9-b574-4811-a88e-130c3580913e")!,
                    changedAt: changedAt,
                    category: "electrode-review",
                    summary: "Reviewed E17 position.",
                    targets: ["electrodes/E17"]
                )
            ]
        )
        let logData = try MANTAJSON.makeEncoder().encode(log)
        try logData.write(to: directory.appendingPathComponent("log_manta.json"))

        manifest.bundleID = derivedID
        manifest.parentBundleID = parentID
        manifest.finalizedAt = changedAt
        manifest.content.changeLog = "log_manta.json"
        manifest.files.append(
            MANTAFileEntry(
                path: "log_manta.json",
                mediaType: "application/json",
                role: "bundle-change-log",
                size: Int64(logData.count),
                sha256: SHA256.hash(data: logData).map { String(format: "%02x", $0) }.joined()
            )
        )
        try MANTAJSON.makeEncoder().encode(manifest).write(to: manifestURL)
        return directory
    }

    private func replace(in url: URL, from: String, to: String) throws {
        let original = try String(contentsOf: url, encoding: .utf8)
        try original.replacingOccurrences(of: from, with: to).write(to: url, atomically: true, encoding: .utf8)
    }
}
