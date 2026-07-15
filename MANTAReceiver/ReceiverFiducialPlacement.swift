import Compression
import Foundation
import MANTACore
import simd

struct ReceiverImageFiducialHit: Sendable {
    var worldPoint: SIMD3<Float>
    var rawImagePoint: SIMD2<Float>
    var depthMeters: Float
    var confidence: UInt8
    var contributingDepthPixels: Int
}

enum ReceiverFiducialPlacementError: LocalizedError {
    case noDepth
    case unsupportedDepth
    case invalidCamera
    case noReliableDepth

    var errorDescription: String? {
        switch self {
        case .noDepth: "This frame has no saved metric depth."
        case .unsupportedDepth: "This frame's depth artifact could not be decoded."
        case .invalidCamera: "This frame has invalid camera calibration."
        case .noReliableDepth: "No reliable depth was found near that pixel. Try another view or click slightly inward from the silhouette."
        }
    }
}

enum ReceiverImageFiducialResolver {
    static func resolve(
        rawImagePoint: SIMD2<Float>,
        observation: MANTACaptureObservation,
        rootDirectory: URL
    ) throws -> ReceiverImageFiducialHit {
        guard let artifact = observation.depth else {
            throw ReceiverFiducialPlacementError.noDepth
        }
        guard artifact.scalarType.lowercased() == "float32",
              artifact.units == .meters,
              artifact.byteOrder.lowercased() == "little-endian",
              artifact.layout.lowercased().replacingOccurrences(of: "-", with: "")
                .hasPrefix("rowmajor"),
              artifact.imageMapping.lowercased() == "resolution-scale" else {
            throw ReceiverFiducialPlacementError.unsupportedDepth
        }
        guard let camera = PinholeCamera(
            intrinsics: observation.intrinsics.map(Float.init),
            transform: observation.cameraToWorld.map(Float.init)) else {
            throw ReceiverFiducialPlacementError.invalidCamera
        }

        let width = artifact.dimensions.width
        let height = artifact.dimensions.height
        let count = width * height
        guard count > 0,
              let depthData = decode(
                rootDirectory.appendingPathComponent(artifact.path),
                compression: artifact.compression,
                expectedSize: count * MemoryLayout<Float>.size) else {
            throw ReceiverFiducialPlacementError.unsupportedDepth
        }
        let confidenceData = artifact.confidencePath.flatMap {
            decode(
                rootDirectory.appendingPathComponent($0),
                compression: artifact.compression,
                expectedSize: count)
        }
        let depthValues = depthData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let confidenceValues = confidenceData.map(Array.init)

        let centerX = Int(rawImagePoint.x / Float(observation.imageDimensions.width) * Float(width))
        let centerY = Int(rawImagePoint.y / Float(observation.imageDimensions.height) * Float(height))
        guard (0..<width).contains(centerX), (0..<height).contains(centerY) else {
            throw ReceiverFiducialPlacementError.noReliableDepth
        }
        // Anatomical fiducials often lie on a silhouette. A 5x5 depth patch is
        // tens of RGB pixels wide at ARKit's lower depth-map resolution, so its
        // median can land on hair or background despite an accurate visible
        // click. Prefer the reliable sample directly under the click and use a
        // neighborhood only when that exact depth pixel is unavailable.
        let direct = sample(
            x: centerX, y: centerY, width: width,
            depth: depthValues, confidence: confidenceValues,
            minimumConfidence: 2)
            ?? sample(
                x: centerX, y: centerY, width: width,
                depth: depthValues, confidence: confidenceValues,
                minimumConfidence: 1)

        let resolvedDepth: Float
        let resolvedConfidence: UInt8
        let contributingDepthPixels: Int
        if let direct {
            resolvedDepth = direct.depth
            resolvedConfidence = direct.confidence
            contributingDepthPixels = 1
        } else {
            let candidates = samples(
                centerX: centerX,
                centerY: centerY,
                width: width,
                height: height,
                depth: depthValues,
                confidence: confidenceValues,
                minimumConfidence: 2)
            let resolved = candidates.isEmpty
                ? samples(
                    centerX: centerX, centerY: centerY, width: width, height: height,
                    depth: depthValues, confidence: confidenceValues, minimumConfidence: 1)
                : candidates
            guard !resolved.isEmpty else {
                throw ReceiverFiducialPlacementError.noReliableDepth
            }
            let sorted = resolved.sorted { $0.depth < $1.depth }
            let median = sorted[sorted.count / 2]
            resolvedDepth = median.depth
            resolvedConfidence = median.confidence
            contributingDepthPixels = sorted.count
        }

        let world = camera.unproject(pixel: rawImagePoint, depth: resolvedDepth)
        return ReceiverImageFiducialHit(
            worldPoint: world,
            rawImagePoint: rawImagePoint,
            depthMeters: resolvedDepth,
            confidence: resolvedConfidence,
            contributingDepthPixels: contributingDepthPixels)
    }

    private static func sample(
        x: Int, y: Int, width: Int,
        depth: [Float], confidence: [UInt8]?, minimumConfidence: UInt8
    ) -> (depth: Float, confidence: UInt8)? {
        let index = y * width + x
        guard depth.indices.contains(index) else { return nil }
        let value = depth[index]
        let quality = confidence?[index] ?? 2
        guard quality >= minimumConfidence,
              value.isFinite, value >= 0.20, value <= 2.0 else { return nil }
        return (value, quality)
    }

    private static func samples(
        centerX: Int, centerY: Int, width: Int, height: Int,
        depth: [Float], confidence: [UInt8]?, minimumConfidence: UInt8
    ) -> [(depth: Float, confidence: UInt8)] {
        var result = [(Float, UInt8)]()
        for y in max(0, centerY - 2)...min(height - 1, centerY + 2) {
            for x in max(0, centerX - 2)...min(width - 1, centerX + 2) {
                let index = y * width + x
                let value = depth[index]
                let quality = confidence?[index] ?? 2
                guard quality >= minimumConfidence,
                      value.isFinite, value >= 0.20, value <= 2.0 else { continue }
                result.append((value, quality))
            }
        }
        return result
    }

    private static func decode(
        _ url: URL, compression: String, expectedSize: Int
    ) -> Data? {
        guard let source = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard compression.lowercased() == "zlib" else {
            return source.count == expectedSize ? source : nil
        }
        var destination = Data(count: expectedSize)
        let decoded = destination.withUnsafeMutableBytes { output in
            source.withUnsafeBytes { input in
                guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outputBase, expectedSize, inputBase, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return decoded == expectedSize ? destination : nil
    }
}
