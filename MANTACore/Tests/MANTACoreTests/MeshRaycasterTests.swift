import Testing
import simd
@testable import MANTACore

struct MeshRaycasterTests {
    // A unit quad on the z = 0 plane, spanning x,y in [0,1], as two triangles.
    private let quadVertices: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)
    ]
    private let quadIndices: [UInt32] = [0, 1, 2, 0, 2, 3]

    @Test func hitsFrontFacingTriangleAtExpectedPoint() {
        let hit = MeshRaycaster.firstHit(
            origin: SIMD3(0.25, 0.25, 2),
            direction: SIMD3(0, 0, -1),
            vertices: quadVertices,
            triangleIndices: quadIndices)
        #expect(hit != nil)
        if let hit {
            #expect(abs(hit.x - 0.25) < 1e-4)
            #expect(abs(hit.y - 0.25) < 1e-4)
            #expect(abs(hit.z - 0) < 1e-4)
        }
    }

    @Test func returnsNearestOfTwoParallelFaces() {
        // Two stacked quads; ray from +z must hit the nearer (z = 1) one.
        var vertices = quadVertices
        var indices = quadIndices
        let base = UInt32(vertices.count)
        vertices += quadVertices.map { SIMD3($0.x, $0.y, 1) }
        indices += quadIndices.map { $0 + base }

        let hit = MeshRaycaster.firstHit(
            origin: SIMD3(0.5, 0.5, 5),
            direction: SIMD3(0, 0, -1),
            vertices: vertices,
            triangleIndices: indices)
        #expect(hit != nil)
        #expect(abs((hit?.z ?? -99) - 1) < 1e-4)
    }

    @Test func missesWhenRayPointsAway() {
        let hit = MeshRaycaster.firstHit(
            origin: SIMD3(0.5, 0.5, 2),
            direction: SIMD3(0, 0, 1), // away from the quad
            vertices: quadVertices,
            triangleIndices: quadIndices)
        #expect(hit == nil)
    }

    @Test func missesOutsideTriangleBounds() {
        let hit = MeshRaycaster.firstHit(
            origin: SIMD3(5, 5, 2),
            direction: SIMD3(0, 0, -1),
            vertices: quadVertices,
            triangleIndices: quadIndices)
        #expect(hit == nil)
    }

    @Test func hitsBackFaceBecauseTrianglesAreDoubleSided() {
        // Ray from -z travelling +z hits the same quad from behind.
        let hit = MeshRaycaster.firstHit(
            origin: SIMD3(0.5, 0.5, -2),
            direction: SIMD3(0, 0, 1),
            vertices: quadVertices,
            triangleIndices: quadIndices)
        #expect(hit != nil)
        #expect(abs((hit?.z ?? -99) - 0) < 1e-4)
    }

    @Test func toleratesUnnormalizedDirection() {
        let hit = MeshRaycaster.firstHit(
            origin: SIMD3(0.5, 0.5, 2),
            direction: SIMD3(0, 0, -10), // not unit length
            vertices: quadVertices,
            triangleIndices: quadIndices)
        #expect(hit != nil)
        #expect(abs((hit?.z ?? -99) - 0) < 1e-4)
    }
}
