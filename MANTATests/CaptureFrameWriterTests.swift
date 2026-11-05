import CoreVideo
import Foundation
import Testing
import MANTACore
@testable import MANTA

@MainActor
struct CaptureFrameWriterTests {
    @Test func copiesPlanarRGBAndDepthIntoIndependentBuffers() throws {
        let pool = CaptureBufferPool()
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_OneComponent8] {
            let source = try buffer(format: format)
            fill(source, byte: 37)
            CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            let copy = try pool.copy(source)
            fill(source, byte: 99)
            #expect(CVPixelBufferGetPixelFormatType(copy) == format)
            #expect(CVPixelBufferGetWidth(copy) == 4)
            #expect(CVPixelBufferGetHeight(copy) == 4)
            CVPixelBufferLockBaseAddress(copy, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
            let count = CVPixelBufferGetPlaneCount(copy)
            for plane in 0..<max(1, count) {
                let base = count == 0 ? CVPixelBufferGetBaseAddress(copy) : CVPixelBufferGetBaseAddressOfPlane(copy, plane)
                #expect(base?.load(as: UInt8.self) == 37)
            }
            #expect(CVBufferCopyAttachment(copy, kCVImageBufferColorPrimariesKey, nil) != nil)
        }
    }

    @Test func poolRefusesUnboundedBuffers() throws {
        let pool = CaptureBufferPool()
        let source = try buffer(format: kCVPixelFormatType_OneComponent8)
        let copies = try (0..<3).map { _ in try pool.copy(source) }
        _ = withExtendedLifetime(copies) {
            #expect(throws: (any Error).self) { try pool.copy(source) }
        }
    }

    private func buffer(format: OSType) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let result = CVPixelBufferCreate(nil, 4, 4, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
        #expect(result == kCVReturnSuccess)
        return try #require(value)
    }

    private func fill(_ buffer: CVPixelBuffer, byte: Int32) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let count = CVPixelBufferGetPlaneCount(buffer)
        for plane in 0..<max(1, count) {
            let base = count == 0 ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            let stride = count == 0 ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = count == 0 ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, plane)
            if let base { memset(base, byte, stride * rows) }
        }
    }
}
