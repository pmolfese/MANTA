//
//  CaptureArtifactFrameProvider.swift
//  MANTA
//
//  Loads persisted capture artifacts (RGB snapshot, camera model, LiDAR depth)
//  into `DetectionFrame`s for the OCR detector. This is the file-IO counterpart
//  to the pure detection pipeline; the decode here is the inverse of the
//  encoding in CaptureArtifactStore.
//

import CoreGraphics
import Foundation
import MANTACore
import simd

#if canImport(ImageIO) && canImport(Compression)
import Compression
import ImageIO

nonisolated struct CaptureArtifactFrameProvider: DetectionFrameProvider, Sendable {
    let sessionDirectory: URL

    init(store: CaptureArtifactStore, session: ScanSession) {
        sessionDirectory = store.rootDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
    }

    nonisolated init(sessionDirectory: URL) {
        self.sessionDirectory = sessionDirectory
    }

    func frame(for observation: CaptureObservation) -> DetectionFrame? {
        guard
            let snapshot = observation.cameraSnapshotFilename,
            let image = loadImage(relativePath: snapshot),
            let camera = PinholeCamera(intrinsics: observation.cameraIntrinsics, transform: observation.cameraTransform)
        else {
            return nil
        }

        return DetectionFrame(
            image: image,
            camera: camera,
            depthSampler: loadDepthSampler(for: observation)
        )
    }

    /// Loads only the native metric-depth evidence needed by the shared point
    /// fusion engine. RGB decoding is intentionally skipped for the live preview.
    func metricDepthPointFrame(
        for observation: CaptureObservation, frameID: Int
    ) -> MetricDepthPointFrame? {
        guard let grid = loadDepthSampler(for: observation) else { return nil }
        return MetricDepthPointFrame(
            depthValues: grid.depth,
            confidenceValues: grid.confidence,
            depthWidth: grid.depthWidth,
            depthHeight: grid.depthHeight,
            imageWidth: grid.imageWidth,
            imageHeight: grid.imageHeight,
            intrinsics: observation.cameraIntrinsics,
            cameraToWorld: observation.cameraTransform,
            frameID: frameID)
    }

    private func loadImage(relativePath: String) -> CGImage? {
        let url = sessionDirectory.appendingPathComponent(relativePath)
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return image
    }

    private func loadDepthSampler(for observation: CaptureObservation) -> DepthGridSampler? {
        guard
            let depthPath = observation.rawDepthFilename,
            let format = observation.rawDepthFormat,
            let depthData = decompress(
                relativePath: depthPath,
                expectedBytes: format.width * format.height * MemoryLayout<Float32>.stride
            )
        else {
            return nil
        }

        let depth = depthData.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }

        var confidence: [UInt8]?
        if
            let confidencePath = observation.rawConfidenceFilename,
            let confidenceFormat = observation.rawConfidenceFormat,
            let confidenceData = decompress(
                relativePath: confidencePath,
                expectedBytes: confidenceFormat.width * confidenceFormat.height
            ) {
            confidence = Array(confidenceData)
        }

        return DepthGridSampler(
            depth: depth,
            depthWidth: format.width,
            depthHeight: format.height,
            confidence: confidence,
            imageWidth: observation.imageResolution.width,
            imageHeight: observation.imageResolution.height
        )
    }

    private func decompress(relativePath: String, expectedBytes: Int) -> Data? {
        let url = sessionDirectory.appendingPathComponent(relativePath)
        guard let compressed = try? Data(contentsOf: url), expectedBytes > 0 else { return nil }

        var destination = [UInt8](repeating: 0, count: expectedBytes)
        let decodedCount = compressed.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&destination, expectedBytes, base, compressed.count, nil, COMPRESSION_ZLIB)
        }
        guard decodedCount == expectedBytes else { return nil }
        return Data(destination)
    }
}

/// Nearest-neighbor metric depth lookup that maps RGB-image pixels into the
/// lower-resolution depth grid and rejects low-confidence / invalid samples.
nonisolated struct DepthGridSampler: DepthSampler {
    var depth: [Float32]
    var depthWidth: Int
    var depthHeight: Int
    var confidence: [UInt8]?
    var imageWidth: Int
    var imageHeight: Int
    /// Minimum ARKit confidence to accept (0 low, 1 medium, 2 high).
    var minimumConfidence: UInt8 = 1

    func depth(atImagePixel pixel: SIMD2<Float>) -> Float? {
        guard imageWidth > 0, imageHeight > 0, depthWidth > 0, depthHeight > 0 else { return nil }

        let dx = Int((pixel.x / Float(imageWidth)) * Float(depthWidth))
        let dy = Int((pixel.y / Float(imageHeight)) * Float(depthHeight))
        guard dx >= 0, dx < depthWidth, dy >= 0, dy < depthHeight else { return nil }

        let index = dy * depthWidth + dx
        guard index < depth.count else { return nil }

        if let confidence, index < confidence.count, confidence[index] < minimumConfidence {
            return nil
        }

        let value = depth[index]
        guard value.isFinite, value > 0 else { return nil }
        return value
    }
}
#endif
