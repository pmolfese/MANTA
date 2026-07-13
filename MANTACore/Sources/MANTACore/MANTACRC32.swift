import Foundation

/// Streaming ZIP CRC-32. The lookup table avoids the previous eight
/// bit-at-a-time iterations for every payload byte.
struct MANTACRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (0xedb88320 & (0 &- (crc & 1)))
        }
        return crc
    }

    private var value = UInt32.max

    mutating func update(_ data: Data) {
        var crc = value
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { rawBytes in
                for byte in rawBytes.bindMemory(to: UInt8.self) {
                    let index = Int((crc ^ UInt32(byte)) & 0xff)
                    crc = table[index] ^ (crc >> 8)
                }
            }
        }
        value = crc
    }

    func finalize() -> UInt32 { value ^ UInt32.max }

    static func checksum(file url: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc = MANTACRC32()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            crc.update(chunk)
        }
        return crc.finalize()
    }
}
