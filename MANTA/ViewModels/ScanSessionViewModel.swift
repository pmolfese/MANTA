//
//  ScanSessionViewModel.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import Combine
import simd

/// A prepared export archive, wrapped so SwiftUI can present a share sheet via
/// `.sheet(item:)`.
struct ExportedBundle: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class ScanSessionViewModel: ObservableObject {
    @Published var session = ScanSession.newSession()
    @Published var availableLayouts: [ElectrodeLayout] = [.fallback128]
    @Published var selectedLayoutName = ElectrodeLayout.fallback128.name
    @Published var scanViewModel = ARScanViewModel()
    @Published var selectedFormat: ElectrodeExportFormat = .csv
    @Published var exportPreview = ""
    @Published var isDetecting = false
    @Published var isAutoSampling = false
    @Published var autoSamplingInterval = 0.75
    @Published var statusMessage = "Ready to start a LiDAR + photogrammetry scan."
    @Published var diagnosticsPath = ""
    @Published var isReconstructing = false
    @Published var reconstructionProgress: Double?
    @Published var promptForModelFiducials = false
    @Published var sessionSummaries: [SessionSummary] = []
    @Published var exportedBundle: ExportedBundle?
    /// When set, the next tap on the live scan places this fiducial.
    @Published var fiducialPlacementKind: FiducialKind?

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
            availableLayouts = layouts
            if let firstLayout = layouts.first {
                selectedLayoutName = firstLayout.name
                session = ScanSession.newSession(layout: firstLayout)
            }
        } catch {
            availableLayouts = [.fallback128]
            selectedLayoutName = ElectrodeLayout.fallback128.name
            session = ScanSession.newSession(layout: .fallback128)
            statusMessage = "Using fallback layout: \(error.localizedDescription)"
        }

        refreshExportPreview()
        refreshSessions()
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
        let layout = availableLayouts.first(where: { $0.name == selectedLayoutName }) ?? session.layout
        var newSession = ScanSession.newSession(layout: layout)
        newSession.subjectLabel = subjectLabel
        newSession.name = newSession.displayName
        session = newSession
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
            let loaded = try artifactStore.loadSession(id: id)
            session = loaded
            if availableLayouts.contains(where: { $0.name == loaded.layout.name }) {
                selectedLayoutName = loaded.layout.name
            }
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
        try? artifactStore.writeSession(target)
        refreshSessions()
    }

    func deleteSession(id: UUID) {
        try? artifactStore?.deleteSession(id: id)
        if id == session.id {
            startNewSession()
        }
        refreshSessions()
    }

    /// Builds a shareable zip of the session's folder and publishes it so the UI
    /// can present a share sheet.
    func exportSession(id: UUID) {
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }
        if id == session.id { persistSession() }
        statusMessage = "Preparing session bundle…"
        do {
            let url = try artifactStore.exportSessionBundle(id: id)
            exportedBundle = ExportedBundle(url: url)
            statusMessage = "Bundle ready: \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Writes the current session to disk. Called after meaningful mutations.
    private func persistSession() {
        try? artifactStore?.writeSession(session)
    }

    func runInitialDetection() async {
        isDetecting = true
        statusMessage = "Reading electrode labels from captured frames..."

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
                statusMessage = "Detected \(session.detectedElectrodeCount) electrodes. Review labels and landmarks next."
            }
        } catch {
            statusMessage = "Detection failed: \(error.localizedDescription)"
        }

        isDetecting = false
        refreshExportPreview()
        persistSession()
        refreshSessions()
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
        selectedLayoutName = name
        session = ScanSession.newSession(layout: layout)
        statusMessage = "Ready to scan with \(layout.name)."
        refreshExportPreview()
    }

    func startLiveScan() {
        scanViewModel.start(captureMode: session.captureMode)
        statusMessage = "Live \(session.captureMode.rawValue) scan running."
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
            _ = result

            // Snapshot the accumulated LiDAR mesh for ICP and persist it alongside the model.
            let meshCloud = scanViewModel.meshWorldPoints()
            if !meshCloud.isEmpty {
                session.lidarMeshFilename = try? artifactStore.writeLiDARMesh(meshCloud, for: session)
            }

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

    /// Handles a tap on the live AR view while a fiducial is armed: ray-casts to
    /// the scanned surface and stores the world-frame landmark.
    func handleScanTap(viewPoint: CGPoint) {
        guard let kind = fiducialPlacementKind else { return }
        guard let world = scanViewModel.raycastToWorld(viewPoint: viewPoint) else {
            statusMessage = "Couldn't hit the surface there — aim at the head and retry."
            return
        }

        if let index = session.fiducials.firstIndex(where: { $0.kind == kind }) {
            session.fiducials[index].coordinate = Coordinate3D(x: Double(world.x), y: Double(world.y), z: Double(world.z))
            session.fiducials[index].state = .reviewed
        }
        fiducialPlacementKind = nil
        persistSession()
        let placed = session.fiducials.filter { $0.coordinate != nil }.count
        statusMessage = session.fiducialsReady
            ? "All fiducials placed — exports now use the head coordinate frame."
            : "Placed \(kind.rawValue) (\(placed)/3)."
        refreshExportPreview()
    }

    func pauseLiveScan() {
        stopAutoSampling()
        scanViewModel.pause()
        statusMessage = "Live scan paused."
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
        statusMessage = "Auto-sampling started."

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
            guard let observation = try scanViewModel.sampleCurrentFrame(artifactStore: artifactStore, session: session) else {
                statusMessage = scanViewModel.status.message
                return
            }

            session.captureObservations.append(observation)
            let diagnosticsURL = try artifactStore.writeDiagnostics(for: session, scanStatus: scanViewModel.status)
            diagnosticsPath = diagnosticsURL.path
            persistSession()
            if !isAutoSampling { refreshSessions() }
            statusMessage = isAutoSampling
                ? "Auto-saved sample \(session.captureObservations.count)."
                : "Saved sample \(session.captureObservations.count) and diagnostics JSON."
        } catch {
            statusMessage = "Could not save AR sample: \(error.localizedDescription)"
        }
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
