import AppKit
import Compression
import CoreGraphics
import Foundation
import ImageIO
import MANTACore
import SceneKit
import simd

struct ReceiverDepthFusionInput: Sendable {
    var rootDirectory: URL
    var observations: [MANTACaptureObservation]
    var declaredBounds: HeadBoundingBox?
    var headMeshURL: URL?
    var fiducialCoordinates: [SIMD3<Float>]

    nonisolated init(
        rootDirectory: URL,
        observations: [MANTACaptureObservation],
        declaredBounds: HeadBoundingBox?,
        headMeshURL: URL?,
        fiducialCoordinates: [SIMD3<Float>]
    ) {
        self.rootDirectory = rootDirectory
        self.observations = observations
        self.declaredBounds = declaredBounds
        self.headMeshURL = headMeshURL
        self.fiducialCoordinates = fiducialCoordinates
    }
}

struct ReceiverFusedDepthCloud: Sendable {
    var points: [SIMD3<Float>]
    var colors: [SIMD4<Float>]
    var contributingFrames: Int
    var acceptedDepthSamples: Int
    var voxelSizeMeters: Float
    var usedInferredBounds: Bool

    nonisolated var summary: String {
        let source = usedInferredBounds ? "inferred head region" : "declared head region"
        return "\(points.count.formatted()) points · \(contributingFrames) frames · \(source)"
    }

    @MainActor
    func makeNode() -> SCNNode {
        let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let colorData = colors.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let indices = Array(UInt32(0)..<UInt32(points.count))
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: points.count,
            bytesPerIndex: MemoryLayout<UInt32>.size)
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 7
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}

enum ReceiverDepthFusionError: LocalizedError {
    case noDepth
    case noHeadRegion
    case noFusedPoints

    nonisolated var errorDescription: String? {
        switch self {
        case .noDepth: "No decodable metric-depth observations were found."
        case .noHeadRegion: "Depth fusion needs a declared head box, head mesh, or fiducials."
        case .noFusedPoints: "Depth frames did not produce repeatable points inside the head region."
        }
    }
}

enum ReceiverDepthFusion {
    private nonisolated struct Bounds: Sendable {
        var center: SIMD3<Float>
        var halfExtent: SIMD3<Float>

        nonisolated func contains(_ point: SIMD3<Float>) -> Bool {
            let delta = abs(point - center)
            return delta.x <= halfExtent.x
                && delta.y <= halfExtent.y
                && delta.z <= halfExtent.z
        }
    }

    private nonisolated struct VoxelKey: Hashable, Sendable {
        var x: Int32
        var y: Int32
        var z: Int32
    }

    private nonisolated struct Accumulator: Sendable {
        var position = SIMD3<Double>.zero
        var color = SIMD4<Double>.zero
        var samples = 0
        var views = 0
        var lastFrame = -1
    }

    nonisolated static func fuse(
        _ input: ReceiverDepthFusionInput,
        voxelSize: Float = 0.004,
        minimumConfidence: UInt8 = 2
    ) throws -> ReceiverFusedDepthCloud {
        let resolved = try resolveBounds(input)
        var voxels = [VoxelKey: Accumulator]()
        voxels.reserveCapacity(100_000)
        var contributingFrames = 0
        var acceptedSamples = 0

        for (frameIndex, observation) in input.observations.enumerated() {
            guard let depth = observation.depth,
                  depth.scalarType.lowercased() == "float32",
                  depth.units == .meters,
                  depth.byteOrder.lowercased() == "little-endian",
                  depth.layout.lowercased()
                    .replacingOccurrences(of: "-", with: "")
                    .hasPrefix("rowmajor"),
                  depth.imageMapping.lowercased() == "resolution-scale",
                  observation.intrinsics.count == 9,
                  observation.cameraToWorld.count == 16 else { continue }
            let width = depth.dimensions.width
            let height = depth.dimensions.height
            let count = width * height
            guard count > 0,
                  let depthData = decode(
                    input.rootDirectory.appendingPathComponent(depth.path),
                    compression: depth.compression,
                    expectedSize: count * MemoryLayout<Float>.size),
                  depthData.count == count * MemoryLayout<Float>.size else { continue }
            let confidence: Data? = depth.confidencePath.flatMap {
                decode(
                    input.rootDirectory.appendingPathComponent($0),
                    compression: depth.compression,
                    expectedSize: count)
            }
            let rgba = observation.imagePath.flatMap {
                downsampledRGBA(
                    url: input.rootDirectory.appendingPathComponent($0),
                    width: width, height: height)
            }
            let transform = matrix(observation.cameraToWorld)
            let fx = Float(observation.intrinsics[0])
            let fy = Float(observation.intrinsics[4])
            let cx = Float(observation.intrinsics[6])
            let cy = Float(observation.intrinsics[7])
            guard fx.isFinite, fy.isFinite, fx != 0, fy != 0 else { continue }
            let sx = Float(observation.imageDimensions.width) / Float(width)
            let sy = Float(observation.imageDimensions.height) / Float(height)
            var frameAccepted = 0

            depthData.withUnsafeBytes { depthBytes in
                let depthValues = depthBytes.bindMemory(to: Float.self)
                confidence?.withUnsafeBytes { confidenceBytes in
                    let confidenceValues = confidenceBytes.bindMemory(to: UInt8.self)
                    accumulate(
                        depthValues: depthValues,
                        confidenceValues: confidenceValues,
                        rgba: rgba,
                        width: width,
                        height: height,
                        imageScaleX: sx,
                        imageScaleY: sy,
                        fx: fx, fy: fy, cx: cx, cy: cy,
                        cameraToWorld: transform,
                        bounds: resolved.bounds,
                        voxelSize: voxelSize,
                        minimumConfidence: minimumConfidence,
                        frameIndex: frameIndex,
                        voxels: &voxels,
                        accepted: &frameAccepted)
                } ?? accumulate(
                    depthValues: depthValues,
                    confidenceValues: nil,
                    rgba: rgba,
                    width: width,
                    height: height,
                    imageScaleX: sx,
                    imageScaleY: sy,
                    fx: fx, fy: fy, cx: cx, cy: cy,
                    cameraToWorld: transform,
                    bounds: resolved.bounds,
                    voxelSize: voxelSize,
                    minimumConfidence: minimumConfidence,
                    frameIndex: frameIndex,
                    voxels: &voxels,
                    accepted: &frameAccepted)
            }
            if frameAccepted > 0 { contributingFrames += 1 }
            acceptedSamples += frameAccepted
        }

        guard contributingFrames > 0 else { throw ReceiverDepthFusionError.noDepth }
        var retained = voxels.values.filter { $0.views >= 2 }
        if retained.count < 500 {
            retained = Array(voxels.values)
        }
        guard !retained.isEmpty else { throw ReceiverDepthFusionError.noFusedPoints }
        retained.sort {
            if $0.position.x != $1.position.x { return $0.position.x < $1.position.x }
            if $0.position.y != $1.position.y { return $0.position.y < $1.position.y }
            return $0.position.z < $1.position.z
        }
        let stride = max(1, Int(ceil(Double(retained.count) / 180_000.0)))
        let selected = Swift.stride(from: 0, to: retained.count, by: stride).map { retained[$0] }
        let points = selected.map { value -> SIMD3<Float> in
            SIMD3<Float>(value.position / Double(value.samples))
        }
        let colors = selected.map { value -> SIMD4<Float> in
            let averaged = value.color / Double(value.samples)
            return SIMD4<Float>(averaged)
        }
        return ReceiverFusedDepthCloud(
            points: points,
            colors: colors,
            contributingFrames: contributingFrames,
            acceptedDepthSamples: acceptedSamples,
            voxelSizeMeters: voxelSize,
            usedInferredBounds: resolved.inferred)
    }

    private nonisolated static func accumulate(
        depthValues: UnsafeBufferPointer<Float>,
        confidenceValues: UnsafeBufferPointer<UInt8>?,
        rgba: [UInt8]?,
        width: Int,
        height: Int,
        imageScaleX: Float,
        imageScaleY: Float,
        fx: Float, fy: Float, cx: Float, cy: Float,
        cameraToWorld: simd_float4x4,
        bounds: Bounds,
        voxelSize: Float,
        minimumConfidence: UInt8,
        frameIndex: Int,
        voxels: inout [VoxelKey: Accumulator],
        accepted: inout Int
    ) {
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if let confidenceValues,
                   index < confidenceValues.count,
                   confidenceValues[index] < minimumConfidence { continue }
                let depth = depthValues[index]
                guard depth.isFinite, depth >= 0.20, depth <= 2.0 else { continue }
                let pixelX = (Float(x) + 0.5) * imageScaleX
                let pixelY = (Float(y) + 0.5) * imageScaleY
                let camera = SIMD4<Float>(
                    (pixelX - cx) / fx * depth,
                    -(pixelY - cy) / fy * depth,
                    -depth,
                    1)
                let transformed = cameraToWorld * camera
                let world = SIMD3(transformed.x, transformed.y, transformed.z)
                guard bounds.contains(world) else { continue }
                let key = VoxelKey(
                    x: Int32(floor(world.x / voxelSize)),
                    y: Int32(floor(world.y / voxelSize)),
                    z: Int32(floor(world.z / voxelSize)))
                let color: SIMD4<Double>
                if let rgba, index * 4 + 3 < rgba.count {
                    color = SIMD4(
                        Double(rgba[index * 4]) / 255,
                        Double(rgba[index * 4 + 1]) / 255,
                        Double(rgba[index * 4 + 2]) / 255,
                        1)
                } else {
                    color = SIMD4(0.24, 0.82, 0.95, 1)
                }
                var value = voxels[key] ?? Accumulator()
                value.position += SIMD3<Double>(world)
                value.color += color
                value.samples += 1
                if value.lastFrame != frameIndex {
                    value.views += 1
                    value.lastFrame = frameIndex
                }
                voxels[key] = value
                accepted += 1
            }
        }
    }

    private nonisolated static func resolveBounds(
        _ input: ReceiverDepthFusionInput
    ) throws -> (bounds: Bounds, inferred: Bool) {
        if let declared = input.declaredBounds {
            return (Bounds(
                center: SIMD3(
                    Float(declared.center.x), Float(declared.center.y), Float(declared.center.z)),
                halfExtent: SIMD3(
                    Float(declared.widthMeters / 2),
                    Float(declared.heightMeters / 2),
                    Float(declared.depthMeters / 2))), false)
        }
        if let url = input.headMeshURL, let meshBounds = plyBounds(url) {
            let center = (meshBounds.minimum + meshBounds.maximum) / 2
            // The head-cropped mesh is a much better prior than a generic adult-head
            // box. Preserve a small margin for depth noise, but clamp it so shoulders
            // and the far side of the room cannot dominate an inferred fusion.
            let measured = (meshBounds.maximum - meshBounds.minimum) / 2
            let padded = measured + SIMD3<Float>(repeating: 0.025)
            let minimum = SIMD3<Float>(0.09, 0.16, 0.14)
            let maximum = SIMD3<Float>(0.16, 0.22, 0.19)
            let halfExtent = simd_min(simd_max(padded, minimum), maximum)
            return (Bounds(center: center, halfExtent: halfExtent), true)
        }
        if !input.fiducialCoordinates.isEmpty {
            let center = input.fiducialCoordinates.reduce(.zero, +)
                / Float(input.fiducialCoordinates.count)
            return (Bounds(center: center, halfExtent: SIMD3(0.16, 0.22, 0.19)), true)
        }
        throw ReceiverDepthFusionError.noHeadRegion
    }

    private nonisolated static func plyBounds(
        _ url: URL
    ) -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let marker = data.range(of: Data("end_header\n".utf8)) else { return nil }
        let header = String(decoding: data[..<marker.lowerBound], as: UTF8.self)
        let vertexCount = header.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[0] == "element", fields[1] == "vertex" else {
                return nil
            }
            return Int(fields[2])
        }.first ?? 0
        guard vertexCount > 0, marker.upperBound + vertexCount * 12 <= data.endIndex else { return nil }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        data.withUnsafeBytes { bytes in
            for index in 0..<vertexCount {
                let offset = marker.upperBound + index * 12
                let x = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: offset, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: offset + 4, as: UInt32.self)))
                let z = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: offset + 8, as: UInt32.self)))
                let point = SIMD3(x, y, z)
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
        }
        return (minimum, maximum)
    }

    private nonisolated static func decode(
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
        guard decoded == expectedSize else { return nil }
        return destination
    }

    private nonisolated static func downsampledRGBA(
        url: URL, width: Int, height: Int
    ) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return created ? pixels : nil
    }

    private nonisolated static func matrix(_ values: [Double]) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3])),
            SIMD4(Float(values[4]), Float(values[5]), Float(values[6]), Float(values[7])),
            SIMD4(Float(values[8]), Float(values[9]), Float(values[10]), Float(values[11])),
            SIMD4(Float(values[12]), Float(values[13]), Float(values[14]), Float(values[15])))
    }
}
