import Foundation

private enum MANTAZIPError: Error {
    case archiveTooLarge
}

struct MANTADeterministicZIP {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func write(
        directory: URL, to destination: URL,
        precomputedCRC32: [String: UInt32] = [:]
    ) throws {
        let files = try regularFiles(in: directory)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var central = Data()
        var offset: UInt32 = 0
        for item in files {
            let name = Data(item.path.utf8)
            let values = try item.url.resourceValues(forKeys: [.fileSizeKey])
            let byteCount = values.fileSize ?? 0
            let crc = try precomputedCRC32[item.path] ?? MANTACRC32.checksum(file: item.url)
            let size = try uint32(byteCount)

            var local = Data()
            local.appendLE(UInt32(0x04034b50))
            local.appendLE(UInt16(20))
            local.appendLE(UInt16(0x0800))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0))
            local.appendLE(UInt16(0x0021))
            local.appendLE(crc)
            local.appendLE(size)
            local.appendLE(size)
            local.appendLE(try uint16(name.count))
            local.appendLE(UInt16(0))
            local.append(name)
            try handle.write(contentsOf: local)
            try copy(item.url, to: handle)

            var header = Data()
            header.appendLE(UInt32(0x02014b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0x0021))
            header.appendLE(crc)
            header.appendLE(size)
            header.appendLE(size)
            header.appendLE(try uint16(name.count))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt32(0))
            header.appendLE(offset)
            header.append(name)
            central.append(header)

            offset = try adding(offset, local.count + byteCount)
        }

        try handle.write(contentsOf: central)
        var end = Data()
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(try uint16(files.count))
        end.appendLE(try uint16(files.count))
        end.appendLE(try uint32(central.count))
        end.appendLE(offset)
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
    }

    private func regularFiles(in root: URL) throws -> [(path: String, url: URL)] {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            throw CocoaError(.fileReadUnknown)
        }
        var result = [(String, URL)]()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
            guard values.isRegularFile == true else { continue }
            let rootPath = comparableFileSystemPath(root)
            let filePath = comparableFileSystemPath(url)
            guard filePath.hasPrefix(rootPath + "/") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            result.append((relative, url))
        }
        return result.sorted { $0.0 < $1.0 }.map { (path: $0.0, url: $0.1) }
    }

    private func comparableFileSystemPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/private/var/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private func copy(_ source: URL, to handle: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
    }

    private func uint16(_ value: Int) throws -> UInt16 {
        guard let result = UInt16(exactly: value) else { throw MANTAZIPError.archiveTooLarge }
        return result
    }

    private func uint32(_ value: Int) throws -> UInt32 {
        guard let result = UInt32(exactly: value) else { throw MANTAZIPError.archiveTooLarge }
        return result
    }

    private func adding(_ lhs: UInt32, _ rhs: Int) throws -> UInt32 {
        guard let value = UInt32(exactly: rhs), !lhs.addingReportingOverflow(value).overflow else {
            throw MANTAZIPError.archiveTooLarge
        }
        return lhs + value
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
