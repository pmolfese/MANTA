import Foundation
import simd

public enum ElectrodeDepthSource: String, Codable, Sendable {
    case alignedMesh
    case sceneDepth
}

public struct ElectrodeRayLocation: Sendable {
    public let point: SIMD3<Float>
    /// Optical-axis depth, not distance along the oblique ray.
    public let depthMeters: Float
    public let source: ElectrodeDepthSource
}

public enum ElectrodeRayLocalizer {
    /// Mesh must already be in the camera's world frame. A depth disagreement
    /// rejects the mesh hit, not the observed scene depth. Limits are provisional.
    public static func locate(pixel: SIMD2<Float>, camera: PinholeCamera,
                              sceneDepth: Float?, meshVertices: [SIMD3<Float>],
                              meshIndices: [UInt32], maximumDepthDisagreement: Float = 0.03) -> ElectrodeRayLocation? {
        func validDepth(_ value: Float) -> Bool { value.isFinite && value >= 0.05 && value <= 2 }
        let origin4 = camera.cameraToWorld.columns.3
        let origin = SIMD3(origin4.x, origin4.y, origin4.z)
        let ray = camera.unproject(pixel: pixel, depth: 1) - origin
        guard pixel.x.isFinite, pixel.y.isFinite, camera.fx.isFinite, camera.fy.isFinite,
              camera.fx > 0, camera.fy > 0, ray.x.isFinite, ray.y.isFinite, ray.z.isFinite,
              simd_length(ray) > 1e-6 else { return nil }
        let depth = sceneDepth.flatMap { validDepth($0) ? $0 : nil }
        if let hit = MeshRaycaster.firstHit(origin: origin, direction: ray,
                vertices: meshVertices, triangleIndices: meshIndices),
           let projection = camera.project(hit), validDepth(projection.depth),
           depth.map({ abs($0 - projection.depth) <= maximumDepthDisagreement }) ?? true {
            return ElectrodeRayLocation(point: hit, depthMeters: projection.depth, source: .alignedMesh)
        }
        guard let depth else { return nil }
        let point = camera.unproject(pixel: pixel, depth: depth)
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        return ElectrodeRayLocation(point: point, depthMeters: depth, source: .sceneDepth)
    }
}
