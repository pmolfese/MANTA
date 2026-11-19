import Foundation
import CoreVideo
import MANTACore

/// Buffers are private copies, never mutated after submission to the writer.
nonisolated struct OwnedCaptureBuffers: @unchecked Sendable {
    let image: CVPixelBuffer
    let depth: CVPixelBuffer?
    let confidence: CVPixelBuffer?
}

@MainActor
final class CaptureBufferPool {
    private var pools: [String: CVPixelBufferPool] = [:]

    func copy(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let key = "\(width)-\(height)-\(format)"
        if pools[key] == nil {
            // Bound cached free buffers across format/session changes as well as
            // active jobs. Removing a pool does not invalidate its live buffers.
            if pools.count >= 4 { pools.removeAll() }
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else { throw CaptureFrameWriteError.bufferCopy }
            pools[key] = pool
        }
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pools[key]!,
            [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &destination)
        guard status == kCVReturnSuccess, let destination else { throw CaptureFrameWriteError.bufferCopy }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw CaptureFrameWriteError.bufferCopy
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            throw CaptureFrameWriteError.bufferCopy
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planeCount = CVPixelBufferGetPlaneCount(source)
        for plane in 0..<max(1, planeCount) {
            let src = planeCount == 0 ? CVPixelBufferGetBaseAddress(source) : CVPixelBufferGetBaseAddressOfPlane(source, plane)
            let dst = planeCount == 0 ? CVPixelBufferGetBaseAddress(destination) : CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            guard let src, let dst else { throw CaptureFrameWriteError.bufferCopy }
            let srcStride = planeCount == 0 ? CVPixelBufferGetBytesPerRow(source) : CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let dstStride = planeCount == 0 ? CVPixelBufferGetBytesPerRow(destination) : CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let rows = planeCount == 0 ? height : CVPixelBufferGetHeightOfPlane(source, plane)
            for row in 0..<rows {
                memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), min(srcStride, dstStride))
            }
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }
}

nonisolated enum CaptureFrameWriteError: LocalizedError {
    case bufferCopy, storageUnavailable
    var errorDescription: String? {
        switch self {
        case .bufferCopy: "Could not copy the capture buffers into bounded app-owned memory."
        case .storageUnavailable: "Capture write stopped: available storage is unknown or at the reserve."
        }
    }
}

nonisolated struct CaptureFrameWriteResult: Sendable {
    let observation: CaptureObservation
    let timings: [String: String]
}

nonisolated enum CaptureFrameWriter {
    static func write(buffers: OwnedCaptureBuffers, observation initial: CaptureObservation,
                      store: CaptureArtifactStore, session: ScanSession,
                      includeCompressedImage: Bool, enqueuedAt: TimeInterval) throws -> CaptureFrameWriteResult {
        let started = ProcessInfo.processInfo.systemUptime
        guard let capacity = store.availableCapacityBytes, capacity > CaptureStoragePolicy.reserveBytes else {
            throw CaptureFrameWriteError.storageUnavailable
        }
        var observation = initial
        let imageStarted = ProcessInfo.processInfo.systemUptime
        let camera = try store.writeCameraSnapshot(pixelBuffer: buffers.image, observationID: observation.id,
                                                   for: session, includeCompressedImage: includeCompressedImage)
        observation.cameraSnapshotFilename = camera.primaryFilename
        observation.compressedCameraSnapshotFilename = camera.compressedFilename
        let imageFinished = ProcessInfo.processInfo.systemUptime
        if let depth = buffers.depth {
            let artifact = try store.writeDepthSnapshot(depthMap: depth, confidenceMap: buffers.confidence,
                                                       observationID: observation.id, for: session)
            observation.depthSnapshotFilename = artifact.filename
            observation.rawDepthFilename = artifact.rawDepthFilename
            observation.rawDepthFormat = artifact.rawDepthFormat
            observation.rawConfidenceFilename = artifact.rawConfidenceFilename
            observation.rawConfidenceFormat = artifact.rawConfidenceFormat
            observation.confidenceSummary = artifact.confidenceSummary
            observation.depthSummary = artifact.summary
            let pixels = artifact.summary.width * artifact.summary.height
            observation.quality?.validDepthFraction = pixels > 0 ? Double(artifact.summary.validPixelCount) / Double(pixels) : nil
            if let summary = artifact.confidenceSummary {
                let total = summary.lowConfidenceCount + summary.mediumConfidenceCount + summary.highConfidenceCount + summary.unknownConfidenceCount
                observation.quality?.highConfidenceDepthFraction = total > 0 ? Double(summary.highConfidenceCount) / Double(total) : nil
            }
            if let fraction = observation.quality?.validDepthFraction, fraction < 0.5 {
                observation.quality?.warnings.append("low-depth-coverage")
            }
        }
        let depthFinished = ProcessInfo.processInfo.systemUptime
        try store.writeObservationCheckpoint(observation, for: session)
        let finished = ProcessInfo.processInfo.systemUptime
        return CaptureFrameWriteResult(observation: observation, timings: [
            "queueWaitDurationMs": String((started - enqueuedAt) * 1_000),
            "imageWriteDurationMs": String((imageFinished - imageStarted) * 1_000),
            "depthWriteDurationMs": String((depthFinished - imageFinished) * 1_000),
            "checkpointWriteDurationMs": String((finished - depthFinished) * 1_000),
            "artifactSaveDurationMs": String((finished - started) * 1_000),
            "saveDurationMs": String((finished - enqueuedAt) * 1_000)
        ])
    }
}
