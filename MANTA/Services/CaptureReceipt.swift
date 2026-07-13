import Compression
import Foundation
import ImageIO
import MANTACore

struct CaptureReceipt: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case passed, warning, failed }

    struct Check: Codable, Equatable, Sendable {
        var status: Status
        var code: String
        var message: String
        var observationID: UUID?
    }

    var schemaVersion = "1.0.0"
    var generatedAt: Date
    var sessionID: UUID
    var status: Status
    var observationCount: Int
    var decodedImageCount: Int
    var decodedDepthCount: Int
    var decodedConfidenceCount: Int
    var meshVertexCount: Int?
    var meshTriangleCount: Int?
    var checks: [Check]
}

enum CaptureReceiptBuilder {
    static func build(session: ScanSession, sessionDirectory: URL) -> CaptureReceipt {
        var checks = [CaptureReceipt.Check]()
        var imageCount = 0
        var depthCount = 0
        var confidenceCount = 0

        if session.captureObservations.isEmpty {
            checks.append(.init(status: .failed, code: "no-observations",
                                message: "The capture contains no observations."))
        }

        var previousDate: Date?
        var previousARTimestamp: Double?
        for observation in session.captureObservations {
            if let previousDate, observation.capturedAt < previousDate {
                checks.append(.init(
                    status: .failed, code: "nonmonotonic-wall-clock",
                    message: "Observation wall-clock timestamps are not monotonic.",
                    observationID: observation.id))
            }
            previousDate = observation.capturedAt
            if let timestamp = observation.quality?.arFrameTimestamp {
                if let previousARTimestamp, timestamp <= previousARTimestamp {
                    checks.append(.init(
                        status: .failed, code: "nonmonotonic-ar-timestamp",
                        message: "AR frame timestamps are duplicated or out of order.",
                        observationID: observation.id))
                }
                previousARTimestamp = timestamp
            }

            validateMatrices(observation, checks: &checks)

            if let path = observation.cameraSnapshotFilename {
                let url = sessionDirectory.appendingPathComponent(path)
                if validateImage(url, expected: observation.imageResolution) {
                    imageCount += 1
                } else {
                    checks.append(.init(
                        status: .failed, code: "image-decode-or-dimensions",
                        message: "The primary RGB image did not decode at its declared dimensions.",
                        observationID: observation.id))
                }
            } else {
                checks.append(.init(status: .failed, code: "image-missing",
                                    message: "The observation has no RGB image.",
                                    observationID: observation.id))
            }

            if let path = observation.losslessCameraSnapshotFilename {
                let url = sessionDirectory.appendingPathComponent(path)
                if !validateImage(
                    url, expected: observation.imageResolution, expectedType: "public.png"
                ) {
                    checks.append(.init(
                        status: .failed, code: "lossless-image-decode-type-or-dimensions",
                        message: "The lossless RGB companion is not a decodable PNG at the declared dimensions.",
                        observationID: observation.id))
                }
            }

            if let path = observation.compressedCameraSnapshotFilename {
                let url = sessionDirectory.appendingPathComponent(path)
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                let expectedType = ["heic", "heif"].contains(ext) ? "public.heic" : "public.jpeg"
                if !validateImage(
                    url, expected: observation.imageResolution, expectedType: expectedType
                ) {
                    checks.append(.init(
                        status: .failed, code: "compressed-image-decode-type-or-dimensions",
                        message: "The compressed RGB companion did not match its declared codec or dimensions.",
                        observationID: observation.id))
                }
            }

            if let path = observation.rawDepthFilename, let format = observation.rawDepthFormat {
                let expected = format.width * format.height * MemoryLayout<Float32>.size
                if let bytes = decodeZlib(
                    sessionDirectory.appendingPathComponent(path), expectedByteCount: expected
                ) {
                    depthCount += 1
                    validateDepth(bytes, observationID: observation.id, checks: &checks)
                } else {
                    checks.append(.init(
                        status: .failed, code: "depth-decode-or-byte-count",
                        message: "Metric depth did not decompress to the declared byte count.",
                        observationID: observation.id))
                }
            } else if session.captureMode.usesLiDAR {
                checks.append(.init(status: .warning, code: "depth-missing",
                                    message: "A LiDAR observation has no raw metric depth.",
                                    observationID: observation.id))
            }

            if let path = observation.rawConfidenceFilename,
               let format = observation.rawConfidenceFormat {
                if let depth = observation.rawDepthFormat,
                   (format.width != depth.width || format.height != depth.height) {
                    checks.append(.init(
                        status: .failed, code: "confidence-depth-dimensions",
                        message: "Confidence dimensions do not match metric depth.",
                        observationID: observation.id))
                }
                let expected = format.width * format.height
                if let bytes = decodeZlib(
                    sessionDirectory.appendingPathComponent(path), expectedByteCount: expected
                ) {
                    confidenceCount += 1
                    if bytes.contains(where: { $0 > 2 }) {
                        checks.append(.init(
                            status: .warning, code: "unknown-confidence-values",
                            message: "The confidence map contains values outside 0...2.",
                            observationID: observation.id))
                    }
                } else {
                    checks.append(.init(
                        status: .failed, code: "confidence-decode-or-byte-count",
                        message: "Confidence did not decompress to the declared byte count.",
                    observationID: observation.id))
                }
            } else if observation.rawDepthFilename != nil {
                checks.append(.init(
                    status: .warning, code: "confidence-missing",
                    message: "Metric depth has no raw confidence map.",
                    observationID: observation.id))
            }
        }

        var meshVertices: Int?
        var meshTriangles: Int?
        if let path = session.lidarMeshFilename {
            let url = sessionDirectory.appendingPathComponent(path)
            if let data = try? Data(contentsOf: url),
               let mesh = CaptureArtifactStore.parseBinaryLittleEndianPLY(data),
               !mesh.vertices.isEmpty, !mesh.triangleIndices.isEmpty,
               mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) {
                meshVertices = mesh.vertices.count
                meshTriangles = mesh.triangleIndices.count / 3
            } else {
                checks.append(.init(status: .failed, code: "mesh-decode",
                                    message: "The LiDAR mesh is missing, empty, or invalid."))
            }
        } else if session.captureMode.usesLiDAR {
            checks.append(.init(status: .failed, code: "mesh-missing",
                                message: "The LiDAR capture has no persisted mesh."))
        }

        if let bounds = session.headBoundingBox {
            if let path = session.headCroppedLidarMeshFilename,
               let data = try? Data(contentsOf: sessionDirectory.appendingPathComponent(path)),
               let mesh = CaptureArtifactStore.parseBinaryLittleEndianPLY(data),
               !mesh.vertices.isEmpty, !mesh.triangleIndices.isEmpty {
                let center = bounds.center
                let halfWidth = bounds.widthMeters / 2 + 0.001
                let halfHeight = bounds.heightMeters / 2 + 0.001
                let halfDepth = bounds.depthMeters / 2 + 0.001
                if mesh.vertices.contains(where: {
                    abs(Double($0.x) - center.x) > halfWidth
                        || abs(Double($0.y) - center.y) > halfHeight
                        || abs(Double($0.z) - center.z) > halfDepth
                }) {
                    checks.append(.init(
                        status: .warning, code: "head-mesh-outside-bounds",
                        message: "The derived head mesh contains vertices outside its declared boundary."))
                }
            } else {
                checks.append(.init(
                    status: .warning, code: "head-mesh-empty-or-missing",
                    message: "A head boundary was set, but it produced no usable cropped mesh. The full raw mesh is preserved."))
            }
        }

        if checks.isEmpty {
            checks.append(.init(status: .passed, code: "payloads-decode",
                                message: "All declared acquisition payloads decoded successfully."))
        }
        let status: CaptureReceipt.Status = checks.contains(where: { $0.status == .failed })
            ? .failed : checks.contains(where: { $0.status == .warning }) ? .warning : .passed
        return CaptureReceipt(
            generatedAt: Date(), sessionID: session.id, status: status,
            observationCount: session.captureObservations.count,
            decodedImageCount: imageCount, decodedDepthCount: depthCount,
            decodedConfidenceCount: confidenceCount, meshVertexCount: meshVertices,
            meshTriangleCount: meshTriangles, checks: checks)
    }

    private static func validateImage(
        _ url: URL, expected: ImageResolution, expectedType: String? = nil
    ) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        let typeMatches = expectedType.map { CGImageSourceGetType(source) as String? == $0 } ?? true
        return typeMatches && width == expected.width && height == expected.height
    }

    private static func decodeZlib(_ url: URL, expectedByteCount: Int) -> [UInt8]? {
        guard expectedByteCount > 0, let compressed = try? Data(contentsOf: url) else { return nil }
        var output = [UInt8](repeating: 0, count: expectedByteCount + 1)
        let decoded = compressed.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == expectedByteCount else { return nil }
        output.removeLast()
        return output
    }

    private static func validateDepth(
        _ bytes: [UInt8], observationID: UUID, checks: inout [CaptureReceipt.Check]
    ) {
        let validCount = bytes.withUnsafeBytes { raw -> Int in
            var count = 0
            for offset in stride(from: 0, to: raw.count, by: MemoryLayout<UInt32>.size) {
                let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let value = Float32(bitPattern: bits)
                if value.isFinite && value > 0 { count += 1 }
            }
            return count
        }
        if validCount == 0 {
            checks.append(.init(status: .failed, code: "depth-no-valid-values",
                                message: "Metric depth has no finite positive samples.",
                                observationID: observationID))
        }
    }

    private static func validateMatrices(
        _ observation: CaptureObservation, checks: inout [CaptureReceipt.Check]
    ) {
        guard observation.cameraIntrinsics.count == 9,
              observation.cameraTransform.count == 16,
              observation.cameraIntrinsics.allSatisfy(\.isFinite),
              observation.cameraTransform.allSatisfy(\.isFinite) else {
            checks.append(.init(status: .failed, code: "camera-matrix-shape",
                                message: "Camera calibration matrices are malformed.",
                                observationID: observation.id))
            return
        }
        let m = observation.cameraTransform
        let determinant =
            m[0] * (m[5] * m[10] - m[6] * m[9])
            - m[4] * (m[1] * m[10] - m[2] * m[9])
            + m[8] * (m[1] * m[6] - m[2] * m[5])
        if !determinant.isFinite || abs(determinant) < 0.5 || abs(determinant) > 1.5 {
            checks.append(.init(status: .failed, code: "camera-pose-not-rigid",
                                message: "Camera pose rotation is singular or implausibly scaled.",
                                observationID: observation.id))
        }
        if observation.cameraIntrinsics[0] <= 0 || observation.cameraIntrinsics[4] <= 0 {
            checks.append(.init(status: .failed, code: "camera-intrinsics-focal-length",
                                message: "Camera focal lengths must be positive.",
                                observationID: observation.id))
        }
    }
}
