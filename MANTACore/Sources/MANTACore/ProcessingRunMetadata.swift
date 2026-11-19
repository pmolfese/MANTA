import Foundation

/// Provenance for a derived processing result. Missing build identifiers remain
/// nil rather than implying a reproducible source revision that was not recorded.
public struct ProcessingRunMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var runID: UUID
    public var sourceBundleID: UUID
    public var inputSHA256: [String: String]
    public var operatingSystem: String
    public var applicationVersion: String?
    public var applicationBuild: String?

    public init(
        sourceBundleID: UUID, files: [MANTAFileEntry],
        runID: UUID = UUID(),
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        applicationVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        applicationBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    ) {
        self.runID = runID
        self.sourceBundleID = sourceBundleID
        self.inputSHA256 = files.reduce(into: [:]) { $0[$1.path] = $1.sha256 }
        self.operatingSystem = operatingSystem
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
    }
}
