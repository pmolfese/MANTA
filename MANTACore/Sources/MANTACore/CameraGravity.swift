import simd

/// Derives the gravity vector Object Capture wants for a `PhotogrammetrySample`
/// from a capture's stored camera pose. `PhotogrammetrySample.gravity` is the
/// direction of gravity expressed in the camera's own coordinate frame; we have
/// each frame's `cameraToWorld`, so we can rotate the known world-down direction
/// into camera space instead of recording a separate gravity reading at capture.
public enum CameraGravity {
    /// World "down" in the camera's local frame, from a column-major 4x4
    /// camera→world transform. ARKit's world is Y-up, so world-down is
    /// `(0, -1, 0)`. Returns a unit vector, or nil when the transform is
    /// malformed or its rotation is degenerate.
    ///
    /// The rotation block of `cameraToWorld` maps camera axes into world; the
    /// inverse (its transpose, for an orthonormal rotation) maps world vectors
    /// back into camera space. Any uniform scale in the matrix cancels once the
    /// result is normalized.
    public static func inCameraSpace(
        cameraToWorld values: [Float],
        worldDown: SIMD3<Float> = SIMD3(0, -1, 0)
    ) -> SIMD3<Float>? {
        guard values.count == 16 else { return nil }
        // Column-major: columns 0,1,2 are the camera basis expressed in world.
        let rotation = simd_float3x3(
            SIMD3(values[0], values[1], values[2]),
            SIMD3(values[4], values[5], values[6]),
            SIMD3(values[8], values[9], values[10]))
        let cameraFromWorld = rotation.transpose
        let gravity = cameraFromWorld * worldDown
        let length = simd_length(gravity)
        guard length.isFinite, length > 1e-6 else { return nil }
        return gravity / length
    }

    /// Convenience for the `[Double]` transforms stored on observations.
    public static func inCameraSpace(
        cameraToWorld values: [Double],
        worldDown: SIMD3<Float> = SIMD3(0, -1, 0)
    ) -> SIMD3<Float>? {
        inCameraSpace(cameraToWorld: values.map(Float.init), worldDown: worldDown)
    }
}
