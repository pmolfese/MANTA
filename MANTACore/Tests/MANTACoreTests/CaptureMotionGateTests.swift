import Foundation
import Testing
@testable import MANTACore

struct CaptureMotionGateTests {
    private let segment = UUID()
    private func sample(_ state: CaptureMotionAssessment.State) -> CaptureMotionAssessment {
        .init(segmentID: segment, state: state, residualMeters: 0.03, overlapFraction: 0.8)
    }

    @Test func transientMismatchHoldsImmediatelyAndNeedsThreeGoodFrames() {
        var gate = CaptureMotionGate()
        let trusted = gate.assess(sample(.consistent), timestamp: 1)
        let held = gate.assess(sample(.suspected), timestamp: 2)
        #expect(held.state == .insufficientEvidence)
        #expect(held.residualMeters == 0.03)
        #expect(gate.isHolding)
        #expect(!gate.requiresAlignment)
        #expect(gate.assess(sample(.consistent), timestamp: 3).state == .insufficientEvidence)
        #expect(gate.assess(sample(.consistent), timestamp: 4).state == .insufficientEvidence)
        #expect(gate.assess(sample(.consistent), timestamp: 5).state == .consistent)
        #expect(!gate.isHolding)
        #expect(trusted.state == .consistent)
    }

    @Test func sustainedMovementLatchesWithoutTrustingAnApparentReturn() {
        var gate = CaptureMotionGate()
        for t in 1...3 { _ = gate.assess(sample(.suspected), timestamp: Double(t)) }
        #expect(gate.requiresAlignment)
        for t in 4...10 { #expect(gate.assess(sample(.consistent), timestamp: Double(t)).state == .suspected) }
        #expect(gate.isHolding)
        gate = CaptureMotionGate()
        #expect(gate.assess(sample(.consistent), timestamp: 1).state == .consistent)
    }

    @Test func occlusionAndDuplicateFramesCannotEstablishMovementOrRecovery() {
        var gate = CaptureMotionGate()
        _ = gate.assess(sample(.suspected), timestamp: 1)
        for _ in 0..<5 { _ = gate.assess(sample(.suspected), timestamp: 1) }
        #expect(!gate.requiresAlignment)
        _ = gate.assess(sample(.insufficientEvidence), timestamp: 2)
        _ = gate.assess(sample(.consistent), timestamp: 3)
        for _ in 0..<5 { _ = gate.assess(sample(.consistent), timestamp: 3) }
        #expect(gate.isHolding)
        _ = gate.assess(sample(.consistent), timestamp: 4)
        #expect(gate.isHolding)
        #expect(gate.assess(sample(.consistent), timestamp: 5).state == .consistent)
    }
}
