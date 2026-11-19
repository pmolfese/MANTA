#if os(macOS)
import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import RealityKit
import MANTACore

@available(macOS 26.0, *)
public struct ObjectCaptureImages: Sequence {
    public let directory: URL
    public let records: [ReconstructionCameraRecord]
    public init(directory: URL, records: [ReconstructionCameraRecord]) { self.directory = directory; self.records = records }
    public func makeIterator() -> AnyIterator<PhotogrammetrySample> {
        var iterator = records.makeIterator()
        return AnyIterator {
            while let record = iterator.next() {
                guard let image = Self.loadImageBuffer(directory.appendingPathComponent(record.imageFilename)) else { continue }
                return PhotogrammetrySample(id: record.sampleID, image: image)
            }
            return nil
        }
    }
    public static func loadImageBuffer(_ url: URL) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer) == kCVReturnSuccess,
            let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

}
#endif
