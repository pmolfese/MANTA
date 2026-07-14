//
//  LiDARMeshSnapshotIOTests.swift
//  MANTATests
//
//  Round-trips the binary-PLY LiDAR mesh so the cameras-off (reopened session)
//  fiducial-placement path can rely on reading back what capture persisted.
//

import Foundation
import MANTACore
import Testing
import simd
@testable import MANTA

struct LiDARMeshSnapshotIOTests {
    private func makeStore() throws -> CaptureArtifactStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTATests-\(UUID().uuidString)", isDirectory: true)
        return try CaptureArtifactStore(rootDirectory: root)
    }

    @Test func writesAndReadsBackMeshSnapshot() throws {
        let store = try makeStore()
        var session = ScanSession.newSession()

        let snapshot = LiDARMeshSnapshot(
            vertices: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0),
                SIMD3(0, 1, 0), SIMD3(0.5, 0.5, 0.25)
            ],
            triangleIndices: [0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4])

        session.lidarMeshFilename = try store.writeLiDARMeshSnapshot(snapshot, for: session)

        let loaded = try #require(store.loadLiDARMeshSnapshot(for: session))
        #expect(loaded.vertices.count == snapshot.vertices.count)
        #expect(loaded.triangleIndices == snapshot.triangleIndices)
        for (a, b) in zip(loaded.vertices, snapshot.vertices) {
            #expect(simd_distance(a, b) < 1e-5)
        }
    }

    @Test func loadReturnsNilWhenNoMeshPersisted() throws {
        let store = try makeStore()
        let session = ScanSession.newSession() // lidarMeshFilename == nil
        #expect(store.loadLiDARMeshSnapshot(for: session) == nil)
    }

    @Test func readBackMeshSupportsRaycasting() throws {
        let store = try makeStore()
        var session = ScanSession.newSession()
        let snapshot = LiDARMeshSnapshot(
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
            triangleIndices: [0, 1, 2, 0, 2, 3])
        session.lidarMeshFilename = try store.writeLiDARMeshSnapshot(snapshot, for: session)

        let loaded = try #require(store.loadLiDARMeshSnapshot(for: session))
        let hit = MeshRaycaster.firstHit(
            origin: SIMD3(0.25, 0.25, 2), direction: SIMD3(0, 0, -1),
            vertices: loaded.vertices, triangleIndices: loaded.triangleIndices)
        let point = try #require(hit)
        #expect(abs(point.z) < 1e-4)
    }

    @Test func headBoundsKeepOnlyFullyContainedTriangles() {
        let snapshot = LiDARMeshSnapshot(
            vertices: [
                SIMD3(-0.1, 0, 0), SIMD3(0.1, 0, 0), SIMD3(0, 0.1, 0),
                SIMD3(1, 0, 0), SIMD3(1.1, 0, 0), SIMD3(1, 0.1, 0)
            ],
            triangleIndices: [0, 1, 2, 3, 4, 5])
        let bounds = HeadBoundingBox(
            center: .zero, widthMeters: 0.5, heightMeters: 0.5, depthMeters: 0.5)

        let cropped = snapshot.cropped(to: bounds)

        #expect(cropped.vertices.count == 3)
        #expect(cropped.triangleIndices == [0, 1, 2])
    }
}
