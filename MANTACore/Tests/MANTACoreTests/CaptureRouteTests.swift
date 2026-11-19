import Foundation
import Testing
@testable import MANTACore

struct CaptureRouteTests {
    @Test func jumpingAheadRetainsSkippedChecksAndRevisitingDoesNotCompleteThem() throws {
        var route = CaptureRouteProgress()
        route.select(.photos)
        #expect(route.skippedSteps == [.setup, .reference, .orbit])
        #expect(route.acknowledgedSteps.isEmpty)
        route.select(.reference)
        #expect(route.skippedSteps.contains(.reference))
        route.select(.orbit, acknowledgingCurrent: true)
        #expect(route.acknowledgedSteps == [.reference])
        #expect(!route.skippedSteps.contains(.reference))
        #expect(route.skippedSteps.contains(.setup))
        let decoded = try JSONDecoder().decode(CaptureRouteProgress.self, from: JSONEncoder().encode(route))
        #expect(decoded == route)
    }
    @Test func movementAndNewFramesInvalidateInspectionWithoutInventingCompletion() {
        var route = CaptureRouteProgress()
        route.acknowledgedSteps = [.setup, .reference, .orbit, .photos, .review]
        route.reviewedObservationCount = 49
        route.invalidateReview()
        #expect(route.reviewedObservationCount == nil)
        #expect(!route.acknowledgedSteps.contains(.review))
        route.flagMovement()
        #expect(route.selectedStep == .reference)
        #expect(route.acknowledgedSteps == [.setup])
        #expect(route.skippedSteps.isSuperset(of: [.reference, .orbit, .photos, .review]))
        route.select(.finish, acknowledgingCurrent: true)
        #expect(!route.acknowledgedSteps.contains(.finish))
    }
    @Test func legacySessionDecodesWithoutRouteAndNewRouteKeepsPassLink() throws {
        var session = ScanSession.newSession(layout: .headMeshOnly)
        let legacy = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(ScanSession.self, from: legacy).captureRoute == nil)
        var route = CaptureRouteProgress()
        route.previousSessionID = UUID()
        session.captureRoute = route
        let decoded = try JSONDecoder().decode(ScanSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.captureRoute == route)
    }
}
