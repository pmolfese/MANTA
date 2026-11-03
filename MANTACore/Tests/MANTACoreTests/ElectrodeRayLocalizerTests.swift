import Testing
import simd
@testable import MANTACore

struct ElectrodeRayLocalizerTests {
    let camera = PinholeCamera(fx: 100, fy: 100, cx: 50, cy: 50, cameraToWorld: matrix_identity_float4x4)
    let vertices: [SIMD3<Float>] = [SIMD3(-1, -1, -0.5), SIMD3(1, -1, -0.5), SIMD3(0, 1, -0.5)]

    @Test func rgbOnlyRayHitsTriangleInteriorAndKeepsOpticalAxisDepth() throws {
        let pixel = SIMD2<Float>(70, 50)
        let hit = try #require(ElectrodeRayLocalizer.locate(pixel: pixel, camera: camera,
            sceneDepth: nil, meshVertices: vertices, meshIndices: [0, 1, 2]))
        #expect(hit.source == .alignedMesh)
        #expect(abs(hit.depthMeters - 0.5) < 1e-5)
        #expect(simd_distance(hit.point, SIMD3(0.1, 0, -0.5)) < 1e-5)
        #expect(simd_distance(try #require(camera.project(hit.point)).pixel, pixel) < 1e-4)
    }

    @Test func validMeshPreferredAndDisagreementFallsBackToActualDepth() throws {
        func locate(_ depth: Float) -> ElectrodeRayLocation? {
            ElectrodeRayLocalizer.locate(pixel: SIMD2(50, 50), camera: camera,
                sceneDepth: depth, meshVertices: vertices, meshIndices: [0, 1, 2])
        }
        #expect(locate(0.51)?.source == .alignedMesh)
        let fallback = try #require(locate(0.8))
        #expect(fallback.source == .sceneDepth)
        #expect(abs(fallback.point.z + 0.8) < 1e-5)
    }

    @Test func missesAndInvalidDepthNeverInventCoordinates() {
        #expect(ElectrodeRayLocalizer.locate(pixel: SIMD2(50, 50), camera: camera,
            sceneDepth: nil, meshVertices: [], meshIndices: []) == nil)
        #expect(ElectrodeRayLocalizer.locate(pixel: SIMD2(50, 50), camera: camera,
            sceneDepth: .nan, meshVertices: vertices.map { -$0 }, meshIndices: [0, 1, 2]) == nil)
        #expect(ElectrodeRayLocalizer.locate(pixel: SIMD2(.nan, 50), camera: camera,
            sceneDepth: 0.5, meshVertices: vertices, meshIndices: [0, 1, 2]) == nil)
        #expect(ElectrodeRayLocalizer.locate(pixel: SIMD2(50, 50), camera: camera,
            sceneDepth: 0.5, meshVertices: [], meshIndices: [])?.source == .sceneDepth)
    }
}
