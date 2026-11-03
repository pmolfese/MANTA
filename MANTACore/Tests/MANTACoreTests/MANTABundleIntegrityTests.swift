import Foundation
import Testing
@testable import MANTACore

struct MANTABundleIntegrityTests {
    @Test func alteredBytesAndLegacySizesWarnWithoutBlocking() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("capture.json")
        // Valid JSON with a different payload length and checksum.
        var data = try Data(contentsOf: capture)
        data.append(Data("\n ".utf8))
        try data.write(to: capture)
        let bundle = try MANTABundleValidator().validate(directory: root)
        #expect(bundle.capture.observations.count == 2)
        #expect(Set(bundle.integrityWarnings.map(\.kind)) == [.checksumMismatch, .sizeMismatch])
        #expect(try Data(contentsOf: capture) == data) // Audit does not repair/rewrite evidence.
    }

    @Test func missingMalformedAndWrongChecksumsAreAdvisory() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try MANTABundleValidator().validate(directory: root).integrityWarnings.isEmpty)
        let manifestURL = root.appendingPathComponent("manifest.json")
        var manifest = try MANTAJSON.makeDecoder().decode(MANTABundleManifest.self,
            from: Data(contentsOf: manifestURL))
        let cases: [(String, MANTABundleIntegrityWarning.Kind)] = [
            ("", .missingChecksum), ("legacy", .invalidChecksum),
            (String(repeating: "0", count: 64), .checksumMismatch)]
        for (hash, kind) in cases {
            manifest.files[0].sha256 = hash
            try MANTAJSON.makeEncoder().encode(manifest).write(to: manifestURL)
            let bundle = try MANTABundleValidator().validate(directory: root)
            #expect(bundle.integrityWarnings.map(\.kind) == [kind])
        }
    }

    @Test func absentAndNonStringChecksumMetadataStillImports() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("manifest.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try #require(json["files"] as? [[String: Any]])
        files[0].removeValue(forKey: "sha256")
        json["files"] = files
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        #expect(try MANTABundleValidator().validate(directory: root).integrityWarnings.map(\.kind) == [.missingChecksum])
        files[0]["sha256"] = 123
        json["files"] = files
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        #expect(try MANTABundleValidator().validate(directory: root).integrityWarnings.map(\.kind) == [.invalidChecksum])
    }

    @Test func legacyZipRetainsAdvisoryChecksumWarningsAfterExtraction() throws {
        let root = try fixture()
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".manta")
        let destination = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer {
            for url in [root, archive, destination] { try? FileManager.default.removeItem(at: url) }
        }
        let capture = root.appendingPathComponent("capture.json")
        var data = try Data(contentsOf: capture)
        data.append(Data("\n".utf8))
        try data.write(to: capture)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-0", archive.path, "manifest.json", "capture.json"]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        let bundle = try MANTAArchiveImporter().importBundle(at: archive, to: destination)
        #expect(bundle.integrityWarnings.contains { $0.kind == .checksumMismatch })
        #expect(bundle.capture.observations.count == 2)
    }

    @Test func directoryPackageStreamsPastTwoGiBThroughLastByte() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        // Sparse 2 GiB prefix plus a nonzero tail: no multi-GB fixture or allocation.
        let boundary: UInt64 = 2_147_483_648
        try handle.truncate(atOffset: boundary)
        try handle.seek(toOffset: boundary)
        try handle.write(contentsOf: Data("MANTA-large-tail".utf8))
        try handle.close()
        let manifestURL = root.appendingPathComponent("manifest.json")
        var manifest = try MANTAJSON.makeDecoder().decode(MANTABundleManifest.self,
            from: Data(contentsOf: manifestURL))
        // Independently computed SHA-256 of 2 GiB zeros followed by the 16-byte tail.
        manifest.files.append(MANTAFileEntry(path: "large.bin", mediaType: "application/octet-stream",
            role: "test", size: Int64(boundary) + 16,
            sha256: "20a68b932b62eb2077bcf5d71fdf262f2e3870b97c28a9cf6a652959bc2f50cf"))
        try MANTAJSON.makeEncoder().encode(manifest).write(to: manifestURL)
        let bundle = try MANTABundleValidator().validate(directory: root)
        #expect(bundle.integrityWarnings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(bundle.rootDirectory.path == root.path)
    }

    @Test func advisoryAuditDoesNotFollowPathsOutsidePackage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = MANTAFileEntry(path: "../outside", mediaType: "application/octet-stream",
            role: "test", size: 0, sha256: String(repeating: "0", count: 64))
        #expect(MANTABundleIntegrity.warnings(directory: root, files: [file]).map(\.kind) == [.unreadable])
    }

    private func fixture() throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "Minimal128", withExtension: nil, subdirectory: "Fixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        return root
    }
}
