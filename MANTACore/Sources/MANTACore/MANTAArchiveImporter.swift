import Foundation

public struct MANTAArchiveExtractionLimits: Equatable, Sendable {
    public var maximumEntryCount: Int
    public var maximumArchiveBytes: Int64
    public var maximumEntryBytes: Int64
    public var maximumTotalExtractedBytes: Int64
    public var maximumCompressionRatio: Double

    public init(
        maximumEntryCount: Int = 10_000,
        maximumArchiveBytes: Int64 = 16 * 1024 * 1024 * 1024,
        maximumEntryBytes: Int64 = 8 * 1024 * 1024 * 1024,
        maximumTotalExtractedBytes: Int64 = 16 * 1024 * 1024 * 1024,
        maximumCompressionRatio: Double = 200
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalExtractedBytes = maximumTotalExtractedBytes
        self.maximumCompressionRatio = maximumCompressionRatio
    }
}

public enum MANTAArchiveImportError: LocalizedError, Equatable, Sendable {
    case destinationExists
    case invalidArchive(String)
    case unsupportedFeature(String)
    case unsafePath(String)
    case duplicatePath(String)
    case symbolicLink(String)
    case limitExceeded(String)
    case checksumMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .destinationExists: "The archive import destination already exists."
        case .invalidArchive(let reason): "The .manta archive is invalid: \(reason)."
        case .unsupportedFeature(let feature): "The .manta archive uses unsupported ZIP feature: \(feature)."
        case .unsafePath(let path): "The .manta archive contains an unsafe path: \(path)."
        case .duplicatePath(let path): "The .manta archive contains a colliding path: \(path)."
        case .symbolicLink(let path): "The .manta archive contains a symbolic link: \(path)."
        case .limitExceeded(let reason): "The .manta archive exceeds an extraction limit: \(reason)."
        case .checksumMismatch(let path): "The .manta archive entry failed its CRC check: \(path)."
        }
    }
}

public struct MANTAArchiveImporter {
    private let fileManager: FileManager
    private let limits: MANTAArchiveExtractionLimits

    public init(
        fileManager: FileManager = .default,
        limits: MANTAArchiveExtractionLimits = MANTAArchiveExtractionLimits()
    ) {
        self.fileManager = fileManager
        self.limits = limits
    }

    /// Extracts an immutable `.manta` archive into a new directory and validates
    /// its logical bundle. The destination is never partially populated.
    public func importBundle(
        at archiveURL: URL,
        to destinationDirectory: URL
    ) throws -> MANTAValidatedBundle {
        guard !fileManager.fileExists(atPath: destinationDirectory.path) else {
            throw MANTAArchiveImportError.destinationExists
        }
        let parent = destinationDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".manta-import-\(UUID().uuidString).partial", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try extract(archiveURL, to: staging)
            let validated = try MANTABundleValidator(fileManager: fileManager).validate(
                directory: staging)
            try fileManager.moveItem(at: staging, to: destinationDirectory)
            return MANTAValidatedBundle(
                rootDirectory: destinationDirectory,
                manifest: validated.manifest,
                capture: validated.capture,
                changeLog: validated.changeLog)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func extract(_ archiveURL: URL, to root: URL) throws {
        let values = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let archiveSize = values.fileSize else {
            throw MANTAArchiveImportError.invalidArchive("source is not a regular file")
        }
        guard Int64(archiveSize) <= limits.maximumArchiveBytes else {
            throw MANTAArchiveImportError.limitExceeded("archive byte count")
        }
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        let entries = try readCentralDirectory(handle: handle, archiveSize: UInt64(archiveSize))
        try validateLimits(entries)
        for entry in entries {
            try extract(entry, from: handle, to: root)
        }
    }

    private func readCentralDirectory(
        handle: FileHandle,
        archiveSize: UInt64
    ) throws -> [ZIPEntry] {
        guard archiveSize >= 22 else {
            throw MANTAArchiveImportError.invalidArchive("missing end-of-central-directory record")
        }
        let tailCount = Int(min(archiveSize, 65_557))
        let tailOffset = archiveSize - UInt64(tailCount)
        let tail = try read(handle, offset: tailOffset, count: tailCount)
        guard let eocdIndex = tail.lastIndex(ofSignature: 0x06054b50) else {
            throw MANTAArchiveImportError.invalidArchive("missing end-of-central-directory record")
        }
        let eocd = tail.subdata(in: eocdIndex..<tail.count)
        guard eocd.count >= 22 else {
            throw MANTAArchiveImportError.invalidArchive("truncated end-of-central-directory record")
        }
        let disk = eocd.u16(4)
        let centralDisk = eocd.u16(6)
        let diskEntries = eocd.u16(8)
        let entryCount = eocd.u16(10)
        let centralSize = eocd.u32(12)
        let centralOffset = eocd.u32(16)
        let commentLength = Int(eocd.u16(20))
        guard eocd.count == 22 + commentLength else {
            throw MANTAArchiveImportError.invalidArchive("malformed archive comment")
        }
        guard disk == 0, centralDisk == 0, diskEntries == entryCount else {
            throw MANTAArchiveImportError.unsupportedFeature("multi-disk archive")
        }
        guard entryCount != UInt16.max, centralSize != UInt32.max,
              centralOffset != UInt32.max else {
            throw MANTAArchiveImportError.unsupportedFeature("ZIP64")
        }
        guard Int(entryCount) <= limits.maximumEntryCount else {
            throw MANTAArchiveImportError.limitExceeded("entry count")
        }
        let centralEnd = UInt64(centralOffset) + UInt64(centralSize)
        guard centralEnd <= tailOffset + UInt64(eocdIndex), centralEnd <= archiveSize else {
            throw MANTAArchiveImportError.invalidArchive("central directory is out of bounds")
        }

        var cursor = UInt64(centralOffset)
        var entries = [ZIPEntry]()
        var collisionKeys = Set<String>()
        for _ in 0..<entryCount {
            let fixed = try read(handle, offset: cursor, count: 46)
            guard fixed.u32(0) == 0x02014b50 else {
                throw MANTAArchiveImportError.invalidArchive("invalid central-directory entry")
            }
            let nameLength = Int(fixed.u16(28))
            let extraLength = Int(fixed.u16(30))
            let commentLength = Int(fixed.u16(32))
            let variableCount = nameLength + extraLength + commentLength
            let variable = try read(handle, offset: cursor + 46, count: variableCount)
            let nameData = variable.prefix(nameLength)
            guard let path = String(data: nameData, encoding: .utf8) else {
                throw MANTAArchiveImportError.invalidArchive("entry name is not UTF-8")
            }
            try validate(path: path)
            let collisionKey = path.precomposedStringWithCanonicalMapping.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard collisionKeys.insert(collisionKey).inserted else {
                throw MANTAArchiveImportError.duplicatePath(path)
            }
            let madeBySystem = UInt8(truncatingIfNeeded: fixed.u16(4) >> 8)
            let externalAttributes = fixed.u32(38)
            if madeBySystem == 3 {
                let mode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
                if mode & 0xf000 == 0xa000 {
                    throw MANTAArchiveImportError.symbolicLink(path)
                }
            }
            let flags = fixed.u16(8)
            guard flags & 0x0001 == 0 else {
                throw MANTAArchiveImportError.unsupportedFeature("encrypted entry")
            }
            guard flags & 0x0008 == 0 else {
                throw MANTAArchiveImportError.unsupportedFeature("data descriptor")
            }
            let method = fixed.u16(10)
            guard method == 0 else {
                throw MANTAArchiveImportError.unsupportedFeature(
                    method == 8 ? "deflate compression" : "compression method \(method)")
            }
            let entry = ZIPEntry(
                path: path,
                flags: flags,
                method: method,
                crc32: fixed.u32(16),
                compressedSize: fixed.u32(20),
                uncompressedSize: fixed.u32(24),
                localHeaderOffset: fixed.u32(42),
                archiveDataEnd: centralOffset,
                isDirectory: path.hasSuffix("/"))
            guard entry.localHeaderOffset < centralOffset else {
                throw MANTAArchiveImportError.invalidArchive("local header is out of bounds")
            }
            entries.append(entry)
            cursor += UInt64(46 + variableCount)
        }
        guard cursor == UInt64(centralOffset) + UInt64(centralSize) else {
            throw MANTAArchiveImportError.invalidArchive("central-directory size mismatch")
        }
        return entries
    }

    private func validateLimits(_ entries: [ZIPEntry]) throws {
        var total: Int64 = 0
        for entry in entries where !entry.isDirectory {
            let expanded = Int64(entry.uncompressedSize)
            let compressed = Int64(entry.compressedSize)
            guard expanded <= limits.maximumEntryBytes else {
                throw MANTAArchiveImportError.limitExceeded("entry \(entry.path) byte count")
            }
            let (newTotal, overflow) = total.addingReportingOverflow(expanded)
            guard !overflow, newTotal <= limits.maximumTotalExtractedBytes else {
                throw MANTAArchiveImportError.limitExceeded("total extracted byte count")
            }
            total = newTotal
            if expanded > 0 {
                guard compressed > 0,
                      Double(expanded) / Double(compressed) <= limits.maximumCompressionRatio else {
                    throw MANTAArchiveImportError.limitExceeded("compression ratio for \(entry.path)")
                }
            }
        }
    }

    private func extract(_ entry: ZIPEntry, from handle: FileHandle, to root: URL) throws {
        let local = try read(handle, offset: UInt64(entry.localHeaderOffset), count: 30)
        guard local.u32(0) == 0x04034b50 else {
            throw MANTAArchiveImportError.invalidArchive("missing local header for \(entry.path)")
        }
        let nameLength = Int(local.u16(26))
        let extraLength = Int(local.u16(28))
        let nameData = try read(
            handle, offset: UInt64(entry.localHeaderOffset) + 30, count: nameLength)
        guard String(data: nameData, encoding: .utf8) == entry.path,
              local.u16(6) == entry.flags,
              local.u16(8) == entry.method,
              local.u32(14) == entry.crc32,
              local.u32(18) == entry.compressedSize,
              local.u32(22) == entry.uncompressedSize else {
            throw MANTAArchiveImportError.invalidArchive("local header mismatch for \(entry.path)")
        }
        let destination = root.appendingPathComponent(entry.path)
        if entry.isDirectory {
            guard entry.compressedSize == 0, entry.uncompressedSize == 0 else {
                throw MANTAArchiveImportError.invalidArchive("directory entry contains data")
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw MANTAArchiveImportError.invalidArchive("cannot create \(entry.path)")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var remaining = Int(entry.compressedSize)
        var offset = UInt64(entry.localHeaderOffset) + 30 + UInt64(nameLength + extraLength)
        guard offset + UInt64(entry.compressedSize) <= UInt64(entry.archiveDataEnd) else {
            throw MANTAArchiveImportError.invalidArchive("entry data overlaps the central directory")
        }
        var crc = MANTACRC32()
        while remaining > 0 {
            let count = min(remaining, 1024 * 1024)
            let chunk = try read(handle, offset: offset, count: count)
            try output.write(contentsOf: chunk)
            crc.update(chunk)
            remaining -= count
            offset += UInt64(count)
        }
        guard crc.finalize() == entry.crc32 else {
            throw MANTAArchiveImportError.checksumMismatch(entry.path)
        }
    }

    private func validate(path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MANTAArchiveImportError.unsafePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let checked = path.hasSuffix("/") ? components.dropLast() : components[...]
        guard !checked.isEmpty,
              checked.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MANTAArchiveImportError.unsafePath(path)
        }
    }

    private func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw MANTAArchiveImportError.invalidArchive("unexpected end of file")
        }
        return data
    }
}

private struct ZIPEntry {
    var path: String
    var flags: UInt16
    var method: UInt16
    var crc32: UInt32
    var compressedSize: UInt32
    var uncompressedSize: UInt32
    var localHeaderOffset: UInt32
    var archiveDataEnd: UInt32
    var isDirectory: Bool
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    func lastIndex(ofSignature signature: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        for offset in stride(from: count - 4, through: 0, by: -1) {
            if u32(offset) == signature { return offset }
        }
        return nil
    }
}
