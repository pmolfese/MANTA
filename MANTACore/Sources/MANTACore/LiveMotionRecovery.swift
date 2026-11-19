import Foundation
import simd

/// A live correction changes the stored camera pose, never the camera-local pixels.
/// The original AR pose remains available for audit and image orientation.
public struct LiveMotionCorrection: Codable, Equatable, Hashable, Sendable {
    public var referenceSegmentID: UUID
    public var referenceFromWorld: [Float]
    public var originalCameraToWorld: [Float]
    public var validatedFrameCount: Int
    public var trackedLabelCount: Int?
    public var landmarkTimestamp: Double?
    public var method = "automatic-rigid-withheld-frames-v1"

    public init(referenceSegmentID: UUID, transform: simd_float4x4, originalCameraToWorld: [Float], validatedFrameCount: Int) {
        self.referenceSegmentID = referenceSegmentID
        referenceFromWorld = SegmentRegistration.flatten(transform)
        self.originalCameraToWorld = originalCameraToWorld
        self.validatedFrameCount = validatedFrameCount
    }

    public var correctedCameraToWorld: [Float]? {
        let validMethod = method == "automatic-rigid-withheld-frames-v1"
            || (method == "net-anchored-continuous-rigid-v1" && (trackedLabelCount ?? 0) >= 4 && landmarkTimestamp?.isFinite == true)
        guard validMethod, validatedFrameCount >= 3,
              let transform = SegmentRegistration.matrix(referenceFromWorld), SegmentRegistration.rigid(transform),
              let original = SegmentRegistration.matrix(originalCameraToWorld), SegmentRegistration.rigid(original) else { return nil }
        return SegmentRegistration.flatten(transform * original)
    }

    public func supportsFrame(timestamp: Double) -> Bool {
        guard correctedCameraToWorld != nil else { return false }
        guard method == "net-anchored-continuous-rigid-v1" else { return true }
        guard let landmarkTimestamp, timestamp.isFinite else { return false }
        return timestamp >= landmarkTimestamp && timestamp - landmarkTimestamp <= ContinuousNetTracker.maximumLandmarkAge
    }

    public func matches(camera: [Float]) -> Bool {
        guard let corrected = correctedCameraToWorld, camera.count == 16 else { return false }
        return zip(corrected, camera).allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) < 0.0001 }
    }
}

/// A solver result is only a candidate. Three later, distinct frames must agree
/// with it. A failed check discards the candidate; it never falls back to identity.
public struct LiveMotionRecovery: Sendable {
    public private(set) var transform: simd_float4x4?
    public private(set) var alignedReference: [SIMD3<Float>] = []
    public private(set) var hasCandidate = false
    public private(set) var validatedFrameCount = 0
    private var candidate: simd_float4x4?
    private var reference: [SIMD3<Float>] = []
    private var lastValidationTimestamp = -Double.infinity

    public init() {}

    @discardableResult
    public mutating func propose(_ result: SegmentRegistrationResult, reference: [SIMD3<Float>], timestamp: Double) -> Bool {
        guard result.accepted, timestamp.isFinite, reference.count >= 50,
              let values = result.referenceFromSource, let matrix = SegmentRegistration.matrix(values), SegmentRegistration.rigid(matrix),
              let rms = result.rmsMeters, rms.isFinite, rms <= SegmentRegistration.maximumRMSMeters,
              let forward = result.sourceOverlap, forward >= SegmentRegistration.minimumOverlap,
              let reverse = result.referenceOverlap, reverse >= SegmentRegistration.minimumOverlap else { return false }
        candidate = matrix
        self.reference = reference
        lastValidationTimestamp = timestamp
        validatedFrameCount = 0
        hasCandidate = true
        return true
    }

    public mutating func validate(points: [SIMD3<Float>], timestamp: Double) -> Bool {
        guard let candidate, timestamp.isFinite, timestamp > lastValidationTimestamp else { return false }
        lastValidationTimestamp = timestamp
        guard points.count >= 50, SegmentRegistration.spatiallyDistributed(points),
              SegmentRegistration.frameAgrees(points: points, reference: reference, transform: candidate) else {
            discardCandidate()
            return false
        }
        validatedFrameCount += 1
        guard validatedFrameCount >= 3 else { return false }
        transform = candidate
        alignedReference = reference
        self.candidate = nil
        hasCandidate = false
        reference = []
        return true
    }

    public mutating func discardCandidate() {
        candidate = nil
        hasCandidate = false
        reference = []
        validatedFrameCount = 0
    }
}
