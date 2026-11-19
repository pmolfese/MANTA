//
//  ARScanViewModel.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import MANTACore
import Combine
import CoreGraphics
import simd

struct FiducialRaycastResult {
    var point: SIMD3<Float>
    var rayOrigin: SIMD3<Float>?
    var rayDirection: SIMD3<Float>?
    var hitMethod: String
    var observationID: UUID?
}

#if canImport(ARKit) && canImport(RealityKit)
import ARKit
import RealityKit
import Vision

@MainActor
final class ARScanViewModel: NSObject, ObservableObject {
    @Published var status = LiveScanStatus(isSupported: ARWorldTrackingConfiguration.isSupported)
    @Published var observations: [CaptureObservation] = []
    var eventHandler: ((AcquisitionEvent) -> Void)?
    @Published var preserveComparisonFrames = false
    @Published var captureSafetyMessage: String?
    @Published private(set) var activeSettingsSummary: String?
    @Published private(set) var storageMessage: String?
    var storageCapacityProvider: (() -> Int64?)?
    private var storageMonitor: Task<Void, Never>?
    private var lastStorageState: CaptureStoragePolicy.State?
    var canEditCaptureSettings: Bool { !hasStartedTracking && observations.isEmpty && !worldInvalidated }
    private(set) var hasStartedTracking = false

    func settingsSummary(captureMode: CaptureMode) -> String {
        let name = adaptiveSampling ? "Custom adaptive capture" : CapturePreset.name(usesDepth: captureMode.usesLiDAR, bestFrames: selectBestFrames,
            comparisonFrames: preserveComparisonFrames, highResolutionStills: highResolutionStills)
        return "\(name) · \(captureMode.rawValue) · Best frames \(selectBestFrames ? "on" : "off") · Cadence pairs \(preserveComparisonFrames ? "on" : "off") · Hi-res stills \(highResolutionStills ? "on" : "off") · Auto stills \(automaticHighResolutionStills ? "on" : "off") · Adaptive \(adaptiveSampling ? "on" : "off")"
    }

    /// Called before each observation's artifact writes and by the independent monitor.
    @discardableResult
    func checkStorage(_ bytes: Int64?) -> Bool {
        let state = CaptureStoragePolicy.evaluate(availableBytes: bytes)
        switch state {
        case .ready: storageMessage = nil
        case .warning:
            storageMessage = "Storage is below 3 GB. Capture will pause at 1 GB; finish this pass soon."
        case .stop:
            storageMessage = "Capture paused: 1 GB storage reserve reached. Free space, then resume capture. Saved frames remain available."
        case .unavailable:
            storageMessage = "Capture paused: available storage could not be checked. Restore storage access before resuming."
        }
        if !state.allowsCapture {
            pause()
            status.message = storageMessage ?? "Capture paused for storage."
        }
        if state != lastStorageState {
            lastStorageState = state
            eventHandler?(AcquisitionEvent(kind: "capture-storage-state", message: storageMessage ?? "Storage available.",
                details: ["state": state.rawValue, "availableBytes": bytes.map(String.init) ?? "unknown",
                          "warningBytes": String(CaptureStoragePolicy.warningBytes),
                          "reserveBytes": String(CaptureStoragePolicy.reserveBytes)]))
        }
        return state.allowsCapture
    }

    private func startStorageMonitor() {
        storageMonitor?.cancel()
        storageMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.status.isRunning else { return }
                if let provider = self.storageCapacityProvider, !self.checkStorage(provider()) { return }
            }
        }
    }

    @Published private(set) var motionMessage = "Motion check not armed. Set the head region and freeze a stable reference."
    @Published private(set) var motionStopped = false
    private(set) var motionSegmentID = UUID()
    private var motionReference: [SIMD3<Float>] = []
    private var motionBounds: HeadBoundingBox?
    private var motionGate = CaptureMotionGate()
    private var motionRecovery = LiveMotionRecovery()
    @Published var continuousNetTrackingEnabled = false {
        didSet {
            guard oldValue != continuousNetTrackingEnabled, !continuousNetTrackingEnabled else { return }
            if netTrackingWasActive {
                motionGate.holdForAlignment()
                motionFusionHeld = true
                netTrackingWasActive = false
            }
            netTrackingTask?.cancel()
            netTrackingTask = nil
            netTrackingJobID = UUID()
            netLandmarkRevision = UUID()
            captureNetPose = nil
        }
    }
    private var netTracker = ContinuousNetTracker()
    private var netTrackingTask: Task<Void, Never>?
    private var netLandmarkRevision = UUID()
    private var netTrackingJobID = UUID()
    private var lastNetTrackingTimestamp = -Double.infinity
    private var captureNetPose: NetPoseSample?
    private var lastNetTransform: simd_float4x4?
    private var netTrackingWasActive = false
    @Published private(set) var netTrackingMessage = "Net tracking is waiting for repeated electrode labels."
    private var motionRecoveryTask: Task<Void, Never>?
    private var motionRecoveryEpoch = UUID()
    private var motionRecoveryAttempt = 0
    private var lastRecoveryAttemptTimestamp = -Double.infinity
    private var lastReferenceViewTimestamp = -Double.infinity
    private var motionReferenceViews: [[SIMD3<Float>]] = []
    @Published private(set) var motionFusionHeld = false
    private var trustedMeshSnapshot: LiDARMeshSnapshot?
    // ARKit's accumulated mesh cannot undo samples integrated during uncertainty.
    private var accumulatedMeshFrozen = false

    func hasMotionReference(for bounds: HeadBoundingBox?) -> Bool {
        !motionStopped && !motionReference.isEmpty && bounds != nil && bounds == motionBounds
    }

    func invalidateMotionReferenceForRegionChange() {
        if motionRecovery.transform != nil || lastNetTransform != nil { motionGate.holdForAlignment(); motionFusionHeld = true }
        invalidateMotionRecovery()
        motionReference = []
        motionBounds = nil
        guard !motionStopped else { return }
        motionMessage = "Head region changed. Scan the stationary head and freeze a new reference."
    }

    func freezeMotionReference(bounds: HeadBoundingBox?) {
        guard status.isRunning, !motionStopped, !accumulatedMeshFrozen, let bounds else {
            motionMessage = "Set the head region first. After movement, start a new pass."
            return
        }
        invalidateMotionRecovery()
        let points = fullMeshSnapshot().cropped(to: bounds).vertices
        guard points.count >= 50 else { motionMessage = "Scan more of the stationary head before freezing a reference."; return }
        trustedMeshSnapshot = fullMeshSnapshot()
        motionReference = stride(from: 0, to: points.count, by: max(1, points.count / 2048)).prefix(2048).map { points[$0] }
        motionBounds = bounds
        motionMessage = "Reference frozen. Depth consistency is advisory, not proof of a stationary head."
        eventHandler?(AcquisitionEvent(kind: "motion-reference-frozen", message: motionMessage,
            details: ["segmentID": motionSegmentID.uuidString, "referencePoints": String(motionReference.count)]))
    }

    func markSubjectMoved() {
        guard !motionStopped else { return }
        invalidateMotionRecovery()
        motionStopped = true
        worldInvalidated = true
        pause()
        motionMessage = "Movement flagged. Evidence retained; continue with a new pass in this session after the subject settles."
        captureSafetyMessage = motionMessage
        eventHandler?(AcquisitionEvent(kind: "subject-movement", message: motionMessage,
            details: ["segmentID": motionSegmentID.uuidString]))
    }

    /// Never pauses capture or invalidates previously saved observations.
    func assessCaptureMotion(_ rawMotion: CaptureMotionAssessment, timestamp: Double) -> CaptureMotionAssessment {
        let wasHolding = motionFusionHeld
        let motion = motionGate.assess(rawMotion, timestamp: timestamp)
        motionFusionHeld = motionGate.isHolding
        if motionFusionHeld { accumulatedMeshFrozen = true }
        if !accumulatedMeshFrozen { trustedMeshSnapshot = fullMeshSnapshot() }
        if wasHolding != motionFusionHeld {
            eventHandler?(AcquisitionEvent(kind: motionFusionHeld ? "motion-fusion-held" : "motion-fusion-resumed",
                message: motionFusionHeld ? "Recording continues; uncertain frames excluded from model updates." : "Reference consistency restored; model updates resumed."))
        }
        return motion
    }

    private func invalidateMotionRecovery() {
        motionRecoveryEpoch = UUID()
        motionRecoveryTask?.cancel()
        motionRecoveryTask = nil
        motionRecovery = LiveMotionRecovery()
        netTracker = ContinuousNetTracker()
        netLandmarkRevision = UUID()
        netTrackingJobID = UUID()
        netTrackingTask?.cancel()
        netTrackingTask = nil
        lastNetTrackingTimestamp = -.infinity
        captureNetPose = nil
        lastNetTransform = nil
        netTrackingWasActive = false
        netTrackingMessage = "Net tracking is waiting for repeated electrode labels."
        motionReferenceViews = []
        motionRecoveryAttempt = 0
        lastRecoveryAttemptTimestamp = -.infinity
        lastReferenceViewTimestamp = -.infinity
    }

    /// Used by the background solver; acquisition remains independent of its lifetime.
    @discardableResult
    func acceptMotionAlignment(_ result: SegmentRegistrationResult, reference: [SIMD3<Float>], timestamp: Double) -> Bool {
        guard motionFusionHeld, !motionStopped else { return false }
        return motionRecovery.propose(result, reference: reference, timestamp: timestamp)
    }

    private func scheduleMotionRecovery(points: [SIMD3<Float>], timestamp: Double) {
        guard motionFusionHeld, !motionStopped, motionRecoveryTask == nil,
              !motionRecovery.hasCandidate, points.count >= 50,
              timestamp - lastRecoveryAttemptTimestamp >= 3 else { return }
        let views = motionReferenceViews.isEmpty ? [motionReference] : motionReferenceViews
        let reference = views[motionRecoveryAttempt % views.count]
        guard reference.count >= 50 else { return }
        motionRecoveryAttempt += 1
        lastRecoveryAttemptTimestamp = timestamp
        let epoch = motionRecoveryEpoch
        // Arrays contain owned values only; no ARFrame or pixel buffers cross actors.
        motionRecoveryTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                SegmentRegistration.solveAutomatic(source: points, reference: reference)
            }.value
            guard let self, self.motionRecoveryEpoch == epoch else { return }
            self.motionRecoveryTask = nil
            guard !Task.isCancelled, self.status.isRunning else { return }
            let accepted = self.acceptMotionAlignment(result, reference: reference, timestamp: timestamp)
            self.eventHandler?(AcquisitionEvent(kind: accepted ? "motion-alignment-candidate" : "motion-alignment-rejected",
                message: result.reason))
        }
    }

    /// OCR results keep original AR coordinates even when their frame was held.
    func observeNetLandmarks(_ landmarks: [LabeledDetection], observation: CaptureObservation) {
        guard continuousNetTrackingEnabled, !motionStopped,
              observation.quality?.motionAssessment?.segmentID == motionSegmentID,
              let timestamp = observation.quality?.arFrameTimestamp else { return }
        let trusted: simd_float4x4? = observation.quality?.motionAssessment?.state == .consistent
            ? observation.quality?.liveMotionCorrection.flatMap { SegmentRegistration.matrix($0.referenceFromWorld) } ?? matrix_identity_float4x4 : nil
        let bounded = landmarks.filter { landmark in
            guard let trusted, let bounds = motionBounds else { return true }
            let point = SegmentRegistration.point(landmark.world, trusted)
            return abs(Double(point.x) - bounds.center.x) <= bounds.widthMeters / 2
                && abs(Double(point.y) - bounds.center.y) <= bounds.heightMeters / 2
                && abs(Double(point.z) - bounds.center.z) <= bounds.depthMeters / 2
        }
        netTracker.observe(bounded, timestamp: timestamp, trustedReferenceFromWorld: trusted)
        netLandmarkRevision = UUID()
        netTrackingMessage = netTracker.hasLandmarkConflict
            ? "Electrode pattern changed; recording continues while the net is reacquired."
            : "Net reference: \(netTracker.anchors.count) confirmed labels."
    }

    private var trackingReferencePoints: [SIMD3<Float>] {
        motionReference + motionReferenceViews.flatMap { $0 } + motionRecovery.alignedReference
    }

    /// At most one bounded depth-tracking solve runs off the main actor, targeting
    /// roughly 6 Hz. Saving a frame still checks that exact frame independently.
    private func updateContinuousNetTracking(_ frame: ARFrame) {
        guard continuousNetTrackingEnabled, status.isRunning, !motionStopped, !worldInvalidated,
              netTrackingTask == nil, frame.timestamp - lastNetTrackingTimestamp >= 0.15,
              let bounds = motionBounds, netTracker.seed(at: frame.timestamp) != nil,
              let points = motionPoints(frame, bounds: bounds),
              let request = netTracker.request(points: points, reference: trackingReferencePoints, timestamp: frame.timestamp) else { return }
        lastNetTrackingTimestamp = frame.timestamp
        let epoch = motionRecoveryEpoch, revision = netLandmarkRevision, jobID = UUID()
        netTrackingJobID = jobID
        netTrackingTask = Task { [weak self] in
            let pose = await Task.detached(priority: .utility) { request.solve() }.value
            guard let self, self.motionRecoveryEpoch == epoch, self.netTrackingJobID == jobID else { return }
            self.netTrackingTask = nil
            guard !Task.isCancelled, self.netLandmarkRevision == revision,
                  self.status.isRunning, !self.motionStopped else { return }
            if let pose {
                _ = self.netTracker.record(pose)
                if self.netTracker.isTracking {
                    self.lastNetTransform = pose.transform
                    self.netTrackingMessage = "Tracking net · \(pose.labelCount) matched labels · depth pose updates active."
                }
            } else { self.netTracker.miss(at: request.timestamp) }
        }
    }

    func assessMotionPoints(_ points: [SIMD3<Float>], timestamp: Double) -> CaptureMotionAssessment {
        captureNetPose = nil
        if continuousNetTrackingEnabled,
           let request = netTracker.request(points: points, reference: trackingReferencePoints, timestamp: timestamp),
           let pose = request.solve() {
            _ = netTracker.record(pose)
            if netTracker.isTracking {
                captureNetPose = pose
                lastNetTransform = pose.transform
                if !netTrackingWasActive {
                    eventHandler?(AcquisitionEvent(kind: "continuous-net-tracking-started", message: "Net-relative pose updates are active.",
                        details: ["matchedLabels": String(pose.labelCount)]))
                }
                netTrackingWasActive = true
                accumulatedMeshFrozen = true
                motionGate.resumeAfterAlignment(at: timestamp)
                // A verified new view extends coverage in the original net frame.
                if timestamp - lastReferenceViewTimestamp >= 3, timestamp - pose.landmarkTimestamp <= 0.5 {
                    let aligned = points.map { SegmentRegistration.point($0, pose.transform) }
                    let step = max(1, (aligned.count + 511) / 512)
                    motionReferenceViews.append(stride(from: 0, to: aligned.count, by: step).map { aligned[$0] })
                    if motionReferenceViews.count > 12 { motionReferenceViews.removeFirst() }
                    lastReferenceViewTimestamp = timestamp
                }
                return assessCaptureMotion(.init(segmentID: motionSegmentID, state: .consistent,
                    residualMeters: pose.residualMeters), timestamp: timestamp)
            }
        } else if continuousNetTrackingEnabled { netTracker.miss(at: timestamp) }
        if netTrackingWasActive {
            motionGate.holdForAlignment()
            netTrackingWasActive = false
        }
        if continuousNetTrackingEnabled, netTracker.hasLandmarkConflict {
            motionGate.holdForAlignment()
            return assessCaptureMotion(.init(segmentID: motionSegmentID, state: .suspected), timestamp: timestamp)
        }
        if motionFusionHeld, motionRecovery.validate(points: points, timestamp: timestamp) {
            motionGate.resumeAfterAlignment(at: timestamp)
            lastNetTransform = nil
            eventHandler?(AcquisitionEvent(kind: "motion-alignment-validated",
                message: "Alignment agreed across three later frames; model updates resume."))
        }
        let transform = motionRecovery.transform ?? matrix_identity_float4x4
        let reference = motionReference + motionReferenceViews.flatMap { $0 } + motionRecovery.alignedReference
        let aligned = points.map { SegmentRegistration.point($0, transform) }
        var raw = CaptureMotionCheck.assess(points: aligned, reference: reference, segmentID: motionSegmentID)
        // Recovered poses must meet the stricter registration gate on every admitted frame.
        if motionRecovery.transform != nil, raw.state == .consistent,
           !SegmentRegistration.frameAgrees(points: points, reference: reference, transform: transform) {
            raw.state = .suspected
        }
        let motion = assessCaptureMotion(raw, timestamp: timestamp)
        if motion.state == .consistent, motionRecovery.transform == nil, points.count >= 50,
           timestamp - lastReferenceViewTimestamp >= 3 {
            let step = max(1, (points.count + 511) / 512)
            motionReferenceViews.append(stride(from: 0, to: points.count, by: step).map { points[$0] })
            if motionReferenceViews.count > 6 { motionReferenceViews.removeFirst() }
            lastReferenceViewTimestamp = timestamp
        }
        if motionFusionHeld { scheduleMotionRecovery(points: points, timestamp: timestamp) }
        else if motionRecovery.hasCandidate { motionRecovery.discardCandidate() }
        return motion
    }

    func applyMotionCorrection(to observation: inout CaptureObservation) {
        guard observation.quality?.liveMotionCorrection == nil else { return }
        let netPose = captureNetPose.flatMap { $0.timestamp == observation.quality?.arFrameTimestamp ? $0 : nil }
        if observation.quality?.motionAssessment?.state == .consistent, let transform = netPose?.transform ?? motionRecovery.transform {
            var correction = LiveMotionCorrection(referenceSegmentID: motionSegmentID, transform: transform,
                originalCameraToWorld: observation.cameraTransform, validatedFrameCount: 3)
            if let netPose {
                correction.method = "net-anchored-continuous-rigid-v1"
                correction.trackedLabelCount = netPose.labelCount
                correction.landmarkTimestamp = netPose.landmarkTimestamp
            }
            if let corrected = correction.correctedCameraToWorld {
                observation.cameraTransform = corrected
                observation.quality?.liveMotionCorrection = correction
                observation.quality?.headCenteredCoverageSector = nil
            } else {
                observation.quality?.motionAssessment?.state = .insufficientEvidence
                observation.quality?.warnings.append("invalid-live-correction-pose")
            }
        }
    }

    private func assessMotion(_ frame: ARFrame, bounds: HeadBoundingBox?) -> CaptureMotionAssessment {
        guard !motionStopped else { return assessCaptureMotion(.init(segmentID: motionSegmentID, state: .suspected), timestamp: frame.timestamp) }
        guard !motionReference.isEmpty else { return assessCaptureMotion(.init(segmentID: motionSegmentID, state: .unassessed), timestamp: frame.timestamp) }
        guard bounds == motionBounds, let bounds, let points = motionPoints(frame, bounds: bounds) else {
            return assessCaptureMotion(.init(segmentID: motionSegmentID, state: .insufficientEvidence), timestamp: frame.timestamp)
        }
        return assessMotionPoints(points, timestamp: frame.timestamp)
    }

    private func motionPoints(_ frame: ARFrame, bounds: HeadBoundingBox) -> [SIMD3<Float>]? {
        guard case .normal = frame.camera.trackingState,
              let depth = frame.sceneDepth, let confidence = depth.confidenceMap else {
            return nil
        }
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly); CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddress(map), let conf = CVPixelBufferGetBaseAddress(confidence) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height else {
            return nil
        }
        let camera = PinholeCamera(fx: frame.camera.intrinsics[0][0], fy: frame.camera.intrinsics[1][1],
            cx: frame.camera.intrinsics[2][0], cy: frame.camera.intrinsics[2][1], cameraToWorld: frame.camera.transform)
        var points: [SIMD3<Float>] = []
        let referenceFromWorld = netTracker.seed(at: frame.timestamp)?.transform ?? motionRecovery.transform ?? lastNetTransform ?? matrix_identity_float4x4
        // Bounded search around the last known head pose; larger departures stay held.
        let margin: Double = motionFusionHeld ? 0.10 : (continuousNetTrackingEnabled ? 0.03 : 0)
        for y in stride(from: 0, to: height, by: max(1, height / 48)) {
            for x in stride(from: 0, to: width, by: max(1, width / 48)) {
                guard conf.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(confidence) + x, as: UInt8.self) >= 2 else { continue }
                let z = raw.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(map) + x * 4, as: Float.self)
                guard z.isFinite, z > 0.2, z < 2 else { continue }
                let point = camera.unproject(pixel: SIMD2(Float(x) * Float(frame.camera.imageResolution.width) / Float(width),
                    Float(y) * Float(frame.camera.imageResolution.height) / Float(height)), depth: z)
                let inReference = SegmentRegistration.point(point, referenceFromWorld)
                if abs(Double(inReference.x) - bounds.center.x) <= bounds.widthMeters / 2 + margin,
                   abs(Double(inReference.y) - bounds.center.y) <= bounds.heightMeters / 2 + margin,
                   abs(Double(inReference.z) - bounds.center.z) <= bounds.depthMeters / 2 + margin { points.append(point) }
            }
        }
        return points
    }

    private var worldInvalidated = false
    private let frameWriter = BoundedCaptureWriter(capacity: 3)
    private let captureBuffers = CaptureBufferPool()
    private var lastSubmittedTimestamp: TimeInterval = -1
    var observationSavedHandler: ((UUID, Result<CaptureObservation, Error>) -> Void)?
    var pendingWriteCount: Int { frameWriter.pendingCount }
    func drainWrites() async { await frameWriter.drain() }
    @Published var adaptiveSampling = false
    @Published private(set) var stillGuidance = "Hold the iPad steady for a label photo; the participant should remain still."
    private var stableSince: TimeInterval?
    private var latestSharpness: Double = 0
    private var latestSector = ""
    private var scoredPosition: SIMD3<Float>?
    private var savedStillSectors: Set<String> = []
    private var sampledSectors: Set<String> = []
    private var lastAutomaticSampleTimestamp: TimeInterval?
    var automaticStillReady: Bool {
        AdaptiveCapturePolicy.canTakeStill(stableSeconds: stableSince.map { scoredTimestamp - $0 } ?? 0,
            sharpness: latestSharpness, fresh: ProcessInfo.processInfo.systemUptime - scoredTimestamp < 0.5,
            sectorSaved: savedStillSectors.contains(latestSector))
    }
    @Published var selectBestFrames = false
    @Published var highResolutionStills = true
    @Published var automaticHighResolutionStills = false
    var supportsHighResolutionStillCapture: Bool {
        arView?.session.configuration?.videoFormat.isRecommendedForHighResolutionFrameCapturing == true
    }
    @Published var lensMessage = "Lens check has not run."
    @Published var isCheckingLens = false
    @Published var isCapturingStill = false
    private var bestFrame: (frame: ARFrame, orientation: String, score: Double)?
    private var scoredTimestamp: TimeInterval = 0
    private var scoredRotation: simd_quatf?
    private var requiresDepth = false
    private var captureGeneration = UUID()


    // The capture session outlives an individual SwiftUI Camera/Model tab.
    // Keeping the ARView strongly owned here prevents a visual-mode switch from
    // tearing down RealityKit and silently pausing an otherwise running scan.
    private var arView: ARView?
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var lastSampledTransform: simd_float4x4?
    private var lastReportedTrackingSummary: String?
    private var hasReportedFirstFrame = false

    func attach(_ arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        // `attach` is called by `UIViewRepresentable.makeUIView`, while SwiftUI
        // is still updating its view hierarchy. Publishing synchronously from
        // that callback triggers "Publishing changes from within view updates"
        // and can cause SwiftUI to discard or repeat the update. Yield to the
        // next main-actor turn and ignore the write if this ARView was replaced
        // before then.
        Task { @MainActor [weak self, weak arView] in
            await Task.yield()
            guard let self, let arView, self.arView === arView else { return }
            self.status.isSupported = ARWorldTrackingConfiguration.isSupported
        }
    }

    /// Returns the single ARView backing this capture session. SwiftUI may
    /// remove and recreate its representable while switching visual modes, but
    /// the AR session and accumulated anchors remain attached to this view.
    func captureView() -> ARView {
        if let arView { return arView }
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        attach(view)
        return view
    }

    func start(captureMode: CaptureMode = .both) {
        guard ARWorldTrackingConfiguration.isSupported else {
            status.message = "AR world tracking is not available on this device."
            status.isSupported = false
            return
        }

        guard !worldInvalidated else {
            status.message = "Tracking was interrupted. Start a new session to avoid mixing coordinate worlds."
            captureSafetyMessage = status.message
            return
        }
        if let provider = storageCapacityProvider, !checkStorage(provider()) { return }
        if hasStartedTracking, let existing = arView?.session.configuration {
            arView?.session.run(existing)
            status.isRunning = true
            startStorageMonitor()
            status.message = "Resuming the existing coordinate world. Camera changes require a new session."
            return
        }
        captureGeneration = UUID()
        bestFrame = nil
        scoredTimestamp = 0
        scoredRotation = nil
        requiresDepth = captureMode.usesLiDAR
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .automatic

        if let format = highestResolutionVideoFormat(usesLiDAR: captureMode.usesLiDAR) {
            configuration.videoFormat = format
        }

        if highResolutionStills,
           let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
        }

        // LiDAR depth + mesh are only enabled for modes that use them. Photogrammetry-only
        // capture still runs world tracking so every RGB frame carries an ARKit pose.
        if captureMode.usesLiDAR {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }

            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = .mesh
            }
        }

        meshAnchors.removeAll()
        lastSampledTransform = nil
        lastSubmittedTimestamp = -1
        hasReportedFirstFrame = false
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        hasStartedTracking = true
        status.isRunning = true
        activeSettingsSummary = settingsSummary(captureMode: captureMode)
        startStorageMonitor()
        status.message = captureMode.usesLiDAR
            ? "Move around the cap slowly; keep electrodes in view and avoid motion blur."
            : "Circle the head, keeping frames sharp and well-lit for photogrammetry."

        // Probe 1 (requested): record the camera format and semantics we asked the
        // device for. Comparing this to the first delivered frame reveals a silent
        // ARKit fallback or missing scene depth before a subject is captured.
        let requested = configuration.videoFormat.imageResolution
        eventHandler?(AcquisitionEvent(
            kind: "video-format-selected",
            message: "Requested \(Int(requested.width))x\(Int(requested.height)) camera format.",
            details: [
                "requestedWidth": String(Int(requested.width)),
                "requestedHeight": String(Int(requested.height)),
                "requestedFPS": String(configuration.videoFormat.framesPerSecond),
                "deviceHardwareIdentifier": DeviceHardwareIdentifier.current,
                "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "applicationVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "applicationBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "coordinateTarget": "visibleDiscCupCenter",
                "captureSettings": activeSettingsSummary ?? "unknown",
                "cadenceComparisonFrames": String(preserveComparisonFrames),
                "bestFrameSelection": String(selectBestFrames),
                "adaptiveSampling": String(adaptiveSampling),
                "automaticStillPolicy": "hold-0.3s-sharp-new-direction",
                "frameSelectionVersion": "1",
                "selectionWindowSeconds": "0.9",
                "selectionScoringIntervalSeconds": "0.15",
                "stillMinimumIntervalSeconds": "5",
                "highResolutionStills": String(highResolutionStills),
                "automaticHighResolutionStills": String(automaticHighResolutionStills),
                "sceneDepthRequested": String(configuration.frameSemantics.contains(.sceneDepth)),
                "sceneReconstructionMesh": String(configuration.sceneReconstruction == .mesh),
                "supportedFormatCount": String(ARWorldTrackingConfiguration.supportedVideoFormats.count)
            ]))
    }

    /// Chooses the highest-resolution camera format the device offers so the RGB
    /// record carries as much disk/label detail as possible.
    ///
    /// For LiDAR modes the dedicated high-resolution-frame format is excluded: on
    /// current hardware it disables synchronized scene depth, and keeping depth and
    /// color registered to a single frame is worth more to the solvers than extra
    /// RGB pixels. Photogrammetry-only capture has no depth to preserve, so it takes
    /// the largest format available. Returns `nil` to leave the ARKit default in
    /// place when no better format exists.
    private func highestResolutionVideoFormat(usesLiDAR: Bool) -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let candidates: [ARConfiguration.VideoFormat]
        if usesLiDAR,
           let hiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            candidates = formats.filter { $0.imageResolution != hiRes.imageResolution }
        } else {
            candidates = formats
        }
        return candidates.max {
            $0.imageResolution.width * $0.imageResolution.height
                < $1.imageResolution.width * $1.imageResolution.height
        }
    }

    func resetForNewCapture() {
        pause()
        hasStartedTracking = false
        motionStopped = false
        motionGate = CaptureMotionGate()
        invalidateMotionRecovery()
        motionFusionHeld = false
        trustedMeshSnapshot = nil
        accumulatedMeshFrozen = false
        savedStillSectors = []
        sampledSectors = []
        lastAutomaticSampleTimestamp = nil
        stableSince = nil
        scoredPosition = nil
        motionReference = []
        motionBounds = nil
        motionSegmentID = UUID()
        motionMessage = "Motion check not armed. Set the head region and freeze a stable reference."
        lastSubmittedTimestamp = -1
        observations.removeAll()
        meshAnchors.removeAll()
        worldInvalidated = false
        captureSafetyMessage = nil
        activeSettingsSummary = nil
        storageMessage = nil
        lastStorageState = nil
    }

    func lockArchivedCapture() {
        pause()
        worldInvalidated = true
        activeSettingsSummary = nil
        storageMessage = nil
        captureSafetyMessage = "Reopened captures are review-only. Start a new session to acquire a new coordinate world."
    }

    func lockEndedCapture() {
        pause()
        worldInvalidated = true
        captureSafetyMessage = nil
        status.message = "Session ended. Start a new session to collect more data."
    }

    func invalidatePendingCaptures() {
        captureGeneration = UUID()
        bestFrame = nil
    }

    func pause() {
        storageMonitor?.cancel()
        storageMonitor = nil
        captureGeneration = UUID()
        bestFrame = nil
        stableSince = nil
        scoredPosition = nil
        arView?.session.pause()
        status.isRunning = false
        status.message = "Scan paused."
    }

    func sampleCurrentFrame(
        artifactStore: CaptureArtifactStore, session: ScanSession,
        includeCompressedImage: Bool = false, useBestFrame: Bool = false, minimumGap: Double = 0.75,
        recaptureTargetLabel: String? = nil
    ) throws -> CaptureObservation? {
        guard status.isRunning, !worldInvalidated, let current = arView?.session.currentFrame else {
            status.message = "No AR frame is available yet."
            return nil
        }

        let candidate = bestFrame
        bestFrame = nil
        let useCandidate = useBestFrame && selectBestFrames && candidate.map {
            current.timestamp - $0.frame.timestamp >= 0 && current.timestamp - $0.frame.timestamp <= 0.9
                && $0.frame.timestamp > lastSubmittedTimestamp
        } == true
        let frame = useCandidate ? candidate!.frame : current
        guard frame.timestamp > lastSubmittedTimestamp else { return nil }
        if useBestFrame && adaptiveSampling {
            let novelty = poseNovelty(frame.camera.transform)
            let elapsed = lastAutomaticSampleTimestamp.map { frame.timestamp - $0 } ?? max(3, minimumGap)
            guard AdaptiveCapturePolicy.shouldSample(elapsed: elapsed, minimumGap: minimumGap,
                sharpness: imageQuality(frame.capturedImage).sharpness,
                translation: novelty.translation ?? 1, rotationDegrees: novelty.rotationDegrees ?? 180,
                newSector: !sampledSectors.contains(coverageSector(frame.camera.transform))) else {
                status.message = "Waiting for a sharp, useful view. Move slowly; manual capture remains available."
                return nil
            }
        }
        let wantsPair = useBestFrame && preserveComparisonFrames && current.timestamp > frame.timestamp
        guard admitFrames(wantsPair ? 2 : 1) else { return nil }
        let saved = try saveFrame(frame, orientation: useCandidate ? candidate!.orientation : storedImageOrientation(),
                                  artifactStore: artifactStore, session: session,
                                  includeCompressedImage: includeCompressedImage,
                                  source: useCandidate ? "best-window-frame" : "current-frame", recaptureTargetLabel: recaptureTargetLabel)
        if useBestFrame {
            lastAutomaticSampleTimestamp = frame.timestamp
            sampledSectors.insert(coverageSector(frame.camera.transform))
        }
        if wantsPair && !motionStopped {
            let cadence = try saveFrame(current, orientation: storedImageOrientation(), artifactStore: artifactStore,
                                        session: session, includeCompressedImage: includeCompressedImage,
                                        source: "cadence-comparison")
            eventHandler?(AcquisitionEvent(kind: "frame-comparison-pair", message: "Selected and cadence frames queued; check their save outcomes.",
                details: ["selectedObservationID": saved.id.uuidString, "cadenceObservationID": cadence.id.uuidString]))
        } else if !wantsPair && useBestFrame && preserveComparisonFrames {
            eventHandler?(AcquisitionEvent(kind: "frame-comparison-pair", message: "Same frame selected; queued once.",
                details: ["selectedObservationID": saved.id.uuidString, "cadenceObservationID": saved.id.uuidString]))
        }
        return saved
    }

    private func admitFrames(_ count: Int) -> Bool {
        guard frameWriter.canAccept(count) else {
            status.message = "Capture writer busy; candidate skipped."
            eventHandler?(AcquisitionEvent(kind: "capture-queue-full", message: status.message,
                details: ["pendingWrites": String(frameWriter.pendingCount), "droppedCandidates": String(count)]))
            return false
        }
        return true
    }

    /// Returns reserved identity/calibration only. The completion handler publishes
    /// the saved observation after all artifacts and its checkpoint are durable.
    private func saveFrame(_ frame: ARFrame, orientation: String,
                           artifactStore: CaptureArtifactStore, session: ScanSession,
                           includeCompressedImage: Bool, source: String, guidedView: CaptureGuidedView? = nil,
                           recaptureTargetLabel: String? = nil) throws -> CaptureObservation {
        guard checkStorage(artifactStore.availableCapacityBytes) else { throw CaptureFrameWriteError.storageUnavailable }
        var observation = makeObservation(from: frame)
        observation.quality?.captureSource = source
        observation.quality?.guidedView = guidedView
        observation.quality?.recaptureTargetLabel = recaptureTargetLabel
        let motion = assessMotion(frame, bounds: session.headBoundingBox)
        observation.quality?.motionAssessment = motion
        applyMotionCorrection(to: &observation)
        observation.imageOrientation = orientation
        motionMessage = switch motion.state {
        case .unassessed: "Motion check not armed. Freeze a stable head reference."
        case .insufficientEvidence: "Rechecking reference… Recording continues; model updates are held."
        case .consistent: captureNetPose != nil ? "Tracking net. Recording and model updates continue." : (motionRecovery.transform == nil ? "Depth consistent with frozen reference (advisory only)." : "Realigned to reference. Recording and model updates continue.")
        case .suspected: "Reacquiring head/net… Recording continues while alignment is checked."
        }
        observation.capturedAt = Date(timeIntervalSinceNow: frame.timestamp - ProcessInfo.processInfo.systemUptime)
        let copyStarted = ProcessInfo.processInfo.systemUptime
        let depth = session.captureMode.usesLiDAR ? frame.sceneDepth : nil
        let buffers = try OwnedCaptureBuffers(image: captureBuffers.copy(frame.capturedImage),
            depth: depth.map { try captureBuffers.copy($0.depthMap) },
            confidence: depth?.confidenceMap.map { try captureBuffers.copy($0) })
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        let copyMs = (enqueuedAt - copyStarted) * 1_000
        let initial = observation
        let sessionID = session.id
        // The worker needs capture identity only, not a growing copy of all observations.
        var destination = ScanSession.newSession(layout: .headMeshOnly)
        destination.id = sessionID
        let writeSession = destination
        let accepted = frameWriter.submit(operation: {
            try CaptureFrameWriter.write(buffers: buffers, observation: initial, store: artifactStore,
                session: writeSession, includeCompressedImage: includeCompressedImage, enqueuedAt: enqueuedAt)
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let written):
                if source == "high-resolution-still", (initial.quality?.sharpnessScore ?? 0) >= 0.025,
                   initial.quality?.motionAssessment?.state != .suspected,
                   initial.quality?.motionAssessment?.state != .insufficientEvidence,
                   let sector = initial.quality?.coverageSector { self.savedStillSectors.insert(sector) }
                self.observations.append(written.observation)
                self.observations.sort { $0.capturedAt < $1.capturedAt }
                self.status.sampledFrameCount = self.observations.count
                self.status.lastSampledAt = self.observations.last?.capturedAt
                var details = written.timings
                details["observationID"] = initial.id.uuidString
                details["frameTimestamp"] = String(initial.quality?.arFrameTimestamp ?? 0)
                details["width"] = String(initial.imageResolution.width)
                details["height"] = String(initial.imageResolution.height)
                details["hasDepth"] = String(written.observation.rawDepthFilename != nil)
                details["bufferCopyDurationMs"] = String(copyMs)
                self.eventHandler?(AcquisitionEvent(kind: "capture-frame-selected", message: source, details: details))
                self.eventHandler?(AcquisitionEvent(kind: "sample-saved", message: "Artifacts and observation checkpoint committed.", details: details))
                self.observationSavedHandler?(sessionID, .success(written.observation))
            case .failure(let error):
                self.pause()
                self.eventHandler?(AcquisitionEvent(kind: "sample-save-failed", message: error.localizedDescription,
                    details: ["observationID": initial.id.uuidString, "source": source]))
                self.observationSavedHandler?(sessionID, .failure(error))
            }
        })
        precondition(accepted, "Admission and submission must remain on the main actor without suspension")
        bestFrame = nil
        if frame.timestamp >= lastSubmittedTimestamp {
            lastSubmittedTimestamp = frame.timestamp
            lastSampledTransform = frame.camera.transform
        }
        status.message = "Frame queued for saving."
        eventHandler?(AcquisitionEvent(kind: "capture-frame-queued", message: source,
            details: ["observationID": observation.id.uuidString, "pendingWrites": String(frameWriter.pendingCount),
                      "capacity": String(frameWriter.capacity), "bufferCopyDurationMs": String(copyMs)]))
        return observation
    }

    func captureStill(artifactStore: CaptureArtifactStore, session: ScanSession,
                      includeCompressedImage: Bool, automatic: Bool = false, guidedView: CaptureGuidedView? = nil,
                      recaptureTargetLabel: String? = nil) async throws -> CaptureObservation? {
        guard status.isRunning, highResolutionStills, !isCapturingStill,
              let arSession = arView?.session,
              let format = arSession.configuration?.videoFormat,
              format.isRecommendedForHighResolutionFrameCapturing else {
            status.message = "High-resolution stills need a supported format; enable the experiment before starting capture."
            return nil
        }
        guard ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else {
            status.message = "Still capture skipped while the device is hot."
            return nil
        }
        if automatic && !automaticStillReady { return nil }
        isCapturingStill = true
        defer { isCapturingStill = false }
        let generation = captureGeneration
        let orientation = storedImageOrientation()
        let requestedAt = Date()
        let frame: ARFrame = try await withCheckedThrowingContinuation { continuation in
            arSession.captureHighResolutionFrame { frame, error in
                if let error { continuation.resume(throwing: error) }
                else if let frame { continuation.resume(returning: frame) }
                else { continuation.resume(throwing: NSError(domain: "MANTA", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No high-resolution frame returned."])) }
            }
        }
        guard !Task.isCancelled, generation == captureGeneration, status.isRunning,
              orientation == storedImageOrientation() else { return nil }
        eventHandler?(AcquisitionEvent(kind: "still-delivered", message: "High-resolution request completed.",
            details: ["latencySeconds": String(Date().timeIntervalSince(requestedAt)),
                      "thermalState": String(ProcessInfo.processInfo.thermalState.rawValue)]))
        if automatic && imageQuality(frame.capturedImage).sharpness < 0.025 {
            eventHandler?(AcquisitionEvent(kind: "automatic-still-rejected", message: "Delivered still failed sharpness gate; retry the view."))
            return nil
        }
        guard admitFrames(1) else { return nil }
        return try saveFrame(frame, orientation: orientation, artifactStore: artifactStore,
                             session: session, includeCompressedImage: includeCompressedImage,
                             source: "high-resolution-still", guidedView: guidedView,
                             recaptureTargetLabel: recaptureTargetLabel)
    }

    func checkLens() async {
        guard !isCheckingLens, let frame = arView?.session.currentFrame else { return }
        isCheckingLens = true
        defer { isCheckingLens = false }
        let generation = captureGeneration
        do {
            let observation = try await DetectLensSmudgeRequest(.revision1).perform(on: frame.capturedImage)
            guard generation == captureGeneration else { return }
            let confidence = observation.confidence
            lensMessage = confidence >= 0.5
                ? "Possible lens smudge. Inspect and clean the lens if needed."
                : "No strong smudge indication; inspect image quality too."
            eventHandler?(AcquisitionEvent(kind: "lens-smudge-check", message: lensMessage,
                details: ["confidence": String(confidence), "advisoryThreshold": "0.5",
                          "revision": "1", "frameTimestamp": String(frame.timestamp)]))
        } catch {
            guard generation == captureGeneration else { return }
            lensMessage = "Lens check unavailable: \(error.localizedDescription)"
            eventHandler?(AcquisitionEvent(kind: "lens-smudge-unavailable", message: lensMessage))
        }
    }

    /// Retain at most one candidate ARFrame and score at most 7 frames/second.
    private func considerFrame(_ frame: ARFrame) {
        guard status.isRunning, (selectBestFrames || adaptiveSampling || highResolutionStills),
              case .normal = frame.camera.trackingState else { stableSince = nil; return }
        guard frame.timestamp - scoredTimestamp >= 0.15 else { return }
        let transform = frame.camera.transform
        let rotation = simd_quatf(simd_float3x3(transform.columns.0.xyz, transform.columns.1.xyz, transform.columns.2.xyz))
        let dt = frame.timestamp - scoredTimestamp
        let speed = scoredRotation.map { Double(2 * acos(min(1, abs(simd_dot($0.vector, rotation.vector))))) * 180 / .pi / max(dt, 0.001) } ?? 0
        let position = transform.columns.3.xyz
        let translationSpeed = scoredPosition.map { Double(simd_distance($0, position)) / max(dt, 0.001) } ?? .infinity
        if dt > 0.4 || speed > 5 || translationSpeed > 0.02 { stableSince = nil }
        else if stableSince == nil { stableSince = frame.timestamp }
        scoredPosition = position
        scoredRotation = rotation
        scoredTimestamp = frame.timestamp
        let novelty = poseNovelty(transform)
        let sharpness = imageQuality(frame.capturedImage).sharpness
        latestSharpness = sharpness
        latestSector = coverageSector(transform)
        stillGuidance = savedStillSectors.contains(latestSector)
            ? "Sharp still saved for this camera direction. Move to another view or take a manual photo."
            : (automaticStillReady ? "Ready for a label photo. Keep the participant still."
               : "Hold the iPad steady for a label photo; keep the participant still.")
        guard selectBestFrames, !requiresDepth || frame.sceneDepth != nil else { return }
        let score = CaptureFrameScoring.score(sharpness: sharpness, angularSpeedDegrees: speed,
            translationMeters: novelty.translation ?? 0.03, rotationDegrees: novelty.rotationDegrees ?? 10)
        if bestFrame == nil || frame.timestamp - bestFrame!.frame.timestamp > 0.9 || score > bestFrame!.score {
            bestFrame = (frame, storedImageOrientation(), score)
        }
    }

    /// Ray-casts a point in the AR view (view coordinates) against the scanned
    /// surface and returns the hit in world coordinates. Used to place
    /// nasion/LPA/RPA fiducials by tapping the live scan.
    ///
    /// The reconstructed LiDAR mesh is tried first: for a curved head that hits
    /// the actual scalp, whereas ARKit's estimated-plane fit only approximates it.
    /// If no mesh has been built yet, it falls back to an estimated-plane raycast
    /// so early taps still land somewhere sensible.
    func raycastToWorld(viewPoint: CGPoint) -> FiducialRaycastResult? {
        guard !motionFusionHeld, !accumulatedMeshFrozen, let arView else { return nil }

        if let (origin, direction) = arView.ray(through: viewPoint) {
            let mesh = fullMeshSnapshot()
            if let hit = MeshRaycaster.firstHit(
                origin: origin, direction: direction,
                vertices: mesh.vertices, triangleIndices: mesh.triangleIndices) {
                return FiducialRaycastResult(
                    point: hit, rayOrigin: origin, rayDirection: direction,
                    hitMethod: "lidar-mesh-raycast", observationID: observations.last?.id)
            }
        }

        if let query = arView.makeRaycastQuery(from: viewPoint, allowing: .estimatedPlane, alignment: .any),
           let result = arView.session.raycast(query).first {
            let t = result.worldTransform.columns.3
            return FiducialRaycastResult(
                point: SIMD3<Float>(t.x, t.y, t.z), rayOrigin: nil, rayDirection: nil,
                hitMethod: "estimated-plane-raycast", observationID: observations.last?.id)
        }
        return nil
    }

    /// Nearest hit of an arbitrary world-space ray against the accumulated mesh.
    /// Used by the offline (cameras-off) model view, where the ray comes from the
    /// 3D view's virtual camera instead of the ARKit camera.
    func raycastMesh(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        let mesh = fullMeshSnapshot()
        return MeshRaycaster.firstHit(
            origin: origin, direction: direction,
            vertices: mesh.vertices, triangleIndices: mesh.triangleIndices)
    }

    /// Current device (camera-to-world) transform, for driving the Live Model's
    /// camera so the head rotates to match the operator's physical viewpoint.
    /// Nil when no frame is available (session not running yet).
    func currentCameraTransform() -> simd_float4x4? {
        guard let pose = arView?.session.currentFrame?.camera.transform else { return nil }
        return (lastNetTransform ?? motionRecovery.transform ?? matrix_identity_float4x4) * pose
    }

    /// World-space point cloud of the accumulated LiDAR reconstruction mesh.
    /// Vertices are transformed by each anchor's pose and roughly capped to `maxPoints`
    /// by subsampling so downstream ICP stays tractable.
    func meshWorldPoints(maxPoints: Int = 6000) -> [SIMD3<Float>] {
        if accumulatedMeshFrozen { return Array((trustedMeshSnapshot?.vertices ?? []).prefix(max(0, maxPoints))) }
        let anchors = Array(meshAnchors.values)
        guard !anchors.isEmpty else { return [] }

        let totalVertices = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        guard totalVertices > 0 else { return [] }
        let stride = max(1, totalVertices / max(1, maxPoints))

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(min(totalVertices, maxPoints) + anchors.count)

        var globalIndex = 0
        for anchor in anchors {
            let vertices = anchor.geometry.vertices
            let buffer = vertices.buffer.contents()
            let transform = anchor.transform

            for i in 0..<vertices.count {
                defer { globalIndex += 1 }
                guard globalIndex % stride == 0 else { continue }

                let pointer = buffer
                    .advanced(by: vertices.offset + i * vertices.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self)
                let local = pointer.pointee
                let world = transform * SIMD4<Float>(local.0, local.1, local.2, 1)
                points.append(SIMD3<Float>(world.x, world.y, world.z))
            }
        }

        return points
    }

    /// Complete accumulated mesh evidence for persistence and deferred solving.
    /// Vertices are transformed into ARKit world coordinates and face indices
    /// are rebased into the combined vertex array.
    func fullMeshSnapshot() -> LiDARMeshSnapshot {
        if accumulatedMeshFrozen { return trustedMeshSnapshot ?? LiDARMeshSnapshot(vertices: [], triangleIndices: []) }
        var vertices = [SIMD3<Float>]()
        var triangles = [UInt32]()
        for anchor in meshAnchors.values {
            let geometry = anchor.geometry
            let baseIndex = UInt32(vertices.count)
            let source = geometry.vertices
            let buffer = source.buffer.contents()
            for index in 0..<source.count {
                let pointer = buffer.advanced(by: source.offset + index * source.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self)
                let local = pointer.pointee
                let world = anchor.transform * SIMD4<Float>(local.0, local.1, local.2, 1)
                vertices.append(SIMD3(world.x, world.y, world.z))
            }
            let faces = geometry.faces
            guard faces.indexCountPerPrimitive == 3 else { continue }
            let faceBuffer = faces.buffer.contents()
            for face in 0..<faces.count {
                for corner in 0..<3 {
                    let offset = (face * 3 + corner) * faces.bytesPerIndex
                    let value: UInt32
                    if faces.bytesPerIndex == 2 {
                        value = UInt32(faceBuffer.advanced(by: offset).load(as: UInt16.self))
                    } else {
                        value = faceBuffer.advanced(by: offset).load(as: UInt32.self)
                    }
                    triangles.append(baseIndex + value)
                }
            }
        }
        return LiDARMeshSnapshot(vertices: vertices, triangleIndices: triangles)
    }

    private func updateStatus(from frame: ARFrame) {
        status.frameCount += 1
        let summary = trackingSummary(frame.camera.trackingState)
        status.trackingSummary = summary
        status.hasSceneDepth = frame.sceneDepth != nil
        if highResolutionStills && requiresDepth && frame.sceneDepth == nil {
            captureSafetyMessage = "Experimental format has no scene depth. Keep this RGB evidence, then start a NEW session with high-resolution stills off for the depth pass."
        } else if highResolutionStills && summary != "Normal" {
            captureSafetyMessage = "Tracking is limited. Automatic stills wait for normal tracking; if it persists, finish this pass and start a new baseline session."
        }
        status.meshAnchorCount = meshAnchors.count
        if !hasReportedFirstFrame {
            hasReportedFirstFrame = true
            reportFirstFrame(frame)
        }
        if summary != lastReportedTrackingSummary {
            eventHandler?(AcquisitionEvent(
                kind: "tracking-state-changed", message: summary,
                details: ["worldMappingStatus": worldMappingSummary(frame.worldMappingStatus)]))
            lastReportedTrackingSummary = summary
        }
    }

    /// Probe 2 (delivered): records what the first real frame actually carried, so
    /// it can be compared to `video-format-selected`. A resolution that differs from
    /// the request means ARKit fell back to another format; absent scene depth in a
    /// LiDAR mode means the depth-fusion assumption is broken for this session.
    private func reportFirstFrame(_ frame: ARFrame) {
        let resolution = frame.camera.imageResolution
        var details = [
            "actualImageWidth": String(Int(resolution.width)),
            "actualImageHeight": String(Int(resolution.height)),
            "sceneDepthPresent": String(frame.sceneDepth != nil),
            "worldMappingStatus": worldMappingSummary(frame.worldMappingStatus)
        ]
        if let depthMap = frame.sceneDepth?.depthMap {
            details["depthWidth"] = String(CVPixelBufferGetWidth(depthMap))
            details["depthHeight"] = String(CVPixelBufferGetHeight(depthMap))
        }
        eventHandler?(AcquisitionEvent(
            kind: "first-frame-observed",
            message: "Delivered \(Int(resolution.width))x\(Int(resolution.height)) frame.",
            details: details))
    }

    private func makeObservation(from frame: ARFrame) -> CaptureObservation {
        let resolution = frame.camera.imageResolution
        let imageMetrics = imageQuality(frame.capturedImage)
        let novelty = poseNovelty(frame.camera.transform)
        var warnings = [String]()
        if imageMetrics.sharpness < 0.025 { warnings.append("possible-motion-blur") }
        if imageMetrics.darkFraction > 0.25 { warnings.append("underexposed") }
        if imageMetrics.brightFraction > 0.25 { warnings.append("overexposed-or-glare") }
        if let translation = novelty.translation, let rotation = novelty.rotationDegrees,
           translation < 0.02, rotation < 5 {
            warnings.append("near-duplicate-view")
        }
        let light = frame.lightEstimate

        return CaptureObservation(
            capturedAt: Date(),
            cameraTransform: frame.camera.transform.flattened,
            cameraIntrinsics: frame.camera.intrinsics.flattened,
            imageResolution: ImageResolution(width: Int(resolution.width), height: Int(resolution.height)),
            hasSceneDepth: frame.sceneDepth != nil,
            meshAnchorCount: meshAnchors.count,
            trackingSummary: trackingSummary(frame.camera.trackingState),
            cameraSnapshotFilename: nil,
            imageOrientation: storedImageOrientation(),
            depthSnapshotFilename: nil,
            rawDepthFilename: nil,
            rawDepthFormat: nil,
            rawConfidenceFilename: nil,
            rawConfidenceFormat: nil,
            confidenceSummary: nil,
            depthSummary: nil,
            quality: CaptureQualityMetrics(
                arFrameTimestamp: frame.timestamp,
                worldMappingStatus: worldMappingSummary(frame.worldMappingStatus),
                ambientIntensity: light.map { Double($0.ambientIntensity) },
                ambientColorTemperature: light.map { Double($0.ambientColorTemperature) },
                meanLuminance: imageMetrics.mean,
                darkPixelFraction: imageMetrics.darkFraction,
                brightPixelFraction: imageMetrics.brightFraction,
                sharpnessScore: imageMetrics.sharpness,
                translationFromPreviousSampleMeters: novelty.translation,
                rotationFromPreviousSampleDegrees: novelty.rotationDegrees,
                coverageSector: coverageSector(frame.camera.transform),
                warnings: warnings)
        )
    }

    private func poseNovelty(_ transform: simd_float4x4) -> (translation: Double?, rotationDegrees: Double?) {
        guard let previous = lastSampledTransform else { return (nil, nil) }
        let translation = simd_distance(previous.columns.3.xyz, transform.columns.3.xyz)
        let previousMatrix = simd_float3x3(
            previous.columns.0.xyz, previous.columns.1.xyz, previous.columns.2.xyz)
        let rotationMatrix = simd_float3x3(
            transform.columns.0.xyz, transform.columns.1.xyz, transform.columns.2.xyz)
        let previousRotation = simd_quatf(previousMatrix)
        let rotation = simd_quatf(rotationMatrix)
        let dot = min(1, abs(simd_dot(previousRotation.vector, rotation.vector)))
        let radians: Float = 2 * acos(dot)
        let degrees = radians * 180 / Float.pi
        return (Double(translation), Double(degrees))
    }

    private func coverageSector(_ transform: simd_float4x4) -> String {
        let direction = simd_normalize(-transform.columns.2.xyz)
        var azimuth = atan2(direction.x, -direction.z) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        let azimuthBin = Int((azimuth + 22.5) / 45) % 8
        let elevation = asin(max(-1, min(1, direction.y))) * 180 / .pi
        let elevationBin = elevation > 20 ? "upper" : elevation < -20 ? "lower" : "level"
        return "azimuth-\(azimuthBin)-\(elevationBin)"
    }

    /// ARKit supplies sensor-native landscape pixels. Record the EXIF transform
    /// consumers must apply to display those pixels in the interface orientation.
    private func storedImageOrientation() -> String {
        Self.imageOrientation(for: arView?.window?.windowScene?.interfaceOrientation)
    }

    static func imageOrientation(for interfaceOrientation: UIInterfaceOrientation?) -> String {
        // UIInterfaceOrientation's landscape directions are opposite to
        // UIDeviceOrientation's. Sensor-native rear-camera pixels are upright
        // in interface landscapeRight, not landscapeLeft.
        switch interfaceOrientation {
        case .portrait: "right"
        case .portraitUpsideDown: "left"
        case .landscapeLeft: "down"
        case .landscapeRight: "up"
        default: "up"
        }
    }

    private func imageQuality(_ pixelBuffer: CVPixelBuffer) -> (
        mean: Double, darkFraction: Double, brightFraction: Double, sharpness: Double
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let plane = CVPixelBufferGetPlaneCount(pixelBuffer) > 0 ? 0 : -1
        guard let base = plane >= 0
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBaseAddress(pixelBuffer) else { return (0, 1, 0, 0) }
        let width = plane >= 0 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer)
        let height = plane >= 0 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = plane >= 0
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, dark = 0, bright = 0, count = 0
        var gradient = 0
        let step = 8
        for y in stride(from: step, to: height, by: step) {
            for x in stride(from: step, to: width, by: step) {
                let value = Int(pixels[y * bytesPerRow + x])
                sum += value; count += 1
                if value <= 20 { dark += 1 }
                if value >= 235 { bright += 1 }
                gradient += abs(value - Int(pixels[y * bytesPerRow + x - step]))
                gradient += abs(value - Int(pixels[(y - step) * bytesPerRow + x]))
            }
        }
        guard count > 0 else { return (0, 1, 0, 0) }
        return (
            Double(sum) / Double(count) / 255,
            Double(dark) / Double(count), Double(bright) / Double(count),
            Double(gradient) / Double(count * 2) / 255)
    }

    private func worldMappingSummary(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: "not-available"
        case .limited: "limited"
        case .extending: "extending"
        case .mapped: "mapped"
        @unknown default: "unknown"
        }
    }

    private func trackingSummary(_ trackingState: ARCamera.TrackingState) -> String {
        switch trackingState {
        case .normal:
            return "Normal"
        case .notAvailable:
            return "Not available"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                return "Limited: excessive motion"
            case .insufficientFeatures:
                return "Limited: insufficient features"
            case .initializing:
                return "Limited: initializing"
            case .relocalizing:
                return "Limited: relocalizing"
            @unknown default:
                return "Limited"
            }
        }
    }
}

nonisolated struct LiDARMeshSnapshot: Sendable {
    var vertices: [SIMD3<Float>]
    var triangleIndices: [UInt32]

    func cropped(to bounds: HeadBoundingBox) -> LiDARMeshSnapshot {
        let center = SIMD3<Float>(
            Float(bounds.center.x), Float(bounds.center.y), Float(bounds.center.z))
        let half = SIMD3<Float>(
            Float(bounds.widthMeters / 2), Float(bounds.heightMeters / 2),
            Float(bounds.depthMeters / 2))
        func isInside(_ index: UInt32) -> Bool {
            guard Int(index) < vertices.count else { return false }
            let delta = abs(vertices[Int(index)] - center)
            return delta.x <= half.x && delta.y <= half.y && delta.z <= half.z
        }

        var remap = [UInt32: UInt32]()
        var croppedVertices = [SIMD3<Float>]()
        var croppedIndices = [UInt32]()
        for face in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            let source = [triangleIndices[face], triangleIndices[face + 1], triangleIndices[face + 2]]
            guard source.allSatisfy(isInside) else { continue }
            for index in source {
                if let mapped = remap[index] {
                    croppedIndices.append(mapped)
                } else {
                    let mapped = UInt32(croppedVertices.count)
                    remap[index] = mapped
                    croppedVertices.append(vertices[Int(index)])
                    croppedIndices.append(mapped)
                }
            }
        }
        return LiDARMeshSnapshot(vertices: croppedVertices, triangleIndices: croppedIndices)
    }
}

extension ARScanViewModel: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            self.updateStatus(from: frame)
            self.considerFrame(frame)
            self.updateContinuousNetTracking(frame)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            for case let anchor as ARMeshAnchor in anchors {
                self.meshAnchors[anchor.identifier] = anchor
            }
            self.status.meshAnchorCount = self.meshAnchors.count
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            for case let anchor as ARMeshAnchor in anchors {
                self.meshAnchors[anchor.identifier] = anchor
            }
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                self.meshAnchors.removeValue(forKey: anchor.identifier)
            }
            self.status.meshAnchorCount = self.meshAnchors.count
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.pause()
            self.worldInvalidated = true
            self.captureSafetyMessage = "AR failed. Start a new capture session; existing data remains available."
            self.eventHandler?(AcquisitionEvent(
                kind: "ar-session-failed", message: error.localizedDescription))
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.pause()
            self.worldInvalidated = true
            self.captureSafetyMessage = "AR was interrupted. Start a new session rather than mixing uncertain coordinate worlds."
            self.eventHandler?(AcquisitionEvent(
                kind: "ar-session-interrupted", message: "AR session was interrupted."))
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.eventHandler?(AcquisitionEvent(
                kind: "ar-session-interruption-ended", message: "AR session interruption ended."))
        }
    }
}

private extension simd_float4x4 {
    var flattened: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w
        ]
    }
}

private extension simd_float3x3 {
    var flattened: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z,
            columns.1.x, columns.1.y, columns.1.z,
            columns.2.x, columns.2.y, columns.2.z
        ]
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
#else
@MainActor
final class ARScanViewModel: ObservableObject {
    @Published var status = LiveScanStatus(message: "ARKit is unavailable in this build.")
    @Published var observations: [CaptureObservation] = []
    var eventHandler: ((AcquisitionEvent) -> Void)?

    func start(captureMode: CaptureMode = .both) {}
    func pause() {}
    func sampleCurrentFrame(
        artifactStore: CaptureArtifactStore, session: ScanSession,
        includeCompressedImage: Bool = false
    ) throws -> CaptureObservation? { nil }
    func meshWorldPoints(maxPoints: Int = 6000) -> [SIMD3<Float>] { [] }
    func raycastToWorld(viewPoint: CGPoint) -> FiducialRaycastResult? { nil }
    func raycastMesh(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? { nil }
    func fullMeshSnapshot() -> LiDARMeshSnapshot { LiDARMeshSnapshot(vertices: [], triangleIndices: []) }
    func currentCameraTransform() -> simd_float4x4? { nil }
}
#endif
