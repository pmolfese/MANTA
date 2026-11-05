import Foundation
import Testing
import MANTACore
@testable import MANTA

@MainActor
struct CaptureCoverageReviewTests {
    @Test func headReviewSavesSurfaceAndPreservesIdentityAndReferenceMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let suite = "MANTA-head-review-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mesh = LiDARMeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(0.1,0,0), SIMD3(0,0.1,0)], triangleIndices: [0,1,2])
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults, meshSnapshotProvider: { mesh })
        #expect(model.startNewSession(subjectLabel: "Head-only"))
        let id = model.session.id
        model.session.headBoundingBox = .init(center: .zero)
        model.updateAcquisitionContext {
            $0.pairedReferenceSessionID = "legacy-reference"
            $0.referenceExportConfirmed = true
        }
        model.scanViewModel.status.isRunning = true
        model.reviewCaptureCoverage()
        #expect(model.scanViewModel.status.isRunning)
        #expect(model.captureReviewTitle == "Head readiness and review")
        #expect(model.labelPhotoTitle == "Take Head Photo")
        model.targetGuidedView(.left)
        #expect(!model.recaptureGuidance.contains("electrode"))
        await model.inspectSavedHeadSurface()
        #expect(!model.scanViewModel.status.isRunning)
        #expect(model.captureVisualMode == .model)
        #expect(!model.showCoverageReview && !model.isSessionEnded)
        let saved = try store.loadSession(id: id)
        #expect(saved.headCroppedLidarMeshFilename != nil)
        #expect(saved.acquisitionContext?.pairedReferenceSessionID == "legacy-reference")
        #expect(saved.acquisitionContext?.referenceExportConfirmed == true)
        await model.checkBeforeParticipantRelease()
        #expect(!model.releaseCheckMessages.joined().localizedCaseInsensitiveContains("geoscan"))
        #expect(model.session.acquisitionContext?.captureReview?.geometry?.headMeshRecorded == true)
        #expect(model.session.id == id)

        // Changing the crop invalidates review/export provenance, not raw evidence.
        model.session.lastRawExportedBundleID = UUID()
        model.updateHeadBoundingBox { $0.widthMeters += 0.05 }
        #expect(model.session.headCroppedLidarMeshFilename == nil)
        #expect(model.session.lidarMeshFilename != nil)
        #expect(model.session.acquisitionContext?.captureReview == nil)
        #expect(model.session.lastRawExportedBundleID == nil)
        #expect(!model.scanViewModel.hasMotionReference(for: model.session.headBoundingBox))
        #expect(model.releaseCheckMessages.isEmpty)
    }

    @Test func reviewAndRecaptureTargetingDoNotPauseTrackingOrChangeSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let suite = "MANTA-review-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(model.startNewSession(subjectLabel: "Bench"))
        let id = model.session.id
        model.scanViewModel.status.isRunning = true
        model.reviewCaptureCoverage()
        #expect(model.showCoverageReview)
        #expect(model.scanViewModel.status.isRunning)
        model.targetGuidedView(.left)
        #expect(model.selectedGuidedView == .left)
        #expect(model.recaptureTargetLabel == nil)
        model.targetRecapture(label: "E1")
        #expect(model.selectedGuidedView == nil)
        #expect(model.recaptureTargetLabel == "E1")
        #expect(model.scanViewModel.status.isRunning)
        #expect(model.session.id == id)
        #expect(model.savedGuidedViews.isEmpty)
    }
}
