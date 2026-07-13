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

@MainActor
final class ScanSessionViewModel: ObservableObject {
    @Published var session = ScanSession.newSession(layout: .headMeshOnly)
    @Published var availableLayouts: [ElectrodeLayout] = [.headMeshOnly, .fallback128]
    @Published var selectedLayoutName = ElectrodeLayout.headMeshOnly.name
    @Published var scanViewModel = ARScanViewModel()
    @Published var selectedFormat: ElectrodeExportFormat = .csv
    @Published var exportPreview = ""
    @Published var isDetecting = false
    @Published var liveDetectionEnabled = false
    /// Debug acquisition option used to compare the primary lossless PNG with a
    /// compressed HEIC/JPEG encoding of the exact same sampled frame.
    @Published var captureCompressedImageReferences = false
    @Published var isLiveDetecting = false
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
    @Published var isExporting = false
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
    private let photogrammetryService: PhotogrammetryReconstructing
    private var autoSamplingTask: Task<Void, Never>?
    private var liveDetectionTask: Task<Void, Never>?
    private var pendingLiveObservation: CaptureObservation?
    private var liveRawDetections: [LabeledDetection] = []
    private var liveProcessedFrameIDs: [UUID] = []
    private var liveDetectionStartedAt: Date?
    private var liveDetectionGeneration = UUID()

    /// Finalized results take precedence; provisional live-only labels and
    /// template predictions remain visible until finalization resolves them.
    var visualizedElectrodes: [ElectrodeAnnotation] {
        var byLabel = Dictionary(uniqueKeysWithValues: liveElectrodes.map { ($0.label, $0) })
        for electrode in session.electrodes { byLabel[electrode.label] = electrode }
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
        photogrammetryService: PhotogrammetryReconstructing? = nil
    ) {
        self.detectionPipeline = detectionPipeline ?? ElectrodeDetectionFactory.makeDefaultPipeline()
        self.photogrammetryService = photogrammetryService ?? PhotogrammetryReconstructionService()
        artifactStore = try? CaptureArtifactStore()

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

        refreshExportPreview()
        refreshSessions()
        scanViewModel.eventHandler = { [weak self] event in
            self?.recordAcquisitionEvent(event)
        }
    }

    // MARK: - Subject library

    /// Reloads the list of persisted sessions, newest first.
    func refreshSessions() {
        sessionSummaries = artifactStore?.listSessionSummaries() ?? []
    }

    /// Starts a fresh, unsaved session. It is written to disk on the first
    /// meaningful action (sampling a frame, detecting, or renaming), so empty
    /// sessions don't clutter the library.
    func startNewSession(subjectLabel: String? = nil) {
        stopAutoSampling()
        resetLiveDetection()
        fiducialPlacementKind = nil
        modelFiducialPlacementKind = nil
        isHeadBoundsPlacementActive = false
        cachedMeshSnapshot = nil
        let layout = availableLayouts.first(where: { $0.name == selectedLayoutName }) ?? session.layout
        var newSession = ScanSession.newSession(layout: layout)
        newSession.subjectLabel = subjectLabel
        newSession.name = newSession.displayName
        newSession.acquisitionContext = AcquisitionContext(
            netModel: layout.hasElectrodeNet ? layout.name : nil)
        session = newSession
        resetLiveMetricDepthFusion()
        statusMessage = "New session \(session.displayName)."
        refreshExportPreview()
    }

    /// Reopens a persisted session for review or reprocessing.
    func openSession(id: UUID) {
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }
        do {
            stopAutoSampling()
            resetLiveDetection()
            fiducialPlacementKind = nil
            modelFiducialPlacementKind = nil
            isHeadBoundsPlacementActive = false
            cachedMeshSnapshot = nil
            let loaded = try artifactStore.loadSession(id: id)
            session = loaded
            resetLiveMetricDepthFusion()
            if availableLayouts.contains(where: { $0.name == loaded.layout.name }) {
                selectedLayoutName = loaded.layout.name
            }
            liveDetectionEnabled = loaded.layout.hasElectrodeNet
            statusMessage = "Opened \(loaded.displayName)."
            refreshExportPreview()
        } catch {
            statusMessage = "Could not open session: \(error.localizedDescription)"
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
        try? artifactStore?.deleteSession(id: id)
        if id == session.id {
            startNewSession()
        }
        refreshSessions()
    }

    /// Finalizes an immutable `.manta` snapshot and presents it in the share sheet.
    func exportSession(id: UUID) {
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }
        if id == session.id {
            persistCurrentLiDARMesh()
            persistSession()
        }
        statusMessage = "Preparing session bundle…"
        do {
            if id == session.id {
                recordAcquisitionEvent(AcquisitionEvent(
                    kind: "export-started", message: "Preparing paired raw and solved snapshots."))
            }
            let result = try artifactStore.exportSessionBundles(id: id)
            if id == session.id {
                session.lastRawExportedBundleID = result.raw.bundleID
                session.lastExportedBundleID = result.solved.bundleID
                try artifactStore.writeSession(session)
            } else {
                var exportedSession = try artifactStore.loadSession(id: id)
                exportedSession.lastRawExportedBundleID = result.raw.bundleID
                exportedSession.lastExportedBundleID = result.solved.bundleID
                try artifactStore.writeSession(exportedSession)
            }
            exportedBundle = ExportedBundle(urls: [result.raw.url, result.solved.url])
            statusMessage = "Raw + solved bundles ready · receipt \(result.receipt.status.rawValue)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Seals and shares only immutable acquisition evidence. This is the
    /// preferred hand-off when processing will happen later on iPad or macOS.
    func exportRawSession(id: UUID) {
        guard !isExporting else { return }
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }
        if id == session.id {
            persistCurrentLiDARMesh()
            persistSession()
            recordAcquisitionEvent(AcquisitionEvent(
                kind: "raw-export-started",
                message: "Preparing a raw acquisition snapshot for deferred solving."))
        }
        statusMessage = "Validating and sealing raw acquisition…"
        let startedAt = Date()
        isExporting = true
        exportProgress = 0
        exportStage = "Preparing acquisition"
        exportStartedAt = startedAt

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try artifactStore.exportRawSessionBundle(id: id) { [weak self] fraction, stage in
                        Task { @MainActor in
                            self?.exportProgress = fraction
                            self?.exportStage = stage
                        }
                    }
                }.value
                if id == session.id {
                    session.lastRawExportedBundleID = result.export.bundleID
                    try artifactStore.writeSession(session)
                } else {
                    var exportedSession = try artifactStore.loadSession(id: id)
                    exportedSession.lastRawExportedBundleID = result.export.bundleID
                    try artifactStore.writeSession(exportedSession)
                }
                exportedBundle = ExportedBundle(urls: [result.export.url])
                let elapsed = Date().timeIntervalSince(startedAt)
                statusMessage = String(
                    format: "Raw bundle ready in %.1f s · receipt %@.",
                    elapsed, result.receipt.status.rawValue)
                recordAcquisitionEvent(AcquisitionEvent(
                    kind: "raw-export-completed", message: "Raw acquisition snapshot is ready.",
                    details: [
                        "bundleID": result.export.bundleID.uuidString,
                        "durationSeconds": String(format: "%.3f", elapsed)
                    ]))
            } catch {
                statusMessage = "Raw export failed: \(error.localizedDescription)"
                recordAcquisitionEvent(AcquisitionEvent(
                    kind: "raw-export-failed", message: error.localizedDescription))
            }
            isExporting = false
            exportProgress = 0
            exportStage = ""
            exportStartedAt = nil
        }
    }

    /// Writes the current session to disk. Called after meaningful mutations.
    private func persistSession() {
        _ = try? artifactStore?.writeSession(session)
    }

    func updateAcquisitionContext(_ update: (inout AcquisitionContext) -> Void) {
        var context = session.acquisitionContext ?? AcquisitionContext(
            netModel: session.layout.hasElectrodeNet ? session.layout.name : nil)
        update(&context)
        session.acquisitionContext = context
        persistSession()
        _ = try? artifactStore?.writeAcquisitionContext(for: session)
    }

    func recordAppLifecycle(_ state: String) {
        guard scanViewModel.status.isRunning || !session.captureObservations.isEmpty else { return }
        recordAcquisitionEvent(AcquisitionEvent(
            kind: "app-lifecycle", message: state))
    }

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
        guard let layout = availableLayouts.first(where: { $0.name == name }) else {
            return
        }

        stopAutoSampling()
        resetLiveDetection()
        fiducialPlacementKind = nil
        modelFiducialPlacementKind = nil
        isHeadBoundsPlacementActive = false
        cachedMeshSnapshot = nil
        selectedLayoutName = name
        session = ScanSession.newSession(layout: layout)
        resetLiveMetricDepthFusion()
        session.acquisitionContext = AcquisitionContext(
            netModel: layout.hasElectrodeNet ? layout.name : nil)
        liveDetectionEnabled = layout.hasElectrodeNet
        statusMessage = layout.hasElectrodeNet
            ? "Ready to scan with \(layout.name)."
            : "Ready for head-mesh capture without an electrode net."
        refreshExportPreview()
    }

    func startLiveScan() {
        scanViewModel.start(captureMode: session.captureMode)
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

    func setCaptureMode(_ mode: CaptureMode) {
        session.captureMode = mode
        statusMessage = "Capture mode set to \(mode.rawValue)."
    }

    func runReconstruction() async {
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
        fiducialPlacementKind = firstUnplacedFiducialKind() ?? FiducialKind.allCases.first
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
        if let artifactStore {
            do {
                if let evidence = try scanViewModel.sampleCurrentFrame(
                    artifactStore: artifactStore, session: session,
                    includeCompressedImage: captureCompressedImageReferences
                ) {
                    session.captureObservations.append(evidence)
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
        session.headCroppedLidarMeshFilename = nil
        resetLiveMetricDepthFusion()
        persistSession()
        statusMessage = "Showing the full ARKit environment mesh."
    }

    func updateHeadBoundingBox(_ update: (inout HeadBoundingBox) -> Void) {
        guard var bounds = session.headBoundingBox else { return }
        update(&bounds)
        session.headBoundingBox = bounds
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
        modelFiducialPlacementKind = firstUnplacedFiducialKind() ?? FiducialKind.allCases.first
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
        return FiducialKind.allCases.first { placed[$0] != true }
    }

    func pauseLiveScan() {
        stopAutoSampling()
        fiducialPlacementKind = nil
        scanViewModel.pause()
        persistCurrentLiDARMesh()
        persistSession()
        let issues = captureReadinessIssues
        recordAcquisitionEvent(AcquisitionEvent(
            kind: "capture-paused", message: "AR capture paused.",
            details: ["readinessIssues": issues.joined(separator: " | ")]))
        statusMessage = issues.isEmpty
            ? "Capture paused. Raw capture completeness checks passed."
            : "Capture paused · \(issues.count) advisory issue(s): \(issues.prefix(2).joined(separator: "; "))."
    }

    var captureCoverageSectorCount: Int {
        Set<String>(session.captureObservations.compactMap { observation -> String? in
            guard observation.quality?.warnings.contains("possible-motion-blur") != true else {
                return nil
            }
            return headCenteredCoverageSector(for: observation)
        }).count
    }

    private func headCenteredCoverageSector(for observation: CaptureObservation) -> String? {
        guard observation.cameraTransform.count == 16 else { return nil }
        guard let center = session.headBoundingBox?.center ?? fiducialCentroid else {
            return observation.quality?.coverageSector
        }
        let offset = SIMD3<Double>(
            Double(observation.cameraTransform[12]) - center.x,
            Double(observation.cameraTransform[13]) - center.y,
            Double(observation.cameraTransform[14]) - center.z)
        let distance = simd_length(offset)
        guard distance > 0.01 else { return nil }
        var azimuth = atan2(offset.x, -offset.z) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        let azimuthBin = Int((azimuth + 22.5) / 45) % 8
        let elevation = asin(max(-1, min(1, offset.y / distance))) * 180 / .pi
        let elevationBin = elevation > 20 ? "upper" : elevation < -20 ? "lower" : "level"
        return "azimuth-\(azimuthBin)-\(elevationBin)"
    }

    private var fiducialCentroid: Coordinate3D? {
        let coordinates = session.fiducials.compactMap(\.coordinate)
        guard coordinates.count == 3 else { return nil }
        return Coordinate3D(
            x: coordinates.map(\.x).reduce(0, +) / 3,
            y: coordinates.map(\.y).reduce(0, +) / 3,
            z: coordinates.map(\.z).reduce(0, +) / 3)
    }

    var captureReadinessIssues: [String] {
        var issues = [String]()
        if session.captureObservations.count < 40 {
            issues.append("fewer than 40 frames")
        }
        if captureCoverageSectorCount < 10 {
            issues.append("limited view coverage (\(captureCoverageSectorCount) sectors)")
        }
        if session.captureMode.usesLiDAR {
            let withDepth = session.captureObservations.filter { $0.rawDepthFilename != nil }.count
            if !session.captureObservations.isEmpty,
               Double(withDepth) / Double(session.captureObservations.count) < 0.8 {
                issues.append("depth present on less than 80% of frames")
            }
            if session.lidarMeshFilename == nil {
                issues.append("LiDAR mesh has not been persisted")
            }
        }
        let sharpFrames = session.captureObservations.filter {
            ($0.quality?.warnings.contains("possible-motion-blur") == false)
        }.count
        if !session.captureObservations.isEmpty,
           Double(sharpFrames) / Double(session.captureObservations.count) < 0.7 {
            issues.append("many frames may be blurred")
        }
        if session.layout.hasElectrodeNet, !session.fiducialsReady {
            issues.append("fiducials are incomplete")
        }
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
        if let bytes = artifactStore?.availableCapacityBytes, bytes < 2_000_000_000 {
            issues.append("less than 2 GB free storage")
        }
        return issues
    }

    private func sampleStatus(_ observation: CaptureObservation) -> String {
        let warnings = observation.quality?.warnings ?? []
        let base = "Auto-saved sample \(session.captureObservations.count) · coverage \(captureCoverageSectorCount)."
        return warnings.isEmpty ? base : "\(base) Advisory: \(warnings.joined(separator: ", "))."
    }

    private func persistCurrentLiDARMesh() {
        guard session.captureMode.usesLiDAR, let artifactStore else { return }
        let liveSnapshot = scanViewModel.fullMeshSnapshot()
        let hasLiveMesh = !liveSnapshot.vertices.isEmpty && !liveSnapshot.triangleIndices.isEmpty
        if hasLiveMesh {
            session.lidarMeshFilename = try? artifactStore.writeLiDARMeshSnapshot(
                liveSnapshot, for: session)
            cachedMeshSnapshot = liveSnapshot
        }

        guard let source = hasLiveMesh
                ? liveSnapshot
                : cachedMeshSnapshot ?? artifactStore.loadLiDARMeshSnapshot(for: session),
              !source.vertices.isEmpty, !source.triangleIndices.isEmpty else { return }

        // Regenerate this convenience artifact from the immutable full mesh so a
        // changed box can never leave a stale head crop referenced by the session.
        session.headCroppedLidarMeshFilename = nil
        if let bounds = session.headBoundingBox {
            let cropped = source.cropped(to: bounds)
            if !cropped.vertices.isEmpty, !cropped.triangleIndices.isEmpty {
                session.headCroppedLidarMeshFilename = try? artifactStore.writeLiDARMeshSnapshot(
                    cropped, for: session, filename: "lidar_mesh_head.ply")
            }
        }
    }

    func startAutoSampling() {
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

        autoSamplingTask?.cancel()
        isAutoSampling = true
        recordAcquisitionEvent(AcquisitionEvent(
            kind: "auto-sampling-started", message: "Automatic sampling started.",
            details: ["intervalSeconds": String(autoSamplingInterval)]))
        let preflight = capturePreflightIssues
        statusMessage = preflight.isEmpty
            ? "Auto-sampling started."
            : "Auto-sampling started with advisory: \(preflight.joined(separator: "; "))."

        autoSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if self.canAutoSample {
                    self.sampleCurrentARFrame()
                } else if self.scanViewModel.status.isRunning {
                    self.statusMessage = "Auto-sampling waiting for normal tracking and depth."
                }

                let nanoseconds = UInt64(max(0.25, self.autoSamplingInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    func stopAutoSampling() {
        if isAutoSampling {
            recordAcquisitionEvent(AcquisitionEvent(
                kind: "auto-sampling-stopped", message: "Automatic sampling stopped."))
        }
        autoSamplingTask?.cancel()
        autoSamplingTask = nil
        isAutoSampling = false
    }

    func sampleCurrentARFrame() {
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }

        do {
            guard let observation = try scanViewModel.sampleCurrentFrame(
                artifactStore: artifactStore, session: session,
                includeCompressedImage: captureCompressedImageReferences
            ) else {
                statusMessage = scanViewModel.status.message
                return
            }

            session.captureObservations.append(observation)
            recordAcquisitionEvent(AcquisitionEvent(
                kind: "sample-saved", message: "RGB and available depth evidence saved.",
                details: [
                    "observationID": observation.id.uuidString,
                    "primaryImageFormat": observation.cameraSnapshotFilename.map {
                        URL(fileURLWithPath: $0).pathExtension.lowercased()
                    } ?? "none",
                    "primaryImageLosslessPNG": String(
                        observation.cameraSnapshotFilename?.lowercased().hasSuffix(".png") == true),
                    "compressedImageRequested": String(captureCompressedImageReferences),
                    "compressedImageProvided": String(
                        observation.compressedCameraSnapshotFilename != nil)
                ]))
            enqueueLiveMetricDepthFusion(
                observation,
                frameID: session.captureObservations.count)
            enqueueLiveDetection(observation)
            let diagnosticsURL = try artifactStore.writeDiagnostics(for: session, scanStatus: scanViewModel.status)
            diagnosticsPath = diagnosticsURL.path
            persistSession()
            if !isAutoSampling { refreshSessions() }
            statusMessage = isAutoSampling
                ? sampleStatus(observation)
                : "Saved sample \(session.captureObservations.count) and diagnostics JSON."
        } catch {
            recordAcquisitionEvent(AcquisitionEvent(
                kind: "sample-save-failed", message: error.localizedDescription))
            statusMessage = "Could not save AR sample: \(error.localizedDescription)"
        }
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
        guard session.captureMode.usesLiDAR,
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
            guard let self, self.session.id == sessionID,
                  self.session.headBoundingBox == bounds else { return }
            self.liveMetricDepthPointCloud = update.snapshot
            self.liveMetricDepthFusionStatus = "6 mm live preview · "
                + "\(update.snapshot.points.count.formatted()) points · "
                + "\(update.snapshot.repeatObservedPointCount.formatted()) repeat-observed · "
                + "\(Int((update.elapsedSeconds * 1_000).rounded())) ms"
        }
    }

    private func enqueueLiveDetection(_ observation: CaptureObservation) {
        guard liveDetectionEnabled,
              observation.cameraSnapshotFilename != nil,
              observation.rawDepthFilename != nil else { return }
        if observation.quality?.warnings.contains("possible-motion-blur") == true {
            liveDetectionStatus = "Skipped a blurred sample; capture continues."
            return
        }
        if liveDetectionTask != nil {
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
                    return ([LabeledDetection](), error.localizedDescription)
                }
            }.value

            guard let self, self.liveDetectionGeneration == generation,
                  self.session.id == sessionSnapshot.id else { return }
            self.liveDetectionTask = nil
            self.isLiveDetecting = false
            if let error = outcome.1 {
                self.liveDetectionStatus = "Live OCR skipped a frame: \(error)"
            } else {
                self.liveRawDetections.append(contentsOf: outcome.0)
                self.liveProcessedFrameIDs.append(observation.id)
                self.rebuildLiveElectrodes()
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
        let directlyObserved = ElectrodeAnnotationBuilder.build(
            from: fused, layout: session.layout, confidenceThreshold: 0.55,
            suspectLabels: suspects)
        liveElectrodes = ElectrodeTemplateFitter.fillMissing(
            annotations: directlyObserved, layout: session.layout)

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
            engineVersion: "1",
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
                "ocrConfidenceThreshold": "0.45",
                "aggregationConfidenceThreshold": "0.55",
                "fillsMissingFromTemplate": "true",
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
        for kind in FiducialKind.allCases {
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
