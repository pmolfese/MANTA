//
//  ScanSessionViewModel.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import Combine
import MANTACore
import simd
#if canImport(UIKit)
import UIKit
#endif

/// A prepared export archive, wrapped so SwiftUI can present a share sheet via
/// `.sheet(item:)`.
struct ExportedBundle: Identifiable {
    let id = UUID()
    let urls: [URL]
}

enum CaptureVisualMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case model = "Head Model"
    case split = "Split"
    var id: String { rawValue }
}

@MainActor
final class ScanSessionViewModel: ObservableObject {
    @Published var session = ScanSession.newSession(layout: .headMeshOnly)
    // Tracks whether a session has been selected, independently of its optional label.
    @Published private(set) var needsSessionName = true
    @Published var captureSaveError: String?
    @Published private(set) var isEndingSession = false
    @Published private(set) var isStartingPass = false
    @Published var sessionEndSummary: String?
    var isSessionEnded: Bool { session.endedAt != nil }
    var canEndSession: Bool {
        !needsSessionName && !isSessionEnded && !isEndingSession
            && !isExporting && !isCheckingRelease && !isReconstructing && !isDetecting
    }
    private var canAcquire: Bool { !needsSessionName && !isSessionEnded && !isEndingSession && !isDrainingCapture && !isExporting && !isCheckingRelease && !isDetecting && !isReconstructing }
    @Published private(set) var routeInspectionStep: CaptureRouteStep?
    var captureRouteStep: CaptureRouteStep {
        routeInspectionStep ?? (isSessionEnded ? .finish : session.captureRoute?.selectedStep ?? .setup)
    }
    var canNavigateCaptureRoute: Bool {
        !needsSessionName && !isEndingSession && !isCheckingRelease && !isExporting
            && !isDrainingCapture && !isReconstructing && !isDetecting
    }
    var highResolutionPhotoCount: Int {
        session.captureObservations.filter { $0.quality?.captureSource == "high-resolution-still" }.count
    }
    func captureRouteRequirementMet(_ step: CaptureRouteStep) -> Bool {
        switch step {
        case .setup: !needsSessionName
        case .reference: scanViewModel.hasMotionReference(for: session.headBoundingBox)
        case .orbit: !scanViewModel.motionStopped && !session.captureObservations.isEmpty
        case .photos: !scanViewModel.motionStopped && savedGuidedViews.count == CaptureGuidedView.allCases.count
        case .review: !scanViewModel.motionStopped && !scanViewModel.status.isRunning
            && session.captureRoute?.reviewedObservationCount == session.captureObservations.count
            && session.headCroppedLidarMeshFilename != nil
        case .finish: isSessionEnded
        }
    }
    func captureRouteCompleted(_ step: CaptureRouteStep) -> Bool {
        if step == .finish { return isSessionEnded }
        guard session.captureRoute?.acknowledgedSteps.contains(step) == true else { return false }
        // A historical frozen reference is not an armed reference after reopening.
        return captureRouteRequirementMet(step)
    }
    func selectCaptureRouteStep(_ step: CaptureRouteStep, acknowledgeCurrent: Bool = false) {
        guard canNavigateCaptureRoute else { return }
        if isSessionEnded { routeInspectionStep = step; return }
        let previous = session.captureRoute
        var route = previous ?? CaptureRouteProgress()
        route.select(step, acknowledgingCurrent: acknowledgeCurrent && captureRouteRequirementMet(captureRouteStep))
        session.captureRoute = route
        guard persistSession() else { session.captureRoute = previous; return }
        recordAcquisitionEvent(.init(kind: "capture-route-selected", message: step.rawValue,
            details: ["skippedSteps": route.skippedSteps.map(\.rawValue).sorted().joined(separator: ",")]))
    }
    func advanceCaptureRoute() {
        guard let next = captureRouteStep.next else { return }
        selectCaptureRouteStep(next, acknowledgeCurrent: true)
    }
    func freezeCaptureRouteReference() {
        scanViewModel.freezeMotionReference(bounds: session.headBoundingBox)
        // Stay here until the operator advances; a failed freeze never marks done.
    }
    func acknowledgeCaptureSurfaceReview() {
        guard canNavigateCaptureRoute, !isSessionEnded, !scanViewModel.status.isRunning,
              !scanViewModel.motionStopped, session.headCroppedLidarMeshFilename != nil else { return }
        let previous = session.captureRoute
        var route = previous ?? CaptureRouteProgress()
        route.reviewedObservationCount = session.captureObservations.count
        session.captureRoute = route
        if !persistSession() { session.captureRoute = previous }
    }
    func startNewStationaryPass() async {
        guard canNavigateCaptureRoute, !isSessionEnded, scanViewModel.motionStopped,
              let artifactStore else { return }
        isStartingPass = true
        defer { isStartingPass = false }
        isEndingSession = true // Exclude switching while writes and pass metadata drain.
        await finishCaptureWrites()
        guard captureSaveError == nil, saveCaptureCheckpoint() else { isEndingSession = false; return }
        let previous = session
        let segmentID = scanViewModel.motionSegmentID
        do {
            _ = try artifactStore.writeCaptureReceipt(for: session)
            let archive = try CapturePassArchive.save(session: session, segmentID: segmentID,
                in: artifactStore.sessionDirectory(for: session))
            var passes = session.capturePasses ?? []
            passes.removeAll { $0.segmentID == segmentID }
            passes.append(archive)
            session.capturePasses = passes
            // Keep every frame and the session identity; only the new world's
            // geometry and landmarks must start fresh.
            session.lidarMeshFilename = nil
            session.headCroppedLidarMeshFilename = nil
            session.headBoundingBox = nil
            session.photogrammetryModelFilename = nil
            session.worldAlignmentTransform = nil
            session.fiducials = FiducialKind.cardinal.map { FiducialAnnotation(kind: $0, coordinate: nil, state: .needsReview) }
            session.modelFiducials = session.fiducials
            session.electrodes = []
            session.acquisitionContext?.captureReview = nil
            session.lastRawExportedBundleID = nil
            session.lastExportedBundleID = nil
            var route = CaptureRouteProgress()
            route.select(.reference, acknowledgingCurrent: true)
            session.captureRoute = route
            guard persistSession() else { session = previous; isEndingSession = false; return }
        } catch {
            session = previous
            captureSaveError = "Could not save the previous pass: \(error.localizedDescription)"
            isEndingSession = false
            return
        }
        scanViewModel.resetForNewCapture()
        restoreCaptureView()
        cachedMeshSnapshot = nil
        resetLiveDetection()
        resetLiveMetricDepthFusion()
        routeInspectionStep = nil
        captureVisualMode = .split
        sessionEndSummary = nil
        isEndingSession = false
        refreshSessions()
        recordAcquisitionEvent(.init(kind: "capture-pass-started", message: "New pass in the same session; previous frames and geometry retained.",
            details: ["previousSegmentID": segmentID.uuidString, "segmentID": scanViewModel.motionSegmentID.uuidString]))
        startLiveScan()
    }

    @Published var availableLayouts: [ElectrodeLayout] = [.headMeshOnly, .fallback128]
    @Published var selectedLayoutName = ElectrodeLayout.headMeshOnly.name
    @Published var scanViewModel = ARScanViewModel()
    @Published var captureVisualMode: CaptureVisualMode = .split
    private var captureViewBeforePause: CaptureVisualMode?

    private func restoreCaptureView() {
        if let previous = captureViewBeforePause { captureVisualMode = previous }
        captureViewBeforePause = nil
    }
    @Published var selectedFormat: ElectrodeExportFormat = .csv
    @Published var exportPreview = ""
    @Published var isDetecting = false
    @Published var liveDetectionEnabled = false
    /// Debug acquisition option used to compare the primary lossless PNG with a
    /// compressed HEIC/JPEG encoding of the exact same sampled frame.
    @Published var releaseCheckMessages: [String] = []
    @Published var isCheckingRelease = false
    @Published var captureCompressedImageReferences = false
    private var lastStillRequest = Date.distantPast
    @Published var isLiveDetecting = false
    @Published var showCoverageReview = false
    @Published var selectedGuidedView: CaptureGuidedView?
    @Published var recaptureTargetLabel: String?
    var savedGuidedViews: Set<CaptureGuidedView> { CaptureReviewPolicy.savedViews(session.captureObservations) }
    var singleViewLiveLabels: [String] {
        liveLabelCoverage.seenLabels.subtracting(liveLabelCoverage.supportedLabels).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }
    var liveOCRReviewedFrameCount: Int { liveProcessedFrameIDs.count }
    var labelPhotoTitle: String {
        if let recaptureTargetLabel { return "Photograph \(recaptureTargetLabel)" }
        if let selectedGuidedView { return "Take \(selectedGuidedView.title) Photo" }
        return session.layout.hasElectrodeNet ? "Take Label Photo" : "Take Head Photo"
    }
    var recaptureGuidance: String {
        if let label = recaptureTargetLabel {
            return "Find \(label) on the net. Move closer, avoid glare, and take sharp views from different angles. This target is not a confirmed location."
        }
        if let view = selectedGuidedView {
            return session.layout.hasElectrodeNet ? view.guidance : view.headGuidance
        }
        return "Keep tracking and sampling active. Collect overlapping front, left, right, back, and top views. View tags are optional."
    }
    func reviewCaptureCoverage() {
        showCoverageReview = true
        recordAcquisitionEvent(AcquisitionEvent(kind: "coverage-review-opened", message: "Reviewing gaps while tracking remains active."))
    }
    func targetRecapture(label: String) {
        recaptureTargetLabel = label
        selectedGuidedView = nil
        showCoverageReview = false
        recordAcquisitionEvent(AcquisitionEvent(kind: "recapture-target-selected", message: label))
    }
    func targetGuidedView(_ view: CaptureGuidedView) {
        selectedGuidedView = view
        recaptureTargetLabel = nil
        showCoverageReview = false
    }
    private func captureReviewSnapshot() -> CaptureReviewRecord {
        CaptureReviewRecord(observationCount: session.captureObservations.count,
            processedLiveFrameCount: liveProcessedFrameIDs.count,
            missingViews: CaptureGuidedView.allCases.filter { !savedGuidedViews.contains($0) }.map(\.rawValue),
            unreadLabels: unreadLiveLabels, ambiguousLabels: liveLabelCoverage.ambiguousLabels.sorted(),
            singleViewLabels: singleViewLiveLabels,
            motionFlagged: scanViewModel.motionStopped || session.captureObservations.contains {
                $0.quality?.motionAssessment?.state == .suspected
            }, geometry: geometryReview)
    }

    var geometryReview: CaptureGeometryReview { CaptureGeometryReview(session: session) }
    var captureReviewTitle: String { session.layout.hasElectrodeNet ? "Review and recapture" : "Head readiness and review" }
    var viewCoverageText: String {
        geometryReview.viewSectorCount.map { "\($0)/24" } ?? "Unknown"
    }
    var geometryReviewMessages: [String] {
        let review = geometryReview
        return [
            "Head region: \(review.headRegionSet ? "set" : "not set").",
            "View coverage: \(viewCoverageText) camera-position sectors; not surface completeness.",
            "Depth recorded: \(review.depthFrameCount)/\(review.observationCount) frames; confidence recorded: \(review.confidenceFrameCount)/\(review.depthFrameCount) depth frames. RGB-only photos remain useful.",
            "Head surface: \(review.headMeshRecorded ? "crop recorded; inspect the saved surface" : "no saved head crop"). Full environment mesh: \(review.environmentMeshRecorded ? "recorded" : "not recorded").",
            "Blur warnings: \(review.blurWarningCount); sharpness unknown: \(review.unknownSharpnessCount).",
            "Motion evidence: \(review.motionConsistentCount) consistent, \(review.motionUnknownCount) unknown/insufficient, \(review.motionSuspectCount) suspect frames. Consistency is advisory."
        ]
    }

    func selectHeadRegionFromReview() {
        guard scanViewModel.status.isRunning, !scanViewModel.motionStopped else { return }
        startHeadBoundsPlacement()
        captureVisualMode = .camera
        showCoverageReview = false
    }

    var canInspectHeadSurface: Bool {
        !needsSessionName && !isEndingSession && !isExporting && !isCheckingRelease
            && !isDrainingCapture && !isReconstructing && !isDetecting
    }

    /// Save accepted work before showing the paused, manually inspectable model.
    /// Opening the viewer is not an assertion that the surface is complete.
    func inspectSavedHeadSurface() async {
        guard canInspectHeadSurface else { return }
        cancelAutoSampling()
        scanViewModel.pause()
        fiducialPlacementKind = nil
        isHeadBoundsPlacementActive = false
        await finishCaptureWrites()
        guard captureSaveError == nil else { return }
        if captureViewBeforePause == nil { captureViewBeforePause = captureVisualMode }
        captureVisualMode = .model
        showCoverageReview = false
        recordAcquisitionEvent(.init(kind: "head-surface-review-opened", message: "Capture paused and saved for manual surface inspection."))
        statusMessage = "Orbit and zoom the saved head. Inspect the crown, sides, ears, and rear for holes or doubled surfaces. After movement, start a new pass."
    }

    private func invalidateHeadRegionReview() {
        session.captureRoute?.invalidateReview()
        session.captureRoute?.acknowledgedSteps.remove(.reference)
        scanViewModel.invalidateMotionReferenceForRegionChange()
        session.headCroppedLidarMeshFilename = nil
        session.acquisitionContext?.captureReview = nil
        session.lastRawExportedBundleID = nil
        session.lastExportedBundleID = nil
        releaseCheckMessages = []
    }

    @Published private(set) var liveLabelCoverage = LiveLabelCoverage()
    var unreadLiveLabels: [String] {
        session.layout.electrodes.map { "E\($0.number)" }.filter { !liveLabelCoverage.seenLabels.contains($0) && !liveLabelCoverage.ambiguousLabels.contains($0) }
    }
    @Published var liveElectrodes: [ElectrodeAnnotation] = []
    @Published var liveDetectionStatus = "Waiting for a saved frame."
    @Published var isAutoSampling = false
    @Published var autoSamplingInterval = 0.75
    @Published var statusMessage = "Ready to start a LiDAR + photogrammetry scan."
    @Published var diagnosticsPath = ""
    @Published var isReconstructing = false
    @Published var reconstructionProgress: Double?
    @Published var promptForModelFiducials = false
    @Published var sessionSummaries: [SessionSummary] = []
    @Published var exportedBundle: ExportedBundle?
    @Published private(set) var isExporting = false
    private(set) var exportTask: Task<Void, Never>?
    private var activeExportID: UUID?
    @Published var exportProgress = 0.0
    @Published var exportStage = ""
    @Published var exportStartedAt: Date?
    /// When set, the next tap on the live scan places this fiducial.
    @Published var fiducialPlacementKind: FiducialKind?
    /// When set, the next tap on the 3D head model places this fiducial. This is
    /// the cameras-off path: it works while the session is paused or reopened,
    /// intersecting fused depth or the LiDAR mesh instead of the live camera.
    @Published var modelFiducialPlacementKind: FiducialKind?
    @Published var isHeadBoundsPlacementActive = false
    /// Starts each new unbounded scan in tap-to-place mode. This can be disabled
    /// before capture for workflows that intentionally want the full environment.
    @Published var requestHeadRegionOnScanStart = true
    /// Incremental high-confidence RGB-D derivative shown in the Live Model tab.
    /// Raw depth frames remain the authoritative evidence for offline fusion.
    @Published var liveMetricDepthPointCloud = MetricDepthPointCloudSnapshot()
    @Published var liveMetricDepthFusionStatus = "Set the head region to build dense depth points."

    /// Cached mesh loaded from disk, used when no live anchors are in memory
    /// (e.g. a reopened session). Live anchors always take precedence.
    private var cachedMeshSnapshot: LiDARMeshSnapshot?
    private let liveMetricDepthFusion = LiveMetricDepthFusion()

    var isGuidedFiducialPlacementActive: Bool { fiducialPlacementKind != nil }
    var isModelSurfacePlacementActive: Bool { modelFiducialPlacementKind != nil }

    var fiducialPlacementPrompt: String? {
        guard let kind = fiducialPlacementKind else { return nil }
        return "Find the \(kind.rawValue), then tap it in the camera view."
    }

    var modelFiducialPlacementPrompt: String? {
        guard let kind = modelFiducialPlacementKind else { return nil }
        return "Tap the \(kind.rawValue) on the head model."
    }

    var scanPlacementPrompt: String? {
        if isHeadBoundsPlacementActive {
            return "Tap the center of the visible head to define the LiDAR region."
        }
        return fiducialPlacementPrompt
    }

    /// The mesh to display and tap for offline placement: the live in-memory mesh
    /// when scanning, otherwise the mesh persisted for this session.
    func displayMeshSnapshot() -> LiDARMeshSnapshot {
        if scanViewModel.motionStopped { return LiDARMeshSnapshot(vertices: [], triangleIndices: []) }
        if !scanViewModel.status.isRunning, let cached = cachedMeshSnapshot {
            return session.headBoundingBox.map { cached.cropped(to: $0) } ?? cached
        }
        let live = scanViewModel.fullMeshSnapshot()
        if !live.vertices.isEmpty {
            return session.headBoundingBox.map { live.cropped(to: $0) } ?? live
        }
        if let cached = cachedMeshSnapshot {
            return session.headBoundingBox.map { cached.cropped(to: $0) } ?? cached
        }
        if let loaded = artifactStore?.loadLiDARMeshSnapshot(for: session),
           !loaded.vertices.isEmpty {
            cachedMeshSnapshot = loaded
            return session.headBoundingBox.map { loaded.cropped(to: $0) } ?? loaded
        }
        return live
    }

    private var pendingSourceCloud: [SIMD3<Float>] = []
    private var pendingTargetCloud: [SIMD3<Float>] = []

    /// Whether "Reconstruct & Fuse" can run right now.
    var canReconstruct: Bool {
        reconstructionBlocker == nil
    }

    /// Human-readable reason reconstruction can't run yet, or nil when it can.
    var reconstructionBlocker: String? {
        if isReconstructing { return "Reconstruction in progress…" }
        if !isPhotogrammetrySupported { return "This device doesn't support on-device photogrammetry." }
        if session.captureObservations.isEmpty {
            return "Capture frames first: Start, then Sample Frame or Auto Sample."
        }
        return nil
    }

    /// Non-blocking advice shown when reconstruction can run but results may be poor.
    var reconstructionHint: String? {
        guard canReconstruct else { return nil }
        let frames = session.captureObservations.count
        if frames < 20 {
            return "Only \(frames) frames captured; aim for 20+ around the head for a good model."
        }
        return nil
    }

    /// Whether the current strategy/seed needs fiducials marked on the reconstructed model.
    var requiresSourceLandmarks: Bool {
        session.alignmentStrategy == .fiducial
            || session.alignmentStrategy == .depthAssisted
            || session.alignmentSeed.requiresSourceLandmarks
    }

    private let detectionPipeline: ElectrodeDetectionPipeline
    private let artifactStore: CaptureArtifactStore?
    private let sessionDefaults: UserDefaults
    private static let activeSessionKey = "MANTA.activeSessionID"
    private let meshSnapshotProvider: (() -> LiDARMeshSnapshot)?
    private static func hasWorldEvidence(_ session: ScanSession) -> Bool {
        !session.captureObservations.isEmpty || session.lidarMeshFilename != nil
            || session.headBoundingBox != nil || session.fiducials.contains { $0.coordinate != nil }
    }
    private let photogrammetryService: PhotogrammetryReconstructing
    private var autoSamplingTask: Task<Void, Never>?
    private var automaticStillTask: Task<Void, Never>?
    @Published private(set) var isDrainingCapture = false
    private var drainTask: Task<Void, Never>?
    private var captureWriteFailure: String?
    private var captureMetadataSessionID: UUID?
    private var observationsSinceMetadataFlush = 0
    private var lastMetadataFlush = ProcessInfo.processInfo.systemUptime

    private var liveDetectionTask: Task<Void, Never>?
    private var pendingLiveObservation: CaptureObservation?
    private var liveRawDetections: [LabeledDetection] = []
    private var liveProcessedFrameIDs: [UUID] = []
    private var liveDetectionStartedAt: Date?
    private var liveDetectionGeneration = UUID()
    private var liveOCRCandidateCount = 0

    /// Finalized results take precedence; provisional live-only labels and
    /// template predictions remain visible until finalization resolves them.
    var visualizedElectrodes: [ElectrodeAnnotation] {
        if scanViewModel.motionStopped { return [] }
        var byLabel = Dictionary(uniqueKeysWithValues: liveElectrodes.map { ($0.label, $0) })
        for electrode in session.electrodes {
            if scanViewModel.status.isRunning && electrode.provenance?.isDirectMeasurement != true { continue }
            byLabel[electrode.label] = electrode
        }
        return byLabel.values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    var liveDirectElectrodeCount: Int {
        liveElectrodes.filter { $0.confidence > 0 }.count
    }

    var finalizedDirectElectrodeCount: Int {
        session.electrodes.filter { $0.confidence > 0 }.count
    }

    var detectionComparisonMeanDistanceMM: Double? {
        let live = Dictionary(uniqueKeysWithValues: liveElectrodes
            .filter { $0.confidence > 0 }.map { ($0.label, $0.coordinate) })
        let distances = session.electrodes.compactMap { final -> Double? in
            guard final.confidence > 0, let provisional = live[final.label] else { return nil }
            let dx = final.coordinate.x - provisional.x
            let dy = final.coordinate.y - provisional.y
            let dz = final.coordinate.z - provisional.z
            return sqrt(dx * dx + dy * dy + dz * dz) * 1000
        }
        guard !distances.isEmpty else { return nil }
        return distances.reduce(0, +) / Double(distances.count)
    }

    var isPhotogrammetrySupported: Bool { photogrammetryService.isSupported }

    /// Filesystem URL of the reconstructed model, if one has been produced.
    var reconstructedModelURL: URL? {
        guard session.hasReconstructedModel, let artifactStore else { return nil }
        return artifactStore.reconstructionModelURL(for: session)
    }

    /// Records a fiducial placed on the reconstructed model (source frame).
    func setModelFiducial(_ kind: FiducialKind, at point: SIMD3<Float>) {
        guard let index = session.modelFiducials.firstIndex(where: { $0.kind == kind }) else { return }
        session.modelFiducials[index].coordinate = Coordinate3D(x: Double(point.x), y: Double(point.y), z: Double(point.z))
        session.modelFiducials[index].state = .reviewed
        appendFiducialEvidence(FiducialPlacementEvidence(
            kind: kind, source: "photogrammetry-model", hitMethod: "model-surface-pick",
            coordinateSystem: "photogrammetry-model",
            coordinate: Coordinate3D(x: Double(point.x), y: Double(point.y), z: Double(point.z))))
        persistSession()
    }

    init(
        detectionPipeline: ElectrodeDetectionPipeline? = nil,
        photogrammetryService: PhotogrammetryReconstructing? = nil,
        artifactStore: CaptureArtifactStore? = nil,
        sessionDefaults: UserDefaults = .standard,
        meshSnapshotProvider: (() -> LiDARMeshSnapshot)? = nil
    ) {
        self.detectionPipeline = detectionPipeline ?? ElectrodeDetectionFactory.makeDefaultPipeline()
        self.photogrammetryService = photogrammetryService ?? PhotogrammetryReconstructionService()
        self.artifactStore = artifactStore ?? (try? CaptureArtifactStore())
        self.sessionDefaults = sessionDefaults
        self.meshSnapshotProvider = meshSnapshotProvider

        do {
            let layouts = try HydroCelLayoutLoader().loadLayouts()
            availableLayouts = [.headMeshOnly] + layouts
            selectedLayoutName = ElectrodeLayout.headMeshOnly.name
            session = ScanSession.newSession(layout: .headMeshOnly)
            session.acquisitionContext = AcquisitionContext()
        } catch {
            availableLayouts = [.headMeshOnly, .fallback128]
            selectedLayoutName = ElectrodeLayout.headMeshOnly.name
            session = ScanSession.newSession(layout: .headMeshOnly)
            session.acquisitionContext = AcquisitionContext()
            statusMessage = "Net layouts unavailable; head-mesh capture is ready: \(error.localizedDescription)"
        }

        if let rawID = sessionDefaults.string(forKey: Self.activeSessionKey),
           let id = UUID(uuidString: rawID),
           let saved = try? self.artifactStore?.loadSession(id: id) {
            session = saved
            selectedLayoutName = saved.layout.name
            needsSessionName = false
            if saved.endedAt != nil {
                scanViewModel.lockEndedCapture()
            } else if Self.hasWorldEvidence(saved) {
                scanViewModel.lockArchivedCapture()
            }
            statusMessage = "Restored \(saved.displayName)."
        }
        refreshExportPreview()
        refreshSessions()
        scanViewModel.storageCapacityProvider = { [weak self] in self?.artifactStore?.availableCapacityBytes }
        scanViewModel.observationSavedHandler = { [weak self] id, result in
            self?.captureWriteCompleted(sessionID: id, result: result)
        }
        scanViewModel.eventHandler = { [weak self] event in
            self?.recordAcquisitionEvent(event)
            if event.kind == "subject-movement" { self?.handleSubjectMovement() }
            if event.kind == "capture-storage-state",
               let rawState = event.details["state"],
               let state = CaptureStoragePolicy.State(rawValue: rawState), !state.allowsCapture {
                self?.stopAutoSampling()
                self?.statusMessage = event.message
            }
        }
    }

    func markSubjectMoved() { scanViewModel.markSubjectMoved() }

    private func handleSubjectMovement() {
        var route = session.captureRoute ?? CaptureRouteProgress()
        route.flagMovement()
        session.captureRoute = route
        routeInspectionStep = nil
        session.acquisitionContext?.captureReview = nil
        if let artifactStore {
            do {
                let directory = artifactStore.acquisitionDirectory(for: session).appendingPathComponent("motion-stops")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(Date()).write(to: directory.appendingPathComponent("\(scanViewModel.motionSegmentID.uuidString).json"), options: .atomic)
            } catch { captureSaveError = "Could not persist movement flag: \(error.localizedDescription)" }
        }
        let stoppedSegmentID = scanViewModel.motionSegmentID
        for index in session.captureObservations.indices where session.captureObservations[index].quality?.motionAssessment?.segmentID == stoppedSegmentID {
            session.captureObservations[index].quality?.motionAssessment?.state = .suspected
        }
        _ = persistSession()

        resetLiveDetection()
        resetLiveMetricDepthFusion()
        cachedMeshSnapshot = nil
        fiducialPlacementKind = nil
        modelFiducialPlacementKind = nil
        releaseCheckMessages = ["Movement flagged: collect a separate stationary pass before release."]
        stopAutoSampling()
        isDrainingCapture = true
        let markedSessionID = session.id
        Task {
            await finishCaptureWrites()
            guard session.id == markedSessionID else { return }
            for index in session.captureObservations.indices {
                if var motion = session.captureObservations[index].quality?.motionAssessment, motion.segmentID == stoppedSegmentID {
                    motion.state = .suspected
                    session.captureObservations[index].quality?.motionAssessment = motion
                }
            }
            _ = persistSession()
            statusMessage = scanViewModel.motionMessage
        }
    }

    // MARK: - Subject library

    /// Reloads the list of persisted sessions, newest first.
    func refreshSessions() {
        sessionSummaries = artifactStore?.listSessionSummaries() ?? []
    }

    /// Only an explicit new-session action replaces the capture identity; labels are optional.
    @discardableResult
    func startNewSession(subjectLabel: String = "") -> Bool {
        guard !isEndingSession, !isDrainingCapture, !isExporting, !isCheckingRelease, !isReconstructing, !isDetecting else { return false }
        let label = subjectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stopAutoSampling() else { return false }
        releaseCheckMessages = []
        scanViewModel.resetForNewCapture()
        restoreCaptureView()
        resetLiveDetection()
        fiducialPlacementKind = nil
        modelFiducialPlacementKind = nil
        isHeadBoundsPlacementActive = false
        cachedMeshSnapshot = nil
        let layout = availableLayouts.first(where: { $0.name == selectedLayoutName }) ?? session.layout
        var newSession = ScanSession.newSession(layout: layout)
        newSession.subjectLabel = label.isEmpty ? nil : label
        newSession.name = newSession.displayName
        newSession.acquisitionContext = AcquisitionContext(
            netModel: layout.hasElectrodeNet ? layout.name : nil)
        session = newSession
        routeInspectionStep = nil
        captureWriteFailure = nil
        captureSaveError = nil
        needsSessionName = false
        resetLiveMetricDepthFusion()
        guard persistSession() else { return false }
        refreshSessions()
        statusMessage = "New session \(session.displayName)."
        refreshExportPreview()
        return true
    }

    /// Reopening the current session must not discard its still-live AR world.
    @discardableResult
    func openSession(id: UUID) -> Bool {
        guard !isEndingSession, !isDrainingCapture, !isExporting, !isCheckingRelease, !isReconstructing, !isDetecting else { return false }
        if id == session.id, !needsSessionName { return true }
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return false
        }
        guard stopAutoSampling() else { return false }
        do {
            let loaded = try artifactStore.loadSession(id: id)
            scanViewModel.resetForNewCapture()
            if loaded.endedAt != nil {
                scanViewModel.lockEndedCapture()
            } else if Self.hasWorldEvidence(loaded) {
                scanViewModel.lockArchivedCapture()
            }
            releaseCheckMessages = []
            resetLiveDetection()
            fiducialPlacementKind = nil
            modelFiducialPlacementKind = nil
            isHeadBoundsPlacementActive = false
            cachedMeshSnapshot = nil
            routeInspectionStep = nil
            session = loaded
            captureWriteFailure = nil
            captureSaveError = nil
            needsSessionName = false
            sessionDefaults.set(id.uuidString, forKey: Self.activeSessionKey)
            resetLiveMetricDepthFusion()
            selectedLayoutName = loaded.layout.name
            liveDetectionEnabled = loaded.layout.hasElectrodeNet
            statusMessage = "Opened \(loaded.displayName)."
            refreshExportPreview()
            return true
        } catch {
            statusMessage = "Could not open session: \(error.localizedDescription)"
            return false
        }
    }

    /// Renames the current subject; the capture timestamp is untouched.
    func renameSubject(_ label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.subjectLabel = (trimmed?.isEmpty ?? true) ? nil : trimmed
        session.name = session.displayName
        persistSession()
        refreshSessions()
        statusMessage = "Renamed to \(session.displayName)."
    }

    /// Renames any persisted session (or the current one) by id.
    func renameSession(id: UUID, label: String?) {
        if id == session.id {
            renameSubject(label)
            return
        }
        guard let artifactStore, var target = try? artifactStore.loadSession(id: id) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        target.subjectLabel = (trimmed?.isEmpty ?? true) ? nil : trimmed
        target.name = target.displayName
        _ = try? artifactStore.writeSession(target)
        refreshSessions()
    }

    func deleteSession(id: UUID) {
        guard !isEndingSession, !isDrainingCapture, !isExporting, !isCheckingRelease, !isReconstructing, !isDetecting else { return }
        guard let artifactStore else { return }
        do {
            if id == session.id {
                cancelAutoSampling()
                scanViewModel.invalidatePendingCaptures()
                if scanViewModel.pendingWriteCount > 0 {
                    stopAutoSampling()
                    statusMessage = "Finishing saved frames before deletion. Retry when saving completes."
                    return
                }
            }
            try artifactStore.deleteSession(id: id)
            if id == session.id {
                // Deletion intentionally discards this capture; do not checkpoint
                // it afterwards and accidentally recreate the deleted folder.
                scanViewModel.resetForNewCapture()
                restoreCaptureView()
                resetLiveDetection()
                cachedMeshSnapshot = nil
                fiducialPlacementKind = nil
                modelFiducialPlacementKind = nil
                isHeadBoundsPlacementActive = false
                session = ScanSession.newSession(layout: session.layout)
                needsSessionName = true
                sessionDefaults.removeObject(forKey: Self.activeSessionKey)
                resetLiveMetricDepthFusion()
                refreshExportPreview()
            }
            refreshSessions()
        } catch { statusMessage = "Could not delete session: \(error.localizedDescription)" }
    }

    /// Finalizes immutable acquisition and solved snapshots off the main actor.
    func exportSession(id: UUID) { beginSessionExport(id: id, rawOnly: false) }

    /// Preferred hand-off for later processing on the Mac.
    func exportRawSession(id: UUID) { beginSessionExport(id: id, rawOnly: true) }

    private func beginSessionExport(id: UUID, rawOnly: Bool) {
        guard !isExporting, !isEndingSession, !isCheckingRelease, !isDetecting, !isReconstructing else { return }
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }
        let runID = UUID()
        let startedAt = Date()
        activeExportID = runID
        isExporting = true // Lock switching/deletion before the first suspension.
        exportedBundle = nil
        exportProgress = 0
        exportStage = "Saving accepted capture work"
        exportStartedAt = startedAt
        if id == session.id {
            cancelAutoSampling()
            scanViewModel.invalidatePendingCaptures()
        }
        // Retain the owner until accepted writes/export cleanup finish; defer
        // clears the task reference on every exit, including cancellation.
        exportTask = Task { [self] in
            defer {
                activeExportID = nil
                isExporting = false
                exportProgress = 0
                exportStage = ""
                exportStartedAt = nil
                exportTask = nil
            }
            var outputDirectory: URL?
            do {
                if id == session.id {
                    await finishCaptureWrites()
                    guard captureSaveError == nil else {
                        statusMessage = "Export stopped: \(captureSaveError ?? "capture checkpoint could not be saved")"
                        return
                    }
                    recordAcquisitionEvent(.init(kind: "export-started", message: rawOnly
                        ? "Preparing raw acquisition for deferred solving." : "Preparing raw and solved snapshots."))
                }
                try Task.checkCancellation()
                let job = try artifactStore.prepareSessionExport(id: id, rawOnly: rawOnly)
                let result = try await job.execute { [weak self] fraction, stage in
                    guard let self, self.activeExportID == runID else { return }
                    self.exportProgress = fraction
                    self.exportStage = stage
                }
                outputDirectory = job.outputDirectory
                try Task.checkCancellation()
                // Publish only after bundle creation and lineage persistence succeed.
                var updated = id == session.id ? session : try artifactStore.loadSession(id: id)
                updated.lastRawExportedBundleID = result.exports[0].bundleID
                if !rawOnly { updated.lastExportedBundleID = result.exports[1].bundleID }
                try artifactStore.writeSession(updated)
                if id == session.id { session = updated }
                exportedBundle = ExportedBundle(urls: result.exports.map(\.url))
                let elapsed = Date().timeIntervalSince(startedAt)
                statusMessage = String(format: "%@ ready in %.1f s · receipt %@.",
                    rawOnly ? "Raw acquisition" : "Raw and solved snapshots", elapsed, result.receipt.status.rawValue)
                if id == session.id {
                    recordAcquisitionEvent(.init(kind: "export-completed", message: "Immutable capture snapshots are ready.",
                        details: ["bundleIDs": result.exports.map { $0.bundleID.uuidString }.joined(separator: ","),
                                  "durationSeconds": String(format: "%.3f", elapsed)]))
                }
            } catch {
                if let outputDirectory {
                    await Task.detached { try? FileManager().removeItem(at: outputDirectory) }.value
                }
                statusMessage = error is CancellationError ? "Export cancelled. Original capture preserved."
                    : "Export failed: \(error.localizedDescription)"
                if id == session.id {
                    recordAcquisitionEvent(.init(kind: "export-failed", message: statusMessage))
                }
            }
        }
    }

    /// Writes the current session to disk. Called after meaningful mutations.
    @discardableResult
    private func persistSession() -> Bool {
        guard let artifactStore else {
            captureSaveError = "Could not access the app Documents folder."
            return false
        }
        do {
            try artifactStore.writeSession(session)
            if !needsSessionName {
                sessionDefaults.set(session.id.uuidString, forKey: Self.activeSessionKey)
            }
            return true
        } catch {
            captureSaveError = "Could not save session: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func saveCaptureCheckpoint() -> Bool {
        guard !needsSessionName else { return true }
        guard scanViewModel.pendingWriteCount == 0 else { return false }
        guard persistCurrentLiDARMesh(), flushCaptureMetadata() else { return false }
        captureSaveError = captureWriteFailure
        refreshSessions()
        return true
    }

    func updateAcquisitionContext(_ update: (inout AcquisitionContext) -> Void) {
        releaseCheckMessages = []
        var context = session.acquisitionContext ?? AcquisitionContext(
            netModel: session.layout.hasElectrodeNet ? session.layout.name : nil)
        update(&context)
        session.acquisitionContext = context
        persistSession()
        _ = try? artifactStore?.writeAcquisitionContext(for: session)
    }

    func recordAppLifecycle(_ state: String) {
        if state == "background" {
            #if canImport(UIKit)
            beginCaptureBackgroundDrain()
            #endif
            stopAutoSampling()
        }
        guard scanViewModel.status.isRunning || !session.captureObservations.isEmpty else { return }
        recordAcquisitionEvent(AcquisitionEvent(
            kind: "app-lifecycle", message: state))
    }

    #if canImport(UIKit)
    private var captureBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private func beginCaptureBackgroundDrain() {
        guard scanViewModel.pendingWriteCount > 0, captureBackgroundTask == .invalid else { return }
        captureBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish capture writes") { [weak self] in
            Task { @MainActor in self?.endCaptureBackgroundDrain() }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.finishCaptureWrites()
            self.endCaptureBackgroundDrain()
        }
    }
    private func endCaptureBackgroundDrain() {
        guard captureBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(captureBackgroundTask)
        captureBackgroundTask = .invalid
    }
    #endif

    private func recordAcquisitionEvent(_ event: AcquisitionEvent) {
        guard let artifactStore else { return }
        var enriched = event
        enriched.details["captureMode"] = session.captureMode.rawValue
        enriched.details["sampleCount"] = String(session.captureObservations.count)
        enriched.details["tracking"] = scanViewModel.status.trackingSummary
        if let bytes = artifactStore.availableCapacityBytes {
            enriched.details["availableStorageBytes"] = String(bytes)
        }
        enriched.details["thermalState"] = String(ProcessInfo.processInfo.thermalState.rawValue)
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        enriched.details["batteryLevel"] = String(UIDevice.current.batteryLevel)
        enriched.details["batteryState"] = String(UIDevice.current.batteryState.rawValue)
        #endif
        _ = try? artifactStore.appendAcquisitionEvent(enriched, for: session)
    }

    func finalizeElectrodeDetection() async {
        do { try CaptureMotionPolicy.requireStationary(session.captureObservations.map(\.quality)) }
        catch { statusMessage = error.localizedDescription; return }
        guard !scanViewModel.motionStopped else { statusMessage = scanViewModel.motionMessage; return }

        await finishCaptureWrites()
        guard captureSaveError == nil else { return }
        guard session.layout.hasElectrodeNet else {
            statusMessage = "Select an electrode net before running electrode detection."
            return
        }
        isDetecting = true
        statusMessage = "Finalizing electrode detection across all captured frames..."
        let startedAt = Date()

        let context = DetectionContext(
            layout: session.layout,
            observations: session.captureObservations,
            frameProvider: makeFrameProvider()
        )

        do {
            session.electrodes = try await detectionPipeline.detectElectrodes(in: context)
            if session.electrodes.isEmpty {
                statusMessage = session.captureObservations.isEmpty
                    ? "No captured frames yet. Start a scan and sample frames, then detect."
                    : "No electrode labels were read. Capture more, closer, sharper frames and retry."
            } else {
                statusMessage = "Finalized \(session.detectedElectrodeCount) electrodes. Review labels and landmarks next."
            }
            writeFinalDetectionDiagnostics(startedAt: startedAt)
        } catch {
            statusMessage = "Detection failed: \(error.localizedDescription)"
        }

        isDetecting = false
        refreshExportPreview()
        persistSession()
        refreshSessions()
    }

    func setLiveDetectionEnabled(_ enabled: Bool) {
        liveDetectionEnabled = enabled && session.layout.hasElectrodeNet
        if liveDetectionEnabled {
            liveDetectionStatus = "Waiting for the next saved frame."
        } else {
            pendingLiveObservation = nil
            liveDetectionGeneration = UUID()
            liveDetectionTask?.cancel()
            liveDetectionTask = nil
            isLiveDetecting = false
            liveDetectionStatus = "Live detection is off."
        }
    }

    /// Frame source for detection: artifact-backed on device, empty otherwise.
    private func makeFrameProvider() -> DetectionFrameProvider {
        #if canImport(ImageIO) && canImport(Compression)
        if let artifactStore {
            return CaptureArtifactFrameProvider(store: artifactStore, session: session)
        }
        #endif
        return EmptyDetectionFrameProvider()
    }

    func toggleReviewed(_ electrode: ElectrodeAnnotation) {
        guard let index = session.electrodes.firstIndex(where: { $0.id == electrode.id }) else {
            return
        }

        session.electrodes[index].state = session.electrodes[index].state == .reviewed ? .detected : .reviewed
        refreshExportPreview()
        persistSession()
    }

    func updateFormat(_ format: ElectrodeExportFormat) {
        selectedFormat = format
        refreshExportPreview()
    }

    func selectLayout(named name: String) {
        guard scanViewModel.pendingWriteCount == 0, !isDrainingCapture else { return }
        guard !isSessionEnded, !isEndingSession else { return }
        guard let layout = availableLayouts.first(where: { $0.name == name }) else {
            return
        }

        guard layout != session.layout else { return }
        // A net change is a setting, never an implicit new subject/capture.
        // Once evidence exists, require an explicit new session for a new net.
        guard session.captureObservations.isEmpty, session.lidarMeshFilename == nil,
              session.electrodes.isEmpty else {
            statusMessage = "Start a new session to change the net after capture."
            return
        }
        resetLiveDetection()
        selectedLayoutName = name
        session.layout = layout
        var context = session.acquisitionContext ?? AcquisitionContext()
        context.netModel = layout.hasElectrodeNet ? layout.name : nil
        session.acquisitionContext = context
        liveDetectionEnabled = layout.hasElectrodeNet
        if !needsSessionName { persistSession() }
        statusMessage = layout.hasElectrodeNet
            ? "Ready to scan with \(layout.name)."
            : "Ready for head-mesh capture without an electrode net."
        refreshExportPreview()
    }

    func startLiveScan() {
        guard canAcquire else { return }
        captureWriteFailure = nil
        captureSaveError = nil
        guard ensureCaptureMetadata() else { return }
        scanViewModel.start(captureMode: session.captureMode)
        guard scanViewModel.status.isRunning else {
            statusMessage = scanViewModel.status.message
            return
        }
        restoreCaptureView()
        recordAcquisitionEvent(AcquisitionEvent(
            kind: "capture-started", message: "AR capture started.",
            details: ["autoSamplingIntervalSeconds": String(autoSamplingInterval)]))
        if requestHeadRegionOnScanStart, session.headBoundingBox == nil,
           session.captureMode.usesLiDAR {
            fiducialPlacementKind = nil
            isHeadBoundsPlacementActive = true
            statusMessage = "Scan started. Tap the center of the visible head to set the capture region."
        } else {
            statusMessage = "Live \(session.captureMode.rawValue) scan running."
        }
    }

    func applyCapturePreset(_ preset: CapturePreset) {
        guard scanViewModel.canEditCaptureSettings, session.captureObservations.isEmpty else { return }
        session.captureMode = .both
        scanViewModel.adaptiveSampling = false
        scanViewModel.selectBestFrames = preset.selectsBestFrames
        scanViewModel.preserveComparisonFrames = preset.savesComparisonFrames
        scanViewModel.highResolutionStills = preset.capturesHighResolutionStills
        scanViewModel.automaticHighResolutionStills = preset.capturesHighResolutionStills
        if !needsSessionName { persistSession() }
        statusMessage = "\(preset.rawValue) selected for the next capture."
    }

    func setCaptureMode(_ mode: CaptureMode) {
        guard scanViewModel.canEditCaptureSettings, session.captureObservations.isEmpty else { return }
        session.captureMode = mode
        if !needsSessionName { persistSession() }
        statusMessage = "Capture mode set to \(mode.rawValue)."
    }

    func runReconstruction() async {
        do { try CaptureMotionPolicy.requireStationary(session.captureObservations.map(\.quality)) }
        catch { statusMessage = error.localizedDescription; return }
        guard !scanViewModel.motionStopped else { statusMessage = scanViewModel.motionMessage; return }

        await finishCaptureWrites()
        guard captureSaveError == nil else { return }
        guard session.captureMode.usesPhotogrammetry else {
            statusMessage = "Switch to Photogrammetry or Both to reconstruct a model."
            return
        }

        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }

        guard photogrammetryService.isSupported else {
            statusMessage = "On-device photogrammetry is not supported on this device."
            return
        }

        guard !session.captureObservations.isEmpty else {
            statusMessage = "Capture some frames before reconstructing."
            return
        }

        isReconstructing = true
        reconstructionProgress = 0
        statusMessage = "Preparing captured frames for reconstruction..."

        do {
            let prepared = try artifactStore.prepareReconstructionInput(for: session)
            let outputURL = artifactStore.reconstructionModelURL(for: session)
            try? FileManager.default.removeItem(at: outputURL)

            statusMessage = "Reconstructing model from \(prepared.manifest.poses.count) frames..."

            let result = try await photogrammetryService.reconstruct(
                imagesDirectory: prepared.imagesDirectory,
                outputModelURL: outputURL,
                manifest: prepared.manifest
            ) { [weak self] fraction in
                guard let self else { return }
                Task { @MainActor in self.reconstructionProgress = fraction }
            }

            session.photogrammetryModelFilename = artifactStore.reconstructionModelRelativePath
            var reconstructionDiagnostics = result.diagnostics
            reconstructionDiagnostics.producer = solverProducerMetadata()
            reconstructionDiagnostics.parameters = [
                "inputFrameCount": String(prepared.manifest.poses.count)
            ]
            _ = try artifactStore.writeReconstructionDiagnostics(reconstructionDiagnostics, for: session)

            // Snapshot the accumulated LiDAR mesh for ICP and persist it alongside the model.
            let meshCloud = scanViewModel.meshWorldPoints()
            persistCurrentLiDARMesh()

            // Load the reconstructed model's vertices (ICP source) off the main actor.
            let sourceCloud = await Task.detached { ModelPointCloudLoader.load(url: outputURL) }.value

            pendingTargetCloud = meshCloud
            pendingSourceCloud = sourceCloud
            statusMessage = "Reconstruction complete. Computing alignment..."
            computeAlignment()
        } catch {
            statusMessage = "Reconstruction failed: \(error.localizedDescription)"
        }

        isReconstructing = false
        reconstructionProgress = nil
        refreshExportPreview()
    }

    /// Registers the reconstructed model into the ARKit world using the selected strategy/seed.
    /// If the choice needs model-frame fiducials and none are placed, this prompts for them
    /// unless `allowPrompt` is false (the "skip / fall back" path).
    func computeAlignment(allowPrompt: Bool = true) {
        guard session.hasReconstructedModel else { return }

        if allowPrompt, requiresSourceLandmarks, !session.modelFiducialsReady {
            promptForModelFiducials = true
            statusMessage = "Mark the fiducials on the reconstructed model to continue."
            return
        }

        promptForModelFiducials = false
        let input = gatherAlignmentInput(targetCloud: pendingTargetCloud, sourceCloud: pendingSourceCloud)
        let alignment = WorldAlignmentSolver.solve(strategy: session.alignmentStrategy, input: input)
        session.worldAlignmentTransform = alignment.transform.flattenedColumns

        if alignment.rmsError.isFinite {
            statusMessage = String(
                format: "%@ · %@ seed · RMS %.2f mm.",
                session.alignmentStrategy.rawValue,
                session.alignmentSeed.rawValue,
                alignment.rmsError * 1000
            )
        } else {
            statusMessage = "Alignment needs landmark/mesh geometry for \(session.alignmentStrategy.rawValue)."
        }
        refreshExportPreview()
        persistSession()
        refreshSessions()
    }

    /// Called when the user finishes (or skips) marking model fiducials.
    func finishModelFiducials(skipped: Bool) {
        promptForModelFiducials = false
        computeAlignment(allowPrompt: !skipped)
    }

    // MARK: - Fiducial placement (live scan)

    /// Arms placement of a fiducial; the next tap on the live scan sets it. Tap
    /// the same control again to disarm.
    func armFiducialPlacement(_ kind: FiducialKind) {
        if fiducialPlacementKind == kind {
            fiducialPlacementKind = nil
            statusMessage = "Fiducial placement cancelled."
        } else {
            fiducialPlacementKind = kind
            statusMessage = "Tap \(kind.rawValue) on the scan to place it."
        }
    }

    /// Enters a guided Nasion -> LPA -> RPA workflow. Frame sampling stops so
    /// the operator can concentrate on a stable raycast, while AR/LiDAR stays live.
    func startGuidedFiducialPlacement() {
        guard scanViewModel.status.isRunning else {
            statusMessage = "Start the scan before marking fiducials."
            return
        }
        stopAutoSampling()
        isHeadBoundsPlacementActive = false
        fiducialPlacementKind = firstUnplacedFiducialKind() ?? FiducialKind.cardinal.first
        statusMessage = fiducialPlacementPrompt ?? "Mark the live fiducials."
    }

    func cancelGuidedFiducialPlacement() {
        fiducialPlacementKind = nil
        statusMessage = "Fiducial placement cancelled. AR tracking is still running."
    }

    /// Handles a tap on the live AR view while a fiducial is armed: ray-casts to
    /// the scanned surface and stores the world-frame landmark.
    func handleScanTap(viewPoint: CGPoint) {
        if isHeadBoundsPlacementActive {
            guard let result = scanViewModel.raycastToWorld(viewPoint: viewPoint) else {
                statusMessage = "Couldn't hit the head surface there — aim at the head and retry."
                return
            }
            let direction = result.rayDirection.map(simd_normalize) ?? SIMD3<Float>(0, 0, 0)
            let center = result.point + direction * 0.10
            let bounds = HeadBoundingBox(center: Coordinate3D(
                x: Double(center.x), y: Double(center.y), z: Double(center.z)))
            session.headBoundingBox = bounds
            invalidateHeadRegionReview()
            isHeadBoundsPlacementActive = false
            resetLiveMetricDepthFusion()
            persistSession()
            recordAcquisitionEvent(AcquisitionEvent(
                kind: "head-region-set", message: "Head-centered LiDAR boundary defined.",
                details: [
                    "centerX": String(bounds.center.x),
                    "centerY": String(bounds.center.y),
                    "centerZ": String(bounds.center.z),
                    "widthMeters": String(bounds.widthMeters),
                    "heightMeters": String(bounds.heightMeters),
                    "depthMeters": String(bounds.depthMeters),
                    "hitMethod": result.hitMethod
                ]))
            statusMessage = "Head region set. The live model now hides surrounding geometry."
            return
        }
        guard let kind = fiducialPlacementKind else { return }
        guard let result = scanViewModel.raycastToWorld(viewPoint: viewPoint) else {
            statusMessage = "Couldn't hit the surface there — aim at the head and retry."
            return
        }

        var evidenceObservationID = result.observationID
        if let artifactStore, canAcquire, ensureCaptureMetadata() {
            do {
                if let evidence = try scanViewModel.sampleCurrentFrame(
                    artifactStore: artifactStore, session: session,
                    includeCompressedImage: captureCompressedImageReferences
                ) {
                    evidenceObservationID = evidence.id
                }
            } catch {
                recordAcquisitionEvent(AcquisitionEvent(
                    kind: "fiducial-evidence-save-failed", message: error.localizedDescription))
            }
        }

        recordFiducial(
            kind, world: result.point, source: "live-camera", hitMethod: result.hitMethod,
            observationID: evidenceObservationID, imagePoint: viewPoint,
            rayOrigin: result.rayOrigin, rayDirection: result.rayDirection)
        let placed = session.fiducials.filter { $0.coordinate != nil }.count
        if let next = firstUnplacedFiducialKind() {
            fiducialPlacementKind = next
            statusMessage = "Placed \(kind.rawValue) (\(placed)/3). \(fiducialPlacementPrompt ?? "")"
        } else {
            fiducialPlacementKind = nil
            if session.headBoundingBox == nil, let center = fiducialCentroid {
                session.headBoundingBox = HeadBoundingBox(center: center)
            }
            let warnings = fiducialPlausibilityWarnings
            if warnings.isEmpty {
                statusMessage = "All fiducials placed — geometry checks passed."
            } else {
                statusMessage = "Fiducials need review: \(warnings.joined(separator: "; "))."
                recordAcquisitionEvent(AcquisitionEvent(
                    kind: "fiducial-plausibility-warning",
                    message: warnings.joined(separator: "; ")))
            }
        }
        persistSession()
    }

    func startHeadBoundsPlacement() {
        guard scanViewModel.status.isRunning else {
            statusMessage = "Start the scan before setting the head region."
            return
        }
        stopAutoSampling()
        fiducialPlacementKind = nil
        isHeadBoundsPlacementActive = true
        statusMessage = scanPlacementPrompt ?? "Tap the head center."
    }

    func clearHeadBoundingBox() {
        isHeadBoundsPlacementActive = false
        session.headBoundingBox = nil
        invalidateHeadRegionReview()
        resetLiveMetricDepthFusion()
        persistSession()
        statusMessage = "Showing the full ARKit environment mesh."
    }

    func updateHeadBoundingBox(_ update: (inout HeadBoundingBox) -> Void) {
        guard var bounds = session.headBoundingBox else { return }
        update(&bounds)
        guard bounds != session.headBoundingBox else { return }
        session.headBoundingBox = bounds
        invalidateHeadRegionReview()
        resetLiveMetricDepthFusion()
        persistSession()
    }

    // MARK: - Fiducial placement (offline, on the 3D head model)

    /// Enters the cameras-off placement flow. Intersects the displayed LiDAR mesh,
    /// so it works while the session is paused (patient on a break) or reopened.
    func beginModelSurfacePlacement() {
        guard !displayMeshSnapshot().vertices.isEmpty
                || !liveMetricDepthPointCloud.points.isEmpty else {
            statusMessage = "No head surface yet — scan first, then mark fiducials on the model."
            return
        }
        stopAutoSampling()
        fiducialPlacementKind = nil
        modelFiducialPlacementKind = firstUnplacedFiducialKind() ?? FiducialKind.cardinal.first
        statusMessage = modelFiducialPlacementPrompt ?? "Mark the fiducials on the head model."
    }

    func cancelModelSurfacePlacement() {
        modelFiducialPlacementKind = nil
        statusMessage = "Model fiducial placement cancelled."
    }

    /// Handles a tap on the 3D head model: a world-space ray from the model view's
    /// virtual camera, matched to fused depth before falling back to the LiDAR mesh.
    func handleModelSurfaceRay(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        guard let kind = modelFiducialPlacementKind else { return }
        let mesh = displayMeshSnapshot()
        let depthHit = liveMetricDepthPointCloud.nearestPoint(
            toRayOrigin: origin, direction: direction,
            maximumPerpendicularDistance: 0.010)
        let meshHit = MeshRaycaster.firstHit(
            origin: origin, direction: direction,
            vertices: mesh.vertices, triangleIndices: mesh.triangleIndices)
        guard let world = depthHit ?? meshHit else {
            statusMessage = "Tap directly on the head surface to place the \(kind.rawValue)."
            return
        }

        recordFiducial(
            kind, world: world,
            source: depthHit == nil ? "offline-lidar-model" : "offline-fused-depth-model",
            hitMethod: depthHit == nil ? "lidar-mesh-raycast" : "fused-depth-ray-proximity",
            rayOrigin: origin, rayDirection: direction)
        let placed = session.fiducials.filter { $0.coordinate != nil }.count
        if let next = firstUnplacedFiducialKind() {
            modelFiducialPlacementKind = next
            statusMessage = "Placed \(kind.rawValue) (\(placed)/3). \(modelFiducialPlacementPrompt ?? "")"
        } else {
            modelFiducialPlacementKind = nil
            statusMessage = "All fiducials placed on the model — exports now use the head coordinate frame."
        }
    }

    /// Writes a placed fiducial in the ARKit world frame. Shared by the live and
    /// model-surface placement paths so both produce identical, comparable landmarks.
    private func recordFiducial(
        _ kind: FiducialKind, world: SIMD3<Float>, source: String, hitMethod: String,
        observationID: UUID? = nil, imagePoint: CGPoint? = nil,
        rayOrigin: SIMD3<Float>? = nil, rayDirection: SIMD3<Float>? = nil
    ) {
        let coordinate = Coordinate3D(x: Double(world.x), y: Double(world.y), z: Double(world.z))
        if let index = session.fiducials.firstIndex(where: { $0.kind == kind }) {
            session.fiducials[index].coordinate = coordinate
            session.fiducials[index].state = .reviewed
        }
        appendFiducialEvidence(FiducialPlacementEvidence(
            kind: kind, source: source, hitMethod: hitMethod,
            coordinateSystem: "arkit-world", coordinate: coordinate,
            observationID: observationID,
            imagePoint: imagePoint.map { Coordinate2D(x: Double($0.x), y: Double($0.y)) },
            pointCoordinateSpace: imagePoint == nil ? nil : "ar-view-points",
            rayOrigin: rayOrigin.map { Coordinate3D(x: Double($0.x), y: Double($0.y), z: Double($0.z)) },
            rayDirection: rayDirection.map { Coordinate3D(x: Double($0.x), y: Double($0.y), z: Double($0.z)) }))
        persistSession()
        _ = try? artifactStore?.writeFiducialPlacementEvidence(for: session)
        refreshExportPreview()
    }

    private func appendFiducialEvidence(_ evidence: FiducialPlacementEvidence) {
        var placements = session.fiducialPlacementEvidence ?? []
        placements.append(evidence)
        session.fiducialPlacementEvidence = placements
        recordAcquisitionEvent(AcquisitionEvent(
            kind: "fiducial-placed", message: evidence.kind.rawValue,
            details: ["source": evidence.source, "hitMethod": evidence.hitMethod]))
    }

    /// First fiducial kind that still has no coordinate, in canonical order.
    /// Both placement flows resume here, so landmarks can be split freely between
    /// the live camera and the 3D model without redoing already-placed ones.
    private func firstUnplacedFiducialKind() -> FiducialKind? {
        let placed = Dictionary(uniqueKeysWithValues: session.fiducials.map { ($0.kind, $0.coordinate != nil) })
        return FiducialKind.cardinal.first { placed[$0] != true }
    }

    func pauseLiveScan() {
        cancelAutoSampling()
        fiducialPlacementKind = nil
        isHeadBoundsPlacementActive = false
        scanViewModel.pause()
        stopAutoSampling()
        if captureViewBeforePause == nil { captureViewBeforePause = captureVisualMode }
        captureVisualMode = .model
        let issues = captureReadinessIssues
        recordAcquisitionEvent(AcquisitionEvent(
            kind: "capture-paused", message: "AR capture paused.",
            details: ["readinessIssues": issues.joined(separator: " | ")]))
        statusMessage = issues.isEmpty
            ? "Capture paused. Inspect the saved head surface; frame and view counts do not establish completeness."
            : "Capture paused · \(issues.count) advisory issue(s): \(issues.prefix(2).joined(separator: "; "))."
    }

    /// Ends acquisition only after the surface and completion marker are saved.
    /// Receipt findings are advisory: ending does not assert sufficient coverage
    /// or accuracy, and does not automatically export or reconstruct the capture.
    func endSession() async {
        guard canEndSession, let artifactStore else { return }
        isEndingSession = true
        defer { isEndingSession = false }
        cancelAutoSampling()
        scanViewModel.pause()
        fiducialPlacementKind = nil
        modelFiducialPlacementKind = nil
        isHeadBoundsPlacementActive = false
        await finishCaptureWrites()
        guard captureSaveError == nil, saveCaptureCheckpoint() else { return }
        captureVisualMode = .model
        let capturedSession = session
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try artifactStore.writeCaptureReceipt(for: capturedSession)
            }.value
            // Switching/deletion are disabled while the receipt is being written.
            guard session.id == capturedSession.id else { return }
            let findings = result.receipt.checks.filter { $0.status != .passed }.map(\.message)
            releaseCheckMessages = ["File validation: \(result.receipt.status.rawValue)"] + findings
            session.endedAt = Date()
            guard persistSession() else {
                session.endedAt = nil
                return
            }
            scanViewModel.lockEndedCapture()
            refreshSessions()
            recordAcquisitionEvent(AcquisitionEvent(
                kind: "session-ended", message: "Acquisition saved and ended by the operator.",
                details: ["receiptStatus": result.receipt.status.rawValue,
                          "endedAt": session.endedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""]))
            statusMessage = "Session saved and ended. Review or export it, or start a new session."
            sessionEndSummary = findings.isEmpty
                ? "The surface and capture are saved. This session is ready for review and export. Start a new session to collect more data."
                : "The surface and capture are saved, and acquisition has ended. File checks need attention:\n\n"
                    + findings.prefix(5).joined(separator: "\n")
                    + "\n\nAll findings are available in the capture receipt. Review them before releasing the participant."
        } catch {
            captureSaveError = "Could not finish saving the session: \(error.localizedDescription). The session remains paused; retry Save and End Session."
        }
    }

    var captureCoverageSectorCount: Int { geometryReview.viewSectorCount ?? 0 }

    private var fiducialCentroid: Coordinate3D? {
        let coordinates = session.fiducials.compactMap(\.coordinate)
        guard coordinates.count == 3 else { return nil }
        return Coordinate3D(
            x: coordinates.map(\.x).reduce(0, +) / 3,
            y: coordinates.map(\.y).reduce(0, +) / 3,
            z: coordinates.map(\.z).reduce(0, +) / 3)
    }

    var captureReadinessIssues: [String] {
        let review = geometryReview
        var issues = [String]()
        if review.observationCount == 0 { issues.append("no saved frames") }
        if !review.headRegionSet { issues.append("head region is not set; view coverage is unknown") }
        if session.captureMode.usesLiDAR {
            if review.depthFrameCount == 0 { issues.append("no recorded metric depth") }
            if review.confidenceFrameCount < review.depthFrameCount { issues.append("some depth frames lack recorded confidence") }
            if !review.headMeshRecorded { issues.append("no saved head crop; inspect the surface") }
        }
        if review.blurWarningCount > 0 { issues.append("blur warnings on \(review.blurWarningCount) frames") }
        if review.unknownSharpnessCount > 0 { issues.append("sharpness unknown on \(review.unknownSharpnessCount) frames") }
        if review.motionUnknownCount > 0 { issues.append("motion unknown/insufficient on \(review.motionUnknownCount) frames") }
        if scanViewModel.motionStopped || review.motionSuspectCount > 0 { issues.append("movement flagged; save this pass and continue in the same session") }
        if session.layout.hasElectrodeNet, !session.fiducialsReady { issues.append("fiducials are incomplete") }
        issues.append(contentsOf: fiducialPlausibilityWarnings)
        return issues
    }

    var fiducialPlausibilityWarnings: [String] {
        guard let nasion = session.fiducials.first(where: { $0.kind == .nasion })?.coordinate,
              let left = session.fiducials.first(where: { $0.kind == .leftPreauricular })?.coordinate,
              let right = session.fiducials.first(where: { $0.kind == .rightPreauricular })?.coordinate
        else { return [] }
        func distance(_ a: Coordinate3D, _ b: Coordinate3D) -> Double {
            sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2))
        }
        let earSpan = distance(left, right)
        let leftNasion = distance(nasion, left)
        let rightNasion = distance(nasion, right)
        var warnings = [String]()
        if !(0.10...0.24).contains(earSpan) {
            warnings.append(String(format: "implausible LPA–RPA distance (%.0f mm)", earSpan * 1000))
        }
        if !(0.10...0.27).contains(leftNasion) {
            warnings.append(String(format: "implausible nasion–LPA distance (%.0f mm)", leftNasion * 1000))
        }
        if !(0.10...0.27).contains(rightNasion) {
            warnings.append(String(format: "implausible nasion–RPA distance (%.0f mm)", rightNasion * 1000))
        }
        if abs(leftNasion - rightNasion) > 0.06 {
            warnings.append(String(
                format: "left/right nasion distances differ by %.0f mm",
                abs(leftNasion - rightNasion) * 1000))
        }
        return warnings
    }

    var capturePreflightIssues: [String] {
        var issues = [String]()
        if !scanViewModel.status.isSupported { issues.append("AR tracking unsupported") }
        if scanViewModel.status.isRunning,
           scanViewModel.status.trackingSummary != "Normal" {
            issues.append("tracking is not normal")
        }
        if session.captureMode.usesLiDAR, scanViewModel.status.isRunning,
           !scanViewModel.status.hasSceneDepth {
            issues.append("scene depth is unavailable")
        }
        if let bytes = artifactStore?.availableCapacityBytes, bytes < CaptureStoragePolicy.warningBytes {
            issues.append("less than 3 GB free storage")
        }
        return issues
    }

    private func sampleStatus(_ observation: CaptureObservation) -> String {
        let warnings = observation.quality?.warnings ?? []
        let base = "Auto-saved sample \(session.captureObservations.count) · view coverage \(viewCoverageText)."
        return warnings.isEmpty ? base : "\(base) Advisory: \(warnings.joined(separator: ", "))."
    }

    @discardableResult
    private func persistCurrentLiDARMesh() -> Bool {
        guard !isSessionEnded else { return true }
        guard session.captureMode.usesLiDAR else { return true }
        guard let artifactStore else {
            captureSaveError = "Could not access the app Documents folder."
            return false
        }
        let liveSnapshot = meshSnapshotProvider?() ?? scanViewModel.fullMeshSnapshot()
        let hasLiveMesh = !liveSnapshot.vertices.isEmpty && !liveSnapshot.triangleIndices.isEmpty
        do {
            if hasLiveMesh {
                // Update the reference only after the atomic write succeeds.
                let filename = try artifactStore.writeLiDARMeshSnapshot(liveSnapshot, for: session)
                session.lidarMeshFilename = filename
                cachedMeshSnapshot = liveSnapshot
            }
            guard let source = hasLiveMesh
                    ? liveSnapshot
                    : cachedMeshSnapshot ?? artifactStore.loadLiDARMeshSnapshot(for: session),
                  !source.vertices.isEmpty, !source.triangleIndices.isEmpty else { return true }
            var cropFilename: String?
            if let bounds = session.headBoundingBox {
                let cropped = source.cropped(to: bounds)
                if !cropped.vertices.isEmpty, !cropped.triangleIndices.isEmpty {
                    cropFilename = try artifactStore.writeLiDARMeshSnapshot(
                        cropped, for: session, filename: "lidar_mesh_head.ply")
                }
            }
            session.headCroppedLidarMeshFilename = cropFilename
            return true
        } catch {
            captureSaveError = "Could not save head surface: \(error.localizedDescription). Keep this session open and retry."
            return false
        }
    }

    func startAutoSampling() {
        guard canAcquire, ensureCaptureMetadata() else { return }
        captureWriteFailure = nil
        captureSaveError = nil
        guard artifactStore != nil else {
            statusMessage = "Could not access the app Documents folder."
            return
        }

        guard scanViewModel.status.isSupported else {
            statusMessage = scanViewModel.status.message
            return
        }

        if !scanViewModel.status.isRunning {
            scanViewModel.start(captureMode: session.captureMode)
        }

        guard scanViewModel.status.isRunning else {
            statusMessage = scanViewModel.status.message
            return
        }
        restoreCaptureView()
        autoSamplingTask?.cancel()
        isAutoSampling = true
        recordAcquisitionEvent(AcquisitionEvent(
            kind: "auto-sampling-started", message: "Automatic sampling started.",
            details: ["intervalSeconds": String(autoSamplingInterval)]))
        let preflight = capturePreflightIssues
        statusMessage = preflight.isEmpty
            ? "Auto-sampling started."
            : "Auto-sampling started with advisory: \(preflight.joined(separator: "; "))."

        automaticStillTask?.cancel()
        automaticStillTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isAutoSampling, self.scanViewModel.status.isRunning else { return }
                if self.scanViewModel.highResolutionStills,
                   self.scanViewModel.automaticHighResolutionStills,
                   self.scanViewModel.status.trackingSummary == "Normal",
                   Date().timeIntervalSince(self.lastStillRequest) >= 5,
                   self.scanViewModel.automaticStillReady {
                    await self.captureHighResolutionStill(automatic: true)
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }

        autoSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                guard self.scanViewModel.status.isRunning else {
                    self.stopAutoSampling()
                    return
                }
                if self.canAutoSample {
                    self.sampleCurrentARFrame(useBestFrame: true)
                } else if self.scanViewModel.status.isRunning {
                    self.statusMessage = "Auto-sampling waiting for normal tracking and depth."
                }

                let nanoseconds = UInt64(max(0.25, self.autoSamplingInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    @discardableResult
    func stopAutoSampling() -> Bool {
        cancelAutoSampling()
        scanViewModel.invalidatePendingCaptures()
        if scanViewModel.pendingWriteCount > 0 || isDrainingCapture {
            if drainTask == nil {
                isDrainingCapture = true
                drainTask = Task { [weak self] in
                    guard let self else { return }
                    await self.scanViewModel.drainWrites()
                    let saved = self.saveCaptureCheckpoint()
                    self.isDrainingCapture = false
                    self.drainTask = nil
                    if saved && self.captureWriteFailure == nil { self.statusMessage = "Queued frames saved. Automatic sampling stopped." }
                }
            }
            statusMessage = "Finishing queued capture writes…"
            return false
        }
        let saved = saveCaptureCheckpoint()
        if saved, !needsSessionName {
            statusMessage = scanViewModel.status.isRunning
                ? "Capture saved. Automatic sampling stopped; tracking remains active."
                : "Capture saved. Scanning is paused."
        }
        return saved
    }

    private func cancelAutoSampling() {
        if isAutoSampling {
            recordAcquisitionEvent(AcquisitionEvent(
                kind: "auto-sampling-stopped", message: "Automatic sampling stopped."))
        }
        autoSamplingTask?.cancel()
        autoSamplingTask = nil
        automaticStillTask?.cancel()
        automaticStillTask = nil
        isAutoSampling = false
    }

    func sampleCurrentARFrame(useBestFrame: Bool = false) {
        guard canAcquire else { return }
        releaseCheckMessages = []
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }

        guard ensureCaptureMetadata() else { return }
        do {
            _ = try scanViewModel.sampleCurrentFrame(artifactStore: artifactStore, session: session,
                includeCompressedImage: captureCompressedImageReferences, useBestFrame: useBestFrame,
                minimumGap: autoSamplingInterval, recaptureTargetLabel: useBestFrame ? nil : recaptureTargetLabel)
            statusMessage = scanViewModel.status.message
        } catch {
            captureWriteCompleted(sessionID: session.id, result: .failure(error))
        }
    }

    func captureHighResolutionStill(automatic: Bool = false) async {
        guard canAcquire, ensureCaptureMetadata() else { return }
        releaseCheckMessages = []
        guard let artifactStore, !scanViewModel.isCapturingStill else { return }
        lastStillRequest = Date()
        let sessionID = session.id
        do {
            _ = try await scanViewModel.captureStill(artifactStore: artifactStore, session: session,
                includeCompressedImage: captureCompressedImageReferences, automatic: automatic,
                guidedView: automatic ? nil : selectedGuidedView,
                recaptureTargetLabel: automatic ? nil : recaptureTargetLabel)
            guard session.id == sessionID else { return }
            statusMessage = scanViewModel.status.message
        } catch {
            guard session.id == sessionID else { return }
            recordAcquisitionEvent(AcquisitionEvent(kind: "high-resolution-still-failed", message: error.localizedDescription))
            statusMessage = "Still capture failed: \(error.localizedDescription)"
        }
    }

    private func ensureCaptureMetadata() -> Bool {
        guard captureMetadataSessionID != session.id else { return true }
        guard persistSession() else { return false }
        captureMetadataSessionID = session.id
        observationsSinceMetadataFlush = 0
        lastMetadataFlush = ProcessInfo.processInfo.systemUptime
        return true
    }

    @discardableResult
    private func flushCaptureMetadata() -> Bool {
        guard let artifactStore, persistSession() else { return false }
        do {
            diagnosticsPath = try artifactStore.writeDiagnostics(for: session, scanStatus: scanViewModel.status).path
            observationsSinceMetadataFlush = 0
            lastMetadataFlush = ProcessInfo.processInfo.systemUptime
            return true
        } catch {
            captureSaveError = "Could not flush capture diagnostics: \(error.localizedDescription)"
            return false
        }
    }

    private func captureWriteCompleted(sessionID: UUID, result: Result<CaptureObservation, Error>) {
        guard session.id == sessionID else { return } // Never mutate a different capture.
        switch result {
        case .success(var observation):
            session.acquisitionContext?.captureReview = nil
            session.lastRawExportedBundleID = nil
            session.lastExportedBundleID = nil
            if scanViewModel.motionStopped { observation.quality?.motionAssessment?.state = .suspected }
            session.captureRoute?.invalidateReview()
            session.captureObservations.append(observation)
            session.captureObservations.sort { $0.capturedAt < $1.capturedAt }
            observationsSinceMetadataFlush += 1
            enqueueLiveMetricDepthFusion(observation, frameID: session.captureObservations.count)
            enqueueLiveDetection(observation)
            if !isDrainingCapture && (!isAutoSampling || observationsSinceMetadataFlush >= 10
                || ProcessInfo.processInfo.systemUptime - lastMetadataFlush >= 5) {
                if !flushCaptureMetadata() { stopAutoSampling() }
            }
            if !isDrainingCapture { statusMessage = sampleStatus(observation) }
        case .failure(let error):
            captureWriteFailure = "Capture write failed: \(error.localizedDescription)"
            captureSaveError = captureWriteFailure
            scanViewModel.pause()
            stopAutoSampling()
            recordAcquisitionEvent(AcquisitionEvent(kind: "capture-write-failed", message: error.localizedDescription))
            statusMessage = "Capture stopped after a write failure. Completed frames remain recoverable."
        }
    }

    /// Stop admission and invalidate outstanding AR still requests, but finish
    /// already-owned frames. Completion callbacks run before drain returns.
    private func finishCaptureWrites() async {
        cancelAutoSampling()
        scanViewModel.invalidatePendingCaptures()
        if let drainTask { await drainTask.value; return }
        isDrainingCapture = true
        await scanViewModel.drainWrites()
        _ = saveCaptureCheckpoint()
        isDrainingCapture = false
    }

    func checkBeforeParticipantRelease() async {
        guard let artifactStore, !isCheckingRelease, !isEndingSession, !isExporting, !needsSessionName else { return }
        isCheckingRelease = true
        await finishCaptureWrites()
        guard captureSaveError == nil else { isCheckingRelease = false; return }
        // Admission has stopped and accepted writes have drained. Finish the
        // bounded live OCR backlog before recording what was/was not checked.
        while let task = liveDetectionTask { await task.value }
        let review = captureReviewSnapshot()
        if session.acquisitionContext == nil { session.acquisitionContext = AcquisitionContext() }
        session.acquisitionContext?.captureReview = review
        scanViewModel.pause()
        defer { isCheckingRelease = false }
        await Task.yield()
        do {
            try artifactStore.writeSession(session)
            try artifactStore.writeAcquisitionContext(for: session)
            let capturedSession = session
            let result = try await Task.detached(priority: .userInitiated) {
                try artifactStore.writeCaptureReceipt(for: capturedSession)
            }.value
            releaseCheckMessages = ["File validation: \(result.receipt.status.rawValue)",
                "Decoded images: \(result.receipt.decodedImageCount)/\(result.receipt.observationCount)",
                "Export prepared: \(session.lastRawExportedBundleID == nil ? "not yet" : "yes — confirm the destination copy")"]
            releaseCheckMessages += geometryReviewMessages
            if scanViewModel.motionStopped || session.captureObservations.contains(where: { $0.quality?.motionAssessment?.state == .suspected }) {
                releaseCheckMessages.append("Movement flagged: file integrity does not establish usable geometry. Collect a separate stationary pass before release.")
            }
            releaseCheckMessages.append("Optional view tags still missing: \(review.missingViews.isEmpty ? "none" : review.missingViews.joined(separator: ", ")). Untagged images may cover these views; five tags do not establish completeness.")
            if session.layout.hasElectrodeNet {
                releaseCheckMessages.append("Live OCR checked \(review.processedLiveFrameCount) frames; it is not the final Mac solve.")
                releaseCheckMessages.append("Not yet read: \(review.unreadLabels.count); ambiguous: \(review.ambiguousLabels.count); single-view only: \(review.singleViewLabels.count).")
                if !review.unreadLabels.isEmpty { releaseCheckMessages.append("Unread labels: " + review.unreadLabels.joined(separator: ", ")) }
                if !review.ambiguousLabels.isEmpty { releaseCheckMessages.append("Ambiguous labels: " + review.ambiguousLabels.joined(separator: ", ")) }
            }
            releaseCheckMessages += result.receipt.checks.filter { $0.status != .passed }.map(\.message)
            let blurry = session.captureObservations.filter { $0.quality?.warnings.contains("possible-motion-blur") == true }.count
            if blurry > 0 { releaseCheckMessages.append("\(blurry) frames have blur warnings. Revisit those views before release.") }
            recordAcquisitionEvent(AcquisitionEvent(kind: "participant-release-check", message: result.receipt.status.rawValue))
        } catch { releaseCheckMessages = ["Validation failed: \(error.localizedDescription)"] }
    }

    private func resetLiveMetricDepthFusion() {
        liveMetricDepthPointCloud = MetricDepthPointCloudSnapshot()
        liveMetricDepthFusionStatus = session.headBoundingBox == nil
            ? "Set the head region to build dense depth points."
            : "Dense depth preview is ready for the next saved sample."
        let sessionID = session.id
        Task { await liveMetricDepthFusion.reset(to: sessionID) }
    }

    private func enqueueLiveMetricDepthFusion(
        _ observation: CaptureObservation, frameID: Int
    ) {
        guard !scanViewModel.motionStopped,
              observation.quality?.motionAssessment?.state != .insufficientEvidence,
              session.captureMode.usesLiDAR,
              observation.rawDepthFilename != nil,
              let bounds = session.headBoundingBox,
              let artifactStore else { return }
        let sessionID = session.id
        let directory = artifactStore.rootDirectory.appendingPathComponent(
            sessionID.uuidString, isDirectory: true)
        let fusion = liveMetricDepthFusion
        if liveMetricDepthPointCloud.points.isEmpty {
            liveMetricDepthFusionStatus = "Building the first lightweight depth preview…"
        }

        Task { [weak self] in
            let frame = await Task.detached(priority: .userInitiated) {
                CaptureArtifactFrameProvider(sessionDirectory: directory)
                    .metricDepthPointFrame(for: observation, frameID: frameID)
            }.value
            guard let frame,
                  let update = await fusion.ingest(
                    frame, sessionID: sessionID, bounds: bounds) else { return }
            guard let self, !self.scanViewModel.motionStopped, self.session.id == sessionID,
                  self.session.headBoundingBox == bounds else { return }
            self.liveMetricDepthPointCloud = update.snapshot
            self.liveMetricDepthFusionStatus = "6 mm live preview · "
                + "\(update.snapshot.points.count.formatted()) points · "
                + "\(update.snapshot.repeatObservedPointCount.formatted()) repeat-observed · "
                + "\(Int((update.elapsedSeconds * 1_000).rounded())) ms"
        }
    }

    private func enqueueLiveDetection(_ observation: CaptureObservation) {
        guard !scanViewModel.motionStopped,
              liveDetectionEnabled,
              observation.cameraSnapshotFilename != nil else { return }
        if observation.quality?.warnings.contains("possible-motion-blur") == true {
            liveDetectionStatus = "Skipped a blurred sample; capture continues."
            return
        }
        liveOCRCandidateCount += 1
        let isStill = observation.quality?.captureSource == "high-resolution-still"
        guard isStill || observation.quality?.recaptureTargetLabel != nil || liveOCRCandidateCount % 3 == 1 else { return }
        if liveDetectionTask != nil {
            if pendingLiveObservation?.quality?.captureSource == "high-resolution-still" && !isStill { return }
            // Coalesce under load: raw capture keeps every sample, while live OCR
            // catches up using the newest view. Finalization processes them all.
            pendingLiveObservation = observation
            liveDetectionStatus = "Live OCR is catching up; newest frame queued."
            return
        }
        processLiveObservation(observation)
    }

    private func processLiveObservation(_ observation: CaptureObservation) {
        guard let artifactStore else { return }
        let sessionSnapshot = session
        let sessionDirectory = artifactStore.rootDirectory.appendingPathComponent(
            session.id.uuidString, isDirectory: true)
        let generation = liveDetectionGeneration
        if liveDetectionStartedAt == nil { liveDetectionStartedAt = Date() }
        isLiveDetecting = true
        liveDetectionStatus = "Reading electrode labels from saved sample \(session.captureObservations.count)…"

        liveDetectionTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                do {
                    return (try LiveElectrodeDetectionWorker.detect(
                        observation: observation, session: sessionSnapshot,
                        sessionDirectory: sessionDirectory), nil as String?)
                } catch {
                    return (LiveDetectionResult(sightings: [], detections: []), error.localizedDescription)
                }
            }.value

            guard let self, self.liveDetectionGeneration == generation,
                  self.session.id == sessionSnapshot.id else { return }
            self.liveDetectionTask = nil
            self.isLiveDetecting = false
            if let error = outcome.1 {
                self.liveDetectionStatus = "Live OCR skipped a frame: \(error)"
            } else {
                self.liveRawDetections.append(contentsOf: outcome.0.detections)
                self.liveLabelCoverage.ingest(outcome.0.sightings, observationID: observation.id, pose: observation.cameraTransform)
                self.liveProcessedFrameIDs.append(observation.id)
                self.rebuildLiveElectrodes()
                if let target = self.recaptureTargetLabel,
                   self.liveLabelCoverage.supportedLabels.contains(target) {
                    self.recaptureTargetLabel = nil
                    self.recordAcquisitionEvent(AcquisitionEvent(kind: "recapture-target-supported", message: target + " has unverified support in distinct views."))
                }
            }

            if let pending = self.pendingLiveObservation {
                self.pendingLiveObservation = nil
                self.processLiveObservation(pending)
            }
        }
    }

    private func rebuildLiveElectrodes() {
        let fused = ElectrodeObservationAggregator.aggregate(liveRawDetections)
        let positions = Dictionary(uniqueKeysWithValues: fused.map { ($0.label, $0.position) })
        let suspects = ElectrodeNeighborValidator.validate(
            positions: positions, layout: session.layout).suspectLabels
        liveLabelCoverage.markAmbiguous(suspects)
        let directlyObserved = ElectrodeAnnotationBuilder.build(
            from: fused, layout: session.layout, confidenceThreshold: 0.55,
            suspectLabels: suspects)
        liveElectrodes = directlyObserved

        let directCount = directlyObserved.count
        let predictedCount = liveElectrodes.count - directCount
        liveDetectionStatus = predictedCount > 0
            ? "Live: \(directCount) observed · \(predictedCount) provisional from template."
            : "Live: \(directCount) labels localized from \(liveProcessedFrameIDs.count) frames."
        writeLiveDetectionDiagnostics(suspects: suspects, directCount: directCount)
    }

    private func writeLiveDetectionDiagnostics(suspects: Set<String>, directCount: Int) {
        guard let artifactStore, let startedAt = liveDetectionStartedAt else { return }
        let directPositions = Dictionary(uniqueKeysWithValues: liveElectrodes
            .filter { $0.confidence > 0 }.map {
                ($0.label, SIMD3<Float>(
                    Float($0.coordinate.x), Float($0.coordinate.y), Float($0.coordinate.z)))
            })
        let templateFit = ElectrodeCapOrientation.estimate(
            detected: directPositions, layout: session.layout)
        let diagnostics = DetectionRunDiagnostics(
            id: session.id,
            mode: .live,
            startedAt: startedAt,
            completedAt: Date(),
            engine: "manta-vision-ocr-depth",
            engineVersion: "2",
            processedFrameIDs: liveProcessedFrameIDs,
            rawDetectionCount: liveRawDetections.count,
            directlyLocalizedElectrodeCount: directCount,
            templatePredictedElectrodeCount: liveElectrodes.filter { $0.confidence == 0 }.count,
            suspectLabels: suspects.sorted(),
            templateFitRMSMillimeters: templateFit.map { Double($0.rmsError * 1000) },
            templateAnchorCount: templateFit?.anchorCount,
            electrodes: liveElectrodes,
            producer: solverProducerMetadata(),
            parameters: [
                "ocrConfidenceThreshold": "0.75",
                "ocrMinimumTextHeight": "0.005",
                "aggregationConfidenceThreshold": "0.55",
                "fillsMissingFromTemplate": "false",
                "neighborValidation": "true"
            ])
        _ = try? artifactStore.writeDetectionDiagnostics(diagnostics, for: session)
    }

    private func writeFinalDetectionDiagnostics(startedAt: Date) {
        guard let artifactStore else { return }
        let direct = session.electrodes.filter { $0.confidence > 0 }
        let positions = Dictionary(uniqueKeysWithValues: direct.map {
            ($0.label, SIMD3<Float>(Float($0.coordinate.x), Float($0.coordinate.y), Float($0.coordinate.z)))
        })
        let suspects = ElectrodeNeighborValidator.validate(
            positions: positions, layout: session.layout).suspectLabels
        let templateFit = ElectrodeCapOrientation.estimate(
            detected: positions, layout: session.layout)
        let diagnostics = DetectionRunDiagnostics(
            id: UUID(), mode: .finalized, startedAt: startedAt, completedAt: Date(),
            engine: "manta-vision-ocr-depth-full-session", engineVersion: "1",
            processedFrameIDs: session.captureObservations.map(\.id),
            rawDetectionCount: nil,
            directlyLocalizedElectrodeCount: direct.count,
            templatePredictedElectrodeCount: session.electrodes.filter { $0.confidence == 0 }.count,
            suspectLabels: suspects.sorted(),
            templateFitRMSMillimeters: templateFit.map { Double($0.rmsError * 1000) },
            templateAnchorCount: templateFit?.anchorCount,
            electrodes: session.electrodes,
            producer: solverProducerMetadata(),
            parameters: [
                "aggregationConfidenceThreshold": "0.55",
                "fillsMissingFromTemplate": "true",
                "neighborValidation": "true"
            ])
        _ = try? artifactStore.writeDetectionDiagnostics(diagnostics, for: session)
    }

    private func solverProducerMetadata() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        var metadata = [
            "applicationVersion": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info["CFBundleVersion"] as? String ?? "unknown",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        if let revision = info["MANTAGitRevision"] as? String, !revision.isEmpty {
            metadata["sourceRevision"] = revision
        }
        #if canImport(UIKit)
        metadata["deviceModel"] = DeviceHardwareIdentifier.current
        #endif
        return metadata
    }

    private func resetLiveDetection() {
        liveDetectionGeneration = UUID()
        liveDetectionTask?.cancel()
        liveDetectionTask = nil
        pendingLiveObservation = nil
        liveRawDetections = []
        liveLabelCoverage = LiveLabelCoverage()
        selectedGuidedView = nil
        recaptureTargetLabel = nil
        showCoverageReview = false
        liveOCRCandidateCount = 0
        liveProcessedFrameIDs = []
        liveDetectionStartedAt = nil
        liveElectrodes = []
        isLiveDetecting = false
        liveDetectionStatus = liveDetectionEnabled
            ? "Waiting for a saved frame." : "Live detection is off."
    }

    func exportDiagnostics() {
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }

        do {
            let diagnosticsURL = try artifactStore.writeDiagnostics(for: session, scanStatus: scanViewModel.status)
            diagnosticsPath = diagnosticsURL.path
            statusMessage = "Diagnostics saved."
        } catch {
            statusMessage = "Could not save diagnostics: \(error.localizedDescription)"
        }
    }

    /// Assembles the geometry the alignment solvers consume.
    ///
    /// Target landmarks come from the placed fiducials in the ARKit world frame. The source
    /// landmarks (fiducials marked on the reconstructed model), the model point cloud, and the
    /// LiDAR mesh cloud are gathered here as those capture/loading paths come online; until then
    /// the solver falls back to identity and the UI reports that geometry is still needed.
    private func gatherAlignmentInput(
        targetCloud: [SIMD3<Float>] = [],
        sourceCloud: [SIMD3<Float>] = []
    ) -> WorldAlignmentInput {
        var input = WorldAlignmentInput()
        input.seed = session.alignmentSeed
        // Target landmarks: fiducials in the ARKit world frame. Source landmarks: fiducials
        // marked on the reconstructed model. Order is kept consistent by fiducial kind so the
        // correspondences line up.
        input.targetLandmarks = orderedLandmarks(session.fiducials)
        input.sourceLandmarks = orderedLandmarks(session.modelFiducials)
        input.sourceCloud = sourceCloud
        input.targetCloud = targetCloud
        return input
    }

    /// Landmarks in a fixed kind order, only including fiducials that have coordinates.
    /// Returns an empty array unless every kind is present, so partial sets don't create
    /// mismatched correspondences.
    private func orderedLandmarks(_ fiducials: [FiducialAnnotation]) -> [SIMD3<Float>] {
        let byKind = Dictionary(uniqueKeysWithValues: fiducials.map { ($0.kind, $0) })
        var result: [SIMD3<Float>] = []
        for kind in FiducialKind.cardinal {
            guard let coordinate = byKind[kind]?.coordinate else { return [] }
            result.append(SIMD3<Float>(Float(coordinate.x), Float(coordinate.y), Float(coordinate.z)))
        }
        return result
    }

    /// Session as exported: electrodes/fiducials converted into the fiducial-
    /// anchored head frame (mm) when all three fiducials are placed, otherwise the
    /// raw world-frame session.
    var exportSession: ScanSession {
        HeadCoordinateFrame.apply(to: session) ?? session
    }

    /// Whether the export coordinates are in the head frame (vs raw world).
    var isExportHeadFramed: Bool {
        session.fiducialsReady && HeadCoordinateFrame.apply(to: session) != nil
    }

    func shareCoordinateExport() {
        do {
            let session = exportSession
            let ext: String
            let unit: String
            switch selectedFormat {
            case .sfp: (ext, unit) = ("sfp", "m")
            case .sfpCentimeters: (ext, unit) = ("sfp", "cm")
            case .geoScanTXT: (ext, unit) = ("txt", "cm")
            default: return
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(
                "manta_coordinates_\(session.coordinateSpace.frame.rawValue)_\(unit).\(ext)")
            try ElectrodeExporters.export(session, as: selectedFormat)
                .write(to: url, atomically: true, encoding: .utf8)
            exportedBundle = ExportedBundle(urls: [url])
        } catch {
            statusMessage = "Coordinate export failed: \(error.localizedDescription)"
        }
    }

    private func refreshExportPreview() {
        exportPreview = ElectrodeExporters.export(exportSession, as: selectedFormat)
    }

    private var canAutoSample: Bool {
        guard scanViewModel.status.isRunning,
              scanViewModel.status.trackingSummary == "Normal" else {
            return false
        }
        // LiDAR-backed modes wait for valid scene depth; photogrammetry-only just needs tracking.
        return session.captureMode.usesLiDAR ? scanViewModel.status.hasSceneDepth : true
    }

}

private extension simd_float4x4 {
    /// Column-major flattening, matching the layout used for stored camera transforms.
    var flattenedColumns: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w
        ]
    }
}
