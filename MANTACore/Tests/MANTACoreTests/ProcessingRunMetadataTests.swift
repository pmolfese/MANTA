import Foundation
import Testing
@testable import MANTACore

struct ProcessingRunMetadataTests {
    @Test func provenanceSurvivesRoundTripWithoutInventingBuildIdentity() throws {
        let source = UUID()
        let metadata = ProcessingRunMetadata(
            sourceBundleID: source,
            files: [MANTAFileEntry(path: "frames/1.png", mediaType: "image/png",
                                  role: "image", size: 12, sha256: "fixture-hash")],
            operatingSystem: "fixture OS (build fixture)",
            applicationVersion: nil, applicationBuild: nil)
        let decoded = try JSONDecoder().decode(
            ProcessingRunMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded == metadata)
        #expect(decoded.sourceBundleID == source)
        #expect(decoded.inputSHA256 == ["frames/1.png": "fixture-hash"])
        #expect(decoded.applicationBuild == nil)
        #expect(decoded.schemaVersion == 1)
    }
}
