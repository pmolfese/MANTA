//
//  ModelPointCloudLoader.swift
//  MANTA
//
//  Reads a reconstructed model (USDZ) into a world-space point cloud so it can be
//  registered against the LiDAR mesh via ICP. This is the ICP "source" cloud, the
//  counterpart to ARScanViewModel.meshWorldPoints() (the "target").
//

import Foundation
import simd

#if canImport(ModelIO)
import ModelIO

public enum ModelPointCloudLoader {
    /// Loads mesh vertices from a model file, transformed by each mesh's object transform,
    /// and subsampled to roughly `maxPoints`. Returns an empty array on any failure.
    public static func load(url: URL, maxPoints: Int = 6000) -> [SIMD3<Float>] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let asset = MDLAsset(url: url)
        let meshes = (asset.childObjects(of: MDLMesh.self) as? [MDLMesh]) ?? []
        guard !meshes.isEmpty else { return [] }

        let totalVertices = meshes.reduce(0) { $0 + $1.vertexCount }
        guard totalVertices > 0 else { return [] }
        let stride = max(1, totalVertices / max(1, maxPoints))

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(min(totalVertices, maxPoints) + meshes.count)

        var globalIndex = 0
        for mesh in meshes {
            guard let positions = mesh.vertexAttributeData(
                forAttributeNamed: MDLVertexAttributePosition,
                as: .float3
            ) else {
                globalIndex += mesh.vertexCount
                continue
            }

            let base = positions.dataStart
            let vertexStride = positions.stride
            let transform = mesh.transform?.matrix ?? matrix_identity_float4x4

            for i in 0..<mesh.vertexCount {
                defer { globalIndex += 1 }
                guard globalIndex % stride == 0 else { continue }

                let pointer = base.advanced(by: i * vertexStride).assumingMemoryBound(to: Float.self)
                let world = transform * SIMD4<Float>(pointer[0], pointer[1], pointer[2], 1)
                points.append(SIMD3<Float>(world.x, world.y, world.z))
            }
        }

        return points
    }
}
#else
public enum ModelPointCloudLoader {
    public static func load(url: URL, maxPoints: Int = 6000) -> [SIMD3<Float>] { [] }
}
#endif
