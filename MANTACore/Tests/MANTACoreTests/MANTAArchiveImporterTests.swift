import Foundation
import Testing

@testable import MANTACore

struct MANTAArchiveImporterTests {
    @Test func importsAndValidatesFinalizedArchive() throws {
        let archive = try makeArchive()
        let destination = temporaryURL()

        let bundle = try MANTAArchiveImporter().importBundle(at: archive, to: destination)

        #expect(bundle.rootDirectory == destination)
        #expect(bundle.manifest.sessionID == bundle.capture.sessionID)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("capture.json").path))
    }

    @Test func rejectsTraversalAndLeavesNoDestination() throws {
        let archive = try makeArchive()
        try replaceEveryOccurrence(in: archive, from: "capture.json", to: "../ture.json")
        let destination = temporaryURL()

        #expect(throws: MANTAArchiveImportError.unsafePath("../ture.json")) {
            try MANTAArchiveImporter().importBundle(at: archive, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func rejectsCaseCollidingCentralDirectoryPaths() throws {
        let first = temporaryURL()
        let second = temporaryURL()
        try Data("x".utf8).write(to: first)
        try Data("y".utf8).write(to: second)
        let archive = try makeArchive(files: [
            MANTABundleFileSource(
                path: "assets/x.bin", sourceURL: first, mediaType: "application/octet-stream",
                role: "test"),
            MANTABundleFileSource(
                path: "assets/y.bin", sourceURL: second, mediaType: "application/octet-stream",
                role: "test")
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archive.path)
        var data = try Data(contentsOf: archive)
        let old = Data("assets/y.bin".utf8)
        let new = Data("assets/X.bin".utf8)
        let range = try #require(data.range(of: old, options: .backwards))
        data.replaceSubrange(range, with: new)
        try data.write(to: archive)

        #expect(throws: MANTAArchiveImportError.duplicatePath("assets/X.bin")) {
            try MANTAArchiveImporter().importBundle(at: archive, to: temporaryURL())
        }
    }

    @Test func rejectsSymlinkEntry() throws {
        let directory = temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp/outside"))
        let archive = temporaryURL().appendingPathExtension("manta")
        let process = Process()
        process.currentDirectoryURL = directory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-0", "-y", archive.path, "link"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        #expect(throws: MANTAArchiveImportError.symbolicLink("link")) {
            try MANTAArchiveImporter().importBundle(at: archive, to: temporaryURL())
        }
    }

    @Test func rejectsCRCFailure() throws {
        let asset = temporaryURL()
        try Data("camera-bytes".utf8).write(to: asset)
        let archive = try makeArchive(files: [
            MANTABundleFileSource(
                path: "assets/camera.jpg", sourceURL: asset, mediaType: "image/jpeg",
                role: "camera-image")
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archive.path)
        var data = try Data(contentsOf: archive)
        let payload = Data("camera-bytes".utf8)
        let range = try #require(data.range(of: payload))
        data[range.lowerBound] ^= 0xff
        try data.write(to: archive)

        #expect(throws: MANTAArchiveImportError.checksumMismatch("assets/camera.jpg")) {
            try MANTAArchiveImporter().importBundle(at: archive, to: temporaryURL())
        }
    }

    @Test func enforcesConfiguredExtractionLimit() throws {
        let archive = try makeArchive()
        let limits = MANTAArchiveExtractionLimits(
            maximumEntryCount: 100,
            maximumArchiveBytes: 1_000_000,
            maximumEntryBytes: 1,
            maximumTotalExtractedBytes: 1_000_000,
            maximumCompressionRatio: 2)

        #expect(throws: MANTAArchiveImportError.limitExceeded("entry capture.json byte count")) {
            try MANTAArchiveImporter(limits: limits).importBundle(
                at: archive, to: temporaryURL())
        }
    }

    private func makeArchive(files: [MANTABundleFileSource] = []) throws -> URL {
        let sessionID = UUID(uuidString: "c75cf330-8751-46f3-bcd4-7bef70b28ee8")!
        let capture = MANTACaptureDocument(
            schema: MANTABundleFormat.captureSchema,
            sessionID: sessionID,
            captureMode: "both",
            layoutID: "hydrocel-128",
            coordinateSystems: [
                MANTACoordinateSystem(
                    id: "arkit-world", handedness: "right", units: .meters,
                    description: "ARKit world frame.")
            ], observations: [])
        let request = MANTABundleFinalizationRequest(
            capture: capture,
            producer: MANTAProducer(
                application: "MANTA", version: "0.1", build: "1", platform: "test",
                operatingSystemVersion: "test", deviceModel: "test"),
            createdAt: Date(timeIntervalSince1970: 1_784_035_822),
            finalizedAt: Date(timeIntervalSince1970: 1_784_035_942),
            bundleID: UUID(uuidString: "c69e776c-551e-4a68-b837-f9a0357df3ce")!,
            files: files)
        return try MANTABundleFinalizer().finalize(request, in: temporaryURL()).archiveURL
    }

    private func replaceEveryOccurrence(in url: URL, from: String, to: String) throws {
        let old = Data(from.utf8)
        let new = Data(to.utf8)
        #expect(old.count == new.count)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        var data = try Data(contentsOf: url)
        var searchStart = data.startIndex
        while let range = data.range(of: old, in: searchStart..<data.endIndex) {
            data.replaceSubrange(range, with: new)
            searchStart = range.lowerBound + new.count
        }
        try data.write(to: url)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}
