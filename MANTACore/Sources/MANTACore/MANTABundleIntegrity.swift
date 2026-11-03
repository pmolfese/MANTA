import CryptoKit
import Foundation

/// Advisory evidence about the bytes on disk. These findings never reject an import.
public struct MANTABundleIntegrityWarning: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case missingChecksum, invalidChecksum, checksumMismatch, archiveChecksumMismatch, sizeMismatch, unreadable
    }
    public var path: String
    public var kind: Kind
    public var message: String
}

public enum MANTABundleIntegrity {
    /// Bounded-memory audit of either an extracted archive or a directory package.
    /// No ZIP conversion, payload-sized allocation, 32-bit size conversion, or writes.
    public static func warnings(directory: URL, files: [MANTAFileEntry]) -> [MANTABundleIntegrityWarning] {
        var warnings: [MANTABundleIntegrityWarning] = []
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        for entry in files {
            func warn(_ kind: MANTABundleIntegrityWarning.Kind, _ message: String) {
                warnings.append(.init(path: entry.path, kind: kind, message: message))
            }
            let url = root.appendingPathComponent(entry.path).standardizedFileURL.resolvingSymlinksInPath()
            // Lenient package loaders also call this API. Never follow a manifest
            // entry outside the bundle or read a directory/special device as a file.
            guard !entry.path.hasPrefix("/"), url.path.hasPrefix(root.path + "/"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                warn(.unreadable, "Cannot check \(entry.path): not a readable file inside the package.")
                continue
            }
            if let size = values.fileSize, Int64(size) != entry.size {
                warn(.sizeMismatch, "Size differs for \(entry.path): manifest \(entry.size), disk \(size) bytes. Import remains available.")
            }
            guard !entry.sha256.isEmpty else {
                warn(.missingChecksum, "No checksum recorded for \(entry.path); integrity is unverified.")
                continue
            }
            guard entry.sha256.utf8.count == 64, entry.sha256.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else {
                warn(.invalidChecksum, "Invalid checksum recorded for \(entry.path); integrity is unverified.")
                continue
            }
            do {
                let digest = try sha256(url)
                if digest != entry.sha256.lowercased() {
                    warn(.checksumMismatch, "Checksum differs for \(entry.path); the file may have changed or been damaged. Import remains available.")
                }
            } catch {
                warn(.unreadable, "Could not checksum \(entry.path): \(error.localizedDescription). Integrity is unverified.")
            }
        }
        return warnings
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
