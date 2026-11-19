import XCTest
import simd
@testable import MANTACore

final class CameraGravityTests: XCTestCase {
    /// Column-major flattening matching the stored `cameraToWorld` layout.
    private func flatten(_ m: simd_float4x4) -> [Float] {
        (0..<4).flatMap { col in (0..<4).map { row in m[col][row] } }
    }

    func testIdentityPoseReturnsWorldDown() throws {
        let gravity = try XCTUnwrap(
            CameraGravity.inCameraSpace(cameraToWorld: flatten(matrix_identity_float4x4)))
        XCTAssertEqual(gravity.x, 0, accuracy: 1e-6)
        XCTAssertEqual(gravity.y, -1, accuracy: 1e-6)
        XCTAssertEqual(gravity.z, 0, accuracy: 1e-6)
    }

    func testRotationIsInverted() throws {
        // Camera rotated +90° about world Z (camera→world). World-down (0,-1,0)
        // should map to (-1, 0, 0) in camera space: gravity_cam = Rᵀ · down.
        let rotation = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        let gravity = try XCTUnwrap(
            CameraGravity.inCameraSpace(cameraToWorld: flatten(rotation)))
        XCTAssertEqual(gravity.x, -1, accuracy: 1e-6)
        XCTAssertEqual(gravity.y, 0, accuracy: 1e-6)
        XCTAssertEqual(gravity.z, 0, accuracy: 1e-6)
    }

    func testResultIsUnitLengthUnderUniformScale() throws {
        var scaled = matrix_identity_float4x4
        scaled.columns.0 *= 4
        scaled.columns.1 *= 4
        scaled.columns.2 *= 4
        let gravity = try XCTUnwrap(
            CameraGravity.inCameraSpace(cameraToWorld: flatten(scaled)))
        XCTAssertEqual(simd_length(gravity), 1, accuracy: 1e-6)
        XCTAssertEqual(gravity.y, -1, accuracy: 1e-6)
    }

    func testMalformedTransformReturnsNil() {
        XCTAssertNil(CameraGravity.inCameraSpace(cameraToWorld: [Float](repeating: 0, count: 9)))
        XCTAssertNil(CameraGravity.inCameraSpace(cameraToWorld: [Float](repeating: 0, count: 16)))
    }
}
