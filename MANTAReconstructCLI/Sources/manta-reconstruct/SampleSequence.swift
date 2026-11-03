import Compression
import CoreGraphics
import CoreMotion
import CoreVideo
import Foundation
import ImageIO
import MANTACore
import RealityKit
import simd

// Ported from the receiver's ReceiverPhotogrammetrySampleSequence.
//
/// A lazily evaluated sequence of `PhotogrammetrySample`s for depth-guided
/// Object Capture. Each element carries the frame's RGB image, its LiDAR depth
/// map (when available), and a gravity vector derived from the stored camera
/// pose. Samples are built on demand so peak memory stays bounded to the frames
/// Object Capture is actively reading rather than the whole capture at once.
///
/// Orientation note: the RGB image is drawn in its native pixel orientation and
/// the depth is written row-major at its stored resolution. The depth artifact's
/// `resolution-scale` mapping is defined against that same native image grid, so
/// image and depth stay mutually aligned. Absolute orientation is conveyed
/// separately via `gravity`, so we deliberately do not re-apply EXIF rotation.
struct PhotogrammetrySampleSequence: Sequence {
    let descriptors: [ReconstructionSampleDescriptor]

    func makeIterator() -> Iterator {
        Iterator(descriptors: descriptors)
    }

    struct Iterator: IteratorProtocol {
        let descriptors: [ReconstructionSampleDescriptor]
        var index = 0

        mutating func next() -> PhotogrammetrySample? {
            while index < descriptors.count {
                let descriptor = descriptors[index]
                index += 1
                // An unreadable RGB image can't seed a sample at all; skip it.
                // A missing depth map is fine - the frame still contributes its
                // image and gravity.
                guard let image = PhotogrammetrySampleSequence
                    .loadImageBuffer(descriptor.imageURL) else { continue }
                var sample = PhotogrammetrySample(id: descriptor.sampleID, image: image)
                sample.depthDataMap = PhotogrammetrySampleSequence
                    .loadDepthBuffer(descriptor)
                // `PhotogrammetrySample.gravity` is a CMAcceleration (gravity
                // direction, ~1 g magnitude); our unit world-down-in-camera maps
                // to it directly.
                if let gravity = CameraGravity.inCameraSpace(
                    cameraToWorld: descriptor.cameraToWorld) {
                    sample.gravity = CMAcceleration(
                        x: Double(gravity.x), y: Double(gravity.y), z: Double(gravity.z))
                }
                return sample
            }
            return nil
        }
    }

    /// Loads an image file into a 32BGRA pixel buffer in its native pixel
    /// orientation (no EXIF rotation applied).
    static func loadImageBuffer(_ url: URL) -> CVPixelBuffer? {
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

    /// Builds a `DepthFloat32` pixel buffer from a frame's stored metric-depth
    /// artifact. Non-finite or non-positive samples become NaN so Object Capture
    /// treats them as unknown rather than as a surface at zero range.
    static func loadDepthBuffer(
        _ descriptor: ReconstructionSampleDescriptor
    ) -> CVPixelBuffer? {
        guard let url = descriptor.depthURL,
              descriptor.depthWidth > 0, descriptor.depthHeight > 0 else { return nil }
        let count = descriptor.depthWidth * descriptor.depthHeight
        guard let depth = decodeDepth(
            url, compression: descriptor.depthCompression, expectedCount: count) else { return nil }

        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, descriptor.depthWidth, descriptor.depthHeight,
            kCVPixelFormatType_DepthFloat32, attributes as CFDictionary,
            &buffer) == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        depth.withUnsafeBufferPointer { source in
            for row in 0..<descriptor.depthHeight {
                let destination = base.advanced(by: row * rowBytes)
                    .assumingMemoryBound(to: Float.self)
                for column in 0..<descriptor.depthWidth {
                    let value = source[row * descriptor.depthWidth + column]
                    destination[column] = (value.isFinite && value > 0) ? value : Float.nan
                }
            }
        }
        return pixelBuffer
    }

    private static func decodeDepth(
        _ url: URL, compression: String, expectedCount: Int
    ) -> [Float]? {
        guard let source = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let expectedBytes = expectedCount * MemoryLayout<Float>.size
        let raw: Data
        if compression.lowercased() == "zlib" {
            var destination = Data(count: expectedBytes)
            let decoded = destination.withUnsafeMutableBytes { output in
                source.withUnsafeBytes { input -> Int in
                    guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
                          let inputBase = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        outputBase, expectedBytes, inputBase, source.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard decoded == expectedBytes else { return nil }
            raw = destination
        } else {
            guard source.count == expectedBytes else { return nil }
            raw = source
        }
        return raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
