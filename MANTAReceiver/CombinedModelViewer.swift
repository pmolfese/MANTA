import AppKit
import MANTACore
import SceneKit
import SwiftUI
import simd

struct ReceiverModelLandmark: Hashable, Sendable {
    var kind: FiducialKind
    var point: SIMD3<Float>
}

/// Interactive desktop viewer for all reconstructed geometry in a capture.
/// LiDAR is already in ARKit world coordinates. ObjectCapture geometry is put
/// into that same scene only through the declared model-to-world transform.
struct CombinedModelViewer: View {
    let bundle: MANTAValidatedBundle
    private let assets: ReceiverSceneAssets
    private let photogrammetryPlacementLabel: String?
    private let onPhotogrammetryPointPicked: ((SIMD3<Float>) -> Void)?
    private let onFiducialsSaved: (([MANTAFiducialSolution]) -> Void)?
    private let fiducialSaveInProgress: Bool
    private let modelLandmarks: [ReceiverModelLandmark]
    private let worldTargetLandmarks: [ReceiverModelLandmark]
    private let electrodesOverride: [MANTAElectrodeSolution]?
    private let electrodePlacementLabel: String?
    private let onWorldElectrodePointPicked: ((SIMD3<Double>) -> Void)?
    private let includesFiducialAnnotations: Bool
    private let autoShowsFusedDepth: Bool

    @ObservedObject private var display: ReceiverDisplaySettings

    // Forwarders so the body keeps reading/writing plain names while the shared
    // sidebar-driven settings object is the single source of truth.
    private var showLiDAR: Bool {
        get { display.showLiDAR } nonmutating set { display.showLiDAR = newValue }
    }
    private var showPhotogrammetry: Bool {
        get { display.showPhotogrammetry } nonmutating set { display.showPhotogrammetry = newValue }
    }
    private var showFusedDepth: Bool {
        get { display.showFusedDepth } nonmutating set { display.showFusedDepth = newValue }
    }
    private var showAnnotations: Bool {
        get { display.showAnnotations } nonmutating set { display.showAnnotations = newValue }
    }
    private var lidarChoice: ReceiverLiDARChoice {
        get { display.lidarChoice } nonmutating set { display.lidarChoice = newValue }
    }
    private var lidarStyle: ReceiverLiDARStyle {
        get { display.lidarStyle } nonmutating set { display.lidarStyle = newValue }
    }

    // Stored so defaults can be applied to the shared settings on appear.
    private let displayContextKey: String
    private let annotationOnlyDefault: Bool

    @State private var selection: ReceiverSceneSelection?
    @State private var loadError: String?
    @State private var frameRequest = 0
    @State private var fusedDepth: ReceiverFusedDepthCloud?
    @State private var fusionState = ReceiverFusionState.unavailable
    @State private var fiducialPlacementKind: FiducialKind?
    @State private var fiducialOverrides = [FiducialKind: SIMD3<Double>]()

    init(
        bundle: MANTAValidatedBundle,
        display: ReceiverDisplaySettings,
        modelToWorldOverride: simd_float4x4? = nil,
        photogrammetryURLOverride: URL? = nil,
        photogrammetryPlacementLabel: String? = nil,
        modelLandmarks: [ReceiverModelLandmark] = [],
        worldTargetLandmarks: [ReceiverModelLandmark] = [],
        onPhotogrammetryPointPicked: ((SIMD3<Float>) -> Void)? = nil,
        electrodesOverride: [MANTAElectrodeSolution]? = nil,
        electrodePlacementLabel: String? = nil,
        onWorldElectrodePointPicked: ((SIMD3<Double>) -> Void)? = nil,
        annotationOnlyDefault: Bool = false,
        includesFiducialAnnotations: Bool = true,
        fiducialSaveInProgress: Bool = false,
        onFiducialsSaved: (([MANTAFiducialSolution]) -> Void)? = nil
    ) {
        self.bundle = bundle
        self.display = display
        var assets = ReceiverSceneAssets(
            bundle: bundle, photogrammetryURLOverride: photogrammetryURLOverride)
        if photogrammetryURLOverride != nil {
            assets.modelToWorld = modelToWorldOverride
        } else if let modelToWorldOverride {
            assets.modelToWorld = modelToWorldOverride
        }
        self.assets = assets
        self.photogrammetryPlacementLabel = photogrammetryPlacementLabel
        self.modelLandmarks = modelLandmarks
        self.worldTargetLandmarks = worldTargetLandmarks
        self.onPhotogrammetryPointPicked = onPhotogrammetryPointPicked
        self.electrodesOverride = electrodesOverride
        self.electrodePlacementLabel = electrodePlacementLabel
        self.onWorldElectrodePointPicked = onWorldElectrodePointPicked
        self.includesFiducialAnnotations = includesFiducialAnnotations
        self.autoShowsFusedDepth = !annotationOnlyDefault
        self.onFiducialsSaved = onFiducialsSaved
        self.fiducialSaveInProgress = fiducialSaveInProgress
        self.annotationOnlyDefault = annotationOnlyDefault
        // One default configuration per scene context so switching bundle/model
        // resets the toggles, but capability refreshes never clobber user choices.
        let modelIdentity = photogrammetryURLOverride?.standardizedFileURL.path
            ?? assets.photogrammetryURL?.standardizedFileURL.path ?? "none"
        self.displayContextKey = "\(bundle.manifest.bundleID.uuidString)|\(modelIdentity)"
            + "|\(photogrammetryPlacementLabel ?? "")|\(annotationOnlyDefault)"
    }

    /// Pushes current defaults and capabilities into the shared settings.
    private func syncDisplay() {
        display.configureDefaults(
            key: displayContextKey,
            defaultLiDARChoice: assets.defaultLiDARChoice,
            photogrammetryAvailable: assets.photogrammetryURL != nil,
            hasModelToWorld: assets.modelToWorld != nil,
            isPlacement: photogrammetryPlacementLabel != nil,
            annotationOnly: annotationOnlyDefault)
        display.updateCapabilities(
            defaultLiDARChoice: assets.defaultLiDARChoice,
            lidarChoices: assets.lidarChoices,
            photogrammetryAvailable: assets.photogrammetryURL != nil,
            fusedDepthAvailable: fusedDepth != nil,
            hasAnnotations: hasAnnotations,
            annotationsSpatiallyValid: annotationsAreSpatiallyValid,
            canOverlay: assets.canOverlay)
        display.configureBoundsDefaults(
            key: displayContextKey, declared: bundle.capture.reconstruction?.headBoundingBox)
    }

    var body: some View {
            ZStack {
                if assets.hasAnySurface || hasAnnotations || fusedDepth != nil
                    || fusionState == .loading {
                    ReceiverCombinedSceneView(
                        assets: assets,
                        fusedDepth: fusedDepth,
                        settings: ReceiverSceneSettings(
                            showLiDAR: showLiDAR,
                            showPhotogrammetry: showPhotogrammetry,
                            showFusedDepth: showFusedDepth,
                            showAnnotations: showAnnotations && annotationsAreSpatiallyValid,
                            lidarChoice: lidarChoice,
                            lidarStyle: lidarStyle,
                            showHeadBoundingBox: display.showHeadBoundingBox,
                            headBoundingBoxCenter: display.headBoundingBoxCenter,
                            headBoundingBoxHalfExtent: display.headBoundingBoxHalfExtent),
                        electrodes: displayedElectrodes,
                        fiducials: displayedFiducials,
                        modelLandmarks: modelLandmarks,
                        worldTargetLandmarks: worldTargetLandmarks,
                        selection: $selection,
                        loadError: $loadError,
                        frameRequest: frameRequest,
                        photogrammetryPlacementLabel: photogrammetryPlacementLabel,
                        onPhotogrammetryPointPicked: onPhotogrammetryPointPicked,
                        fiducialPlacementKind: fiducialPlacementKind,
                        worldPlacementLabel: electrodePlacementLabel
                            ?? fiducialPlacementKind?.rawValue,
                        onWorldPointPicked: onWorldElectrodePointPicked ?? placeFiducial)
                } else {
                    ContentUnavailableView(
                        "No 3D surface in this bundle",
                        systemImage: "cube.transparent",
                        description: Text(
                            "No LiDAR, photogrammetry, or fusable metric-depth evidence was found."))
                }

                statusOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)

                interactionHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)

                if let selection {
                    SelectionInspector(selection: selection) {
                        self.selection = nil
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(12)
                }

                if onFiducialsSaved != nil {
                    fiducialPlacementBar
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
        .onAppear { syncDisplay() }
        .onChange(of: fusionState) { _, _ in syncDisplay() }
        .onChange(of: display.frameRequestToken) { _, _ in frameRequest &+= 1 }
        .task(id: bundle.manifest.bundleID) {
            syncDisplay()
        }
        // Keyed on the actual fusion inputs, not the bundle ID: the bundle ID no
        // longer changes on in-place edits (reconstruction/alignment/bounding-box
        // saves all mutate the same package), so keying on it here meant Fused
        // Depth was computed once and never refreshed after an edit that changed
        // what it should include - e.g. widening the head bounding box.
        .task(id: fusionInputSignature) {
            if photogrammetryPlacementLabel == nil {
                await loadDepthFusion()
            }
        }
        .onChange(of: bundle.manifest.bundleID) { _, _ in
            fiducialPlacementKind = nil
            fiducialOverrides.removeAll()
        }
        .onChange(of: photogrammetryTransformSignature) { _, _ in
            selection = nil
            syncDisplay()
            // The LiDAR toggle is left to the user. Forcing it on with every
            // solve fought the control and re-showed the metric surface each
            // time a candidate transform appeared.
            //
            // The previous camera target is in the coordinate frame that was
            // just replaced. Keeping it makes a correctly transformed model
            // appear tiny and far away, with the old pick marker left behind.
            frameRequest &+= 1
        }
    }

    /// Fiducial-placement menu for the Viewer's manual fiducial correction. It is
    /// context-specific (needs `onFiducialsSaved`) so it stays on the scene rather
    /// than in the global sidebar Display section.
    @ViewBuilder private var fiducialPlacementBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(FiducialKind.allCases) { kind in
                    Button(kind.rawValue) {
                        showAnnotations = true
                        fiducialPlacementKind = kind
                        selection = nil
                    }
                }
            } label: {
                Label(
                    fiducialPlacementKind.map { "Place \($0.rawValue)" } ?? "Move Fiducial",
                    systemImage: "mappin.and.ellipse")
            }
            .fixedSize()
            .disabled(!hasWorldPlacementSurface)

            if !fiducialOverrides.isEmpty {
                Button("Save Fiducials", systemImage: "checkmark.circle") {
                    onFiducialsSaved?(displayedFiducials)
                    fiducialPlacementKind = nil
                }
                .disabled(fiducialSaveInProgress)
                Button("Discard", role: .cancel) {
                    fiducialPlacementKind = nil
                    fiducialOverrides.removeAll()
                }
                .disabled(fiducialSaveInProgress)
                if fiducialSaveInProgress { ProgressView().controlSize(.small) }
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }


    @ViewBuilder private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showLiDAR, showPhotogrammetry, assets.canOverlay {
                Label("LiDAR + photogrammetry in ARKit world", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if assets.photogrammetryURL != nil,
                      assets.defaultLiDARChoice != nil,
                      !assets.canOverlay {
                Label("No model-to-world transform", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("The two surfaces can be inspected separately but are not overlaid.")
                    .foregroundStyle(.secondary)
            } else if showLiDAR {
                Label("LiDAR · ARKit world", systemImage: "dot.scope")
                    .foregroundStyle(.teal)
            } else if showPhotogrammetry {
                Label(
                    assets.modelToWorld == nil ? "Photogrammetry · model space" : "Photogrammetry · ARKit world",
                    systemImage: "cube.fill")
                    .foregroundStyle(.indigo)
            } else if showAnnotations, hasAnnotations {
                Label("Sensors only · ARKit world", systemImage: "dot.circle.and.hand.point.up.left.fill")
                    .foregroundStyle(.green)
            }

            if showFusedDepth, let fusedDepth {
                Label("RGB-D fusion · ARKit world", systemImage: "circle.hexagongrid.fill")
                    .foregroundStyle(.cyan)
                Text(fusedDepth.summary)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = fusionState {
                Text("Depth fusion: \(message)")
                    .foregroundStyle(.orange)
            }

            if showPhotogrammetry, !showLiDAR, assets.modelToWorld == nil, hasAnnotations {
                Text("Annotations are hidden because they are in ARKit world coordinates.")
                    .foregroundStyle(.secondary)
            }

            if let loadError {
                Text(loadError).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    private var interactionHint: some View {
        Text(electrodePlacementLabel.map {
            "Click the corrected \($0) location · drag to orbit · scroll to zoom"
        } ?? fiducialPlacementKind.map {
            "Click the corrected \($0.rawValue) location · drag to orbit · scroll to zoom"
        } ?? photogrammetryPlacementLabel.map {
            "Click \($0) on the photogrammetry surface · drag to orbit · scroll to zoom"
        } ?? "Drag to orbit · right-drag or Shift-drag to pan · scroll or pinch to zoom · click to inspect")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
    }

    private var hasAnnotations: Bool {
        !displayedElectrodes.isEmpty
            || !displayedFiducials.isEmpty
    }

    private var hasWorldPlacementSurface: Bool {
        showLiDAR || showFusedDepth || (showPhotogrammetry && assets.modelToWorld != nil)
    }

    private var photogrammetryTransformSignature: Int {
        var hasher = Hasher()
        hasher.combine(assets.photogrammetryURL)
        if let transform = assets.modelToWorld {
            for column in 0..<4 {
                for row in 0..<4 { hasher.combine(transform[column][row]) }
            }
        }
        return hasher.finalize()
    }

    private var displayedFiducials: [MANTAFiducialSolution] {
        guard includesFiducialAnnotations else { return [] }
        var values = Dictionary(uniqueKeysWithValues: assets.fiducials.map { ($0.kind, $0) })
        for (kind, point) in fiducialOverrides {
            values[kind.rawValue] = MANTAFiducialSolution(
                kind: kind.rawValue,
                coordinateSystem: "arkit-world",
                coordinate: [point.x, point.y, point.z],
                state: "Reviewed on macOS 3D surface")
        }
        return FiducialKind.allCases.compactMap { values[$0.rawValue] }
    }

    private var displayedElectrodes: [MANTAElectrodeSolution] {
        electrodesOverride ?? bundle.capture.electrodes ?? []
    }

    private func placeFiducial(_ point: SIMD3<Double>) {
        guard let kind = fiducialPlacementKind else { return }
        fiducialOverrides[kind] = point
        fiducialPlacementKind = nil
        showAnnotations = true
        selection = nil
    }

    private var annotationsAreSpatiallyValid: Bool {
        guard hasAnnotations else { return false }
        // World annotations are meaningful on their own and with metric-world
        // surfaces. They must not be drawn beside an unaligned photogrammetry
        // model: sharing one SceneKit scene makes unrelated coordinate frames
        // look like a failed or preloaded registration. Model-placement markers
        // are separate nodes under the photogrammetry root and remain visible.
        return !(showPhotogrammetry && assets.modelToWorld == nil)
    }

    /// Everything that actually determines the fused cloud's contents: which
    /// frames feed it, the LiDAR head-mesh centroid fallback, and the declared
    /// head bounding box. Recomputing when this changes (rather than once per
    /// bundle identity) is what lets a saved bounding-box edit actually widen or
    /// shrink what Fused Depth includes.
    private var fusionInputSignature: Int {
        guard let input = assets.fusionInput else { return 0 }
        var hasher = Hasher()
        hasher.combine(input.rootDirectory)
        hasher.combine(input.observations.count)
        for observation in input.observations { hasher.combine(observation.id) }
        hasher.combine(input.headMeshURL)
        if let bounds = input.declaredBounds {
            hasher.combine(bounds.center.x)
            hasher.combine(bounds.center.y)
            hasher.combine(bounds.center.z)
            hasher.combine(bounds.widthMeters)
            hasher.combine(bounds.heightMeters)
            hasher.combine(bounds.depthMeters)
        }
        return hasher.finalize()
    }

    @MainActor
    private func loadDepthFusion() async {
        guard let input = assets.fusionInput else {
            fusionState = .unavailable
            return
        }
        fusionState = .loading
        do {
            let cloud = try await Task.detached(priority: .userInitiated) {
                try ReceiverDepthFusion.fuse(input)
            }.value
            guard !Task.isCancelled else { return }
            fusedDepth = cloud
            if autoShowsFusedDepth { showFusedDepth = true }
            fusionState = .ready
            frameRequest &+= 1
        } catch {
            fusionState = .failed(error.localizedDescription)
        }
    }
}

private enum ReceiverFusionState: Equatable {
    case unavailable
    case loading
    case ready
    case failed(String)
}

private struct SelectionInspector: View {
    let selection: ReceiverSceneSelection
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(selection.displayName, systemImage: selection.systemImage)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(action: clear) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            Text(String(
                format: "x %.4f   y %.4f   z %.4f m",
                selection.worldPosition.x,
                selection.worldPosition.y,
                selection.worldPosition.z))
                .font(.caption.monospacedDigit())
            Text(String(
                format: "x %.1f   y %.1f   z %.1f mm",
                selection.worldPosition.x * 1_000,
                selection.worldPosition.y * 1_000,
                selection.worldPosition.z * 1_000))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if let faceIndex = selection.faceIndex {
                Text(selection.surface == .fusedDepth ? "Point \(faceIndex)" : "Triangle \(faceIndex)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Copy Coordinates", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    String(
                        format: "%.9f\t%.9f\t%.9f",
                        selection.worldPosition.x,
                        selection.worldPosition.y,
                        selection.worldPosition.z),
                    forType: .string)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(10)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

enum ReceiverLiDARChoice: String, CaseIterable, Identifiable, Hashable {
    case headRegion = "Head Region"
    case fullEnvironment = "Full Environment"
    var id: String { rawValue }
}

enum ReceiverLiDARStyle: String, CaseIterable, Identifiable, Hashable {
    case solid = "Solid"
    case wireframe = "Wireframe"
    case pointCloud = "Point Cloud"
    var id: String { rawValue }
}

private struct ReceiverSceneAssets {
    var fullLiDARURL: URL?
    var headLiDARURL: URL?
    var photogrammetryURL: URL?
    var modelToWorld: simd_float4x4?
    var fiducials: [MANTAFiducialSolution]
    var fusionInput: ReceiverDepthFusionInput?
    /// The scene is only rebuilt when `sceneSignature` changes, which is
    /// otherwise based on file *paths* - unchanged when an edit (e.g.
    /// regenerating the LiDAR head crop after a bounding-box save) overwrites
    /// the same path with new bytes. Folding each surface file's modification
    /// date into the signature (via this) makes such in-place rewrites cause a
    /// reload instead of silently showing stale, already-loaded geometry.
    var contentRevision: Date?

    init(bundle: MANTAValidatedBundle, photogrammetryURLOverride: URL? = nil) {
        let reconstruction = bundle.capture.reconstruction
        fullLiDARURL = Self.existingURL(
            root: bundle.rootDirectory, path: reconstruction?.lidarMeshPath)
        headLiDARURL = Self.existingURL(
            root: bundle.rootDirectory, path: reconstruction?.headCroppedLidarMeshPath)
        photogrammetryURL = photogrammetryURLOverride ?? Self.existingURL(
            root: bundle.rootDirectory, path: reconstruction?.objectCaptureModelPath)
        contentRevision = [fullLiDARURL, headLiDARURL, photogrammetryURL]
            .compactMap { $0.flatMap(Self.modificationDate) }
            .max()
        let captureFiducials = bundle.capture.fiducials ?? []
        fiducials = captureFiducials.isEmpty
            ? Self.rawFiducials(root: bundle.rootDirectory)
            : captureFiducials
        if let values = reconstruction?.modelToWorld, values.count == 16 {
            modelToWorld = simd_float4x4(
                SIMD4(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3])),
                SIMD4(Float(values[4]), Float(values[5]), Float(values[6]), Float(values[7])),
                SIMD4(Float(values[8]), Float(values[9]), Float(values[10]), Float(values[11])),
                SIMD4(Float(values[12]), Float(values[13]), Float(values[14]), Float(values[15])))
        }
        let depthObservations = bundle.capture.observations.filter { $0.depth != nil }
        let coordinates = fiducials.compactMap { fiducial -> SIMD3<Float>? in
            guard let point = fiducial.coordinate, point.count == 3 else { return nil }
            return SIMD3(Float(point[0]), Float(point[1]), Float(point[2]))
        }
        if depthObservations.isEmpty {
            fusionInput = nil
        } else {
            fusionInput = ReceiverDepthFusionInput(
                rootDirectory: bundle.rootDirectory,
                observations: depthObservations,
                declaredBounds: reconstruction?.headBoundingBox,
                headMeshURL: headLiDARURL,
                fiducialCoordinates: coordinates)
        }
    }

    var hasAnySurface: Bool {
        fullLiDARURL != nil || headLiDARURL != nil || photogrammetryURL != nil
    }
    var canOverlay: Bool {
        photogrammetryURL != nil && defaultLiDARChoice != nil && modelToWorld != nil
    }
    var defaultLiDARChoice: ReceiverLiDARChoice? {
        if headLiDARURL != nil { return .headRegion }
        if fullLiDARURL != nil { return .fullEnvironment }
        return nil
    }
    var lidarChoices: [ReceiverLiDARChoice] {
        ReceiverLiDARChoice.allCases.filter { url(for: $0) != nil }
    }
    func url(for choice: ReceiverLiDARChoice) -> URL? {
        switch choice {
        case .headRegion: headLiDARURL
        case .fullEnvironment: fullLiDARURL
        }
    }

    private static func existingURL(root: URL, path: String?) -> URL? {
        guard let path else { return nil }
        let url = root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func rawFiducials(root: URL) -> [MANTAFiducialSolution] {
        let url = root.appendingPathComponent("acquisition/fiducial-placements.json")
        guard let data = try? Data(contentsOf: url),
              let evidence = try? MANTAJSON.makeDecoder().decode(
                [FiducialPlacementEvidence].self, from: data) else { return [] }
        var latest = [FiducialKind: FiducialPlacementEvidence]()
        for item in evidence.sorted(by: { $0.placedAt < $1.placedAt }) {
            latest[item.kind] = item
        }
        return FiducialKind.allCases.compactMap { kind in
            guard let item = latest[kind] else { return nil }
            return MANTAFiducialSolution(
                kind: kind.rawValue,
                coordinateSystem: item.coordinateSystem,
                coordinate: [item.coordinate.x, item.coordinate.y, item.coordinate.z],
                state: "Raw placement · \(item.hitMethod)")
        }
    }
}

private struct ReceiverSceneSettings: Hashable {
    var showLiDAR: Bool
    var showPhotogrammetry: Bool
    var showFusedDepth: Bool
    var showAnnotations: Bool
    var lidarChoice: ReceiverLiDARChoice
    var lidarStyle: ReceiverLiDARStyle
    var showHeadBoundingBox: Bool
    var headBoundingBoxCenter: SIMD3<Float>
    var headBoundingBoxHalfExtent: SIMD3<Float>
}

private struct ReceiverSceneSelection: Equatable {
    enum Surface: Equatable {
        case lidar
        case fusedDepth
        case photogrammetry(aligned: Bool)
        case annotation(String)
    }

    var surface: Surface
    var worldPosition: SIMD3<Double>
    var faceIndex: Int?

    var displayName: String {
        switch surface {
        case .lidar: "LiDAR surface · ARKit world"
        case .fusedDepth: "Fused RGB-D point · ARKit world"
        case .photogrammetry(true): "Photogrammetry surface · ARKit world"
        case .photogrammetry(false): "Photogrammetry surface · model space"
        case .annotation(let label): "Annotation · \(label)"
        }
    }
    var systemImage: String {
        switch surface {
        case .lidar: "dot.scope"
        case .fusedDepth: "circle.hexagongrid.fill"
        case .photogrammetry: "cube.fill"
        case .annotation: "mappin.and.ellipse"
        }
    }
}

@MainActor
private final class ReceiverInteractiveSCNView: SCNView {
    var onStationaryClick: ((CGPoint) -> Void)?

    private enum DragKind {
        case orbit
        case pan
    }

    private var dragKind: DragKind?
    private var dragStart = CGPoint.zero
    private var previousDragLocation = CGPoint.zero
    private var didDrag = false

    override var acceptsFirstResponder: Bool { true }

    func configureCameraInteraction() {
        allowsCameraControl = false
        defaultCameraController.pointOfView = pointOfView
        defaultCameraController.interactionMode = .orbitTurntable
        defaultCameraController.automaticTarget = false
        defaultCameraController.inertiaEnabled = false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginDrag(
            event,
            kind: event.modifierFlags.contains(.shift) ? .pan : .orbit)
    }

    override func mouseDragged(with event: NSEvent) {
        continueDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        endDrag(event, permitsClick: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginDrag(event, kind: .pan)
    }

    override func rightMouseDragged(with event: NSEvent) {
        continueDrag(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        endDrag(event, permitsClick: false)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        dolly(scale: exp(-Float(delta) * (event.hasPreciseScrollingDeltas ? 0.012 : 0.08)))
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        dolly(scale: exp(-Float(event.magnification) * 2.0))
    }

    private func beginDrag(_ event: NSEvent, kind: DragKind) {
        let location = convert(event.locationInWindow, from: nil)
        dragKind = kind
        dragStart = location
        previousDragLocation = location
        didDrag = false
        defaultCameraController.stopInertia()
        defaultCameraController.pointOfView = pointOfView
        defaultCameraController.interactionMode = .orbitTurntable
    }

    private func continueDrag(_ event: NSEvent) {
        guard let dragKind else { return }
        let location = convert(event.locationInWindow, from: nil)
        let totalX = location.x - dragStart.x
        let totalY = location.y - dragStart.y
        if totalX * totalX + totalY * totalY >= 9 { didDrag = true }

        let dx = location.x - previousDragLocation.x
        let dy = location.y - previousDragLocation.y
        previousDragLocation = location

        switch dragKind {
        case .orbit:
            defaultCameraController.rotateBy(
                x: Float(-dx * 0.28), y: Float(dy * 0.28))
        case .pan:
            panBy(screenX: dx, screenY: dy)
        }
        needsDisplay = true
    }

    private func endDrag(_ event: NSEvent, permitsClick: Bool) {
        let location = convert(event.locationInWindow, from: nil)
        let shouldClick = permitsClick && !didDrag
        dragKind = nil
        didDrag = false
        defaultCameraController.interactionMode = .orbitTurntable
        if shouldClick { onStationaryClick?(location) }
    }

    private func panBy(screenX: CGFloat, screenY: CGFloat) {
        guard let camera = pointOfView else { return }
        let target = SIMD3<Float>(defaultCameraController.target)
        let position = camera.simdWorldPosition
        let distance = max(simd_distance(position, target), 0.01)
        let fieldOfView = Float(camera.camera?.fieldOfView ?? 42) * .pi / 180
        let worldPerPixel = 2 * distance * tan(fieldOfView / 2)
            / Float(max(bounds.height, 1))
        let transform = camera.simdWorldTransform
        let right = simd_normalize(SIMD3<Float>(
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
        let up = simd_normalize(SIMD3<Float>(
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
        let translation = -(right * Float(screenX) + up * Float(screenY)) * worldPerPixel
        camera.simdWorldPosition += translation
        defaultCameraController.target = SCNVector3(target + translation)
    }

    private func dolly(scale requestedScale: Float) {
        guard requestedScale.isFinite, let camera = pointOfView else { return }
        let target = SIMD3<Float>(defaultCameraController.target)
        let offset = camera.simdWorldPosition - target
        let distance = simd_length(offset)
        guard distance > 0.0001 else { return }
        let newDistance = min(max(distance * requestedScale, 0.008), 100)
        camera.simdWorldPosition = target + offset / distance * newDistance
        defaultCameraController.pointOfView = camera
        needsDisplay = true
    }
}

private struct ReceiverCombinedSceneView: NSViewRepresentable {
    let assets: ReceiverSceneAssets
    let fusedDepth: ReceiverFusedDepthCloud?
    let settings: ReceiverSceneSettings
    let electrodes: [MANTAElectrodeSolution]
    let fiducials: [MANTAFiducialSolution]
    let modelLandmarks: [ReceiverModelLandmark]
    let worldTargetLandmarks: [ReceiverModelLandmark]
    @Binding var selection: ReceiverSceneSelection?
    @Binding var loadError: String?
    let frameRequest: Int
    let photogrammetryPlacementLabel: String?
    let onPhotogrammetryPointPicked: ((SIMD3<Float>) -> Void)?
    let fiducialPlacementKind: FiducialKind?
    let worldPlacementLabel: String?
    let onWorldPointPicked: ((SIMD3<Double>) -> Void)?

    func makeNSView(context: Context) -> SCNView {
        let view = ReceiverInteractiveSCNView()
        view.backgroundColor = NSColor(white: 0.025, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        view.rendersContinuously = false
        view.configureCameraInteraction()
        view.onStationaryClick = { [weak coordinator = context.coordinator, weak view] point in
            guard let coordinator, let view else { return }
            coordinator.handleClick(at: point, in: view)
        }
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.photogrammetryAligned = assets.modelToWorld != nil
        context.coordinator.photogrammetryPlacementLabel = photogrammetryPlacementLabel
        context.coordinator.onPhotogrammetryPointPicked = onPhotogrammetryPointPicked
        context.coordinator.fiducialPlacementKind = fiducialPlacementKind
        context.coordinator.worldPlacementLabel = worldPlacementLabel
        context.coordinator.onWorldPointPicked = onWorldPointPicked
        let signature = sceneSignature
        if context.coordinator.sceneSignature != signature {
            let previousCamera = view.pointOfView?.simdTransform
            let previousTarget = view.defaultCameraController.target
            do {
                let built = try ReceiverSceneBuilder.build(
                    assets: assets,
                    fusedDepth: fusedDepth,
                    settings: settings,
                    electrodes: electrodes,
                    fiducials: fiducials,
                    modelLandmarks: modelLandmarks,
                    worldTargetLandmarks: worldTargetLandmarks)
                view.scene = built.scene
                context.coordinator.surfaceRoot = built.surfaceRoot
                context.coordinator.photogrammetryRoot = built.photogrammetryRoot
                context.coordinator.metricPlacementPoints = built.metricPlacementPoints
                context.coordinator.sceneSignature = signature
                context.coordinator.installSelectionMarker(selection)
                setLoadError(built.partialLoadWarnings.isEmpty
                    ? nil : built.partialLoadWarnings.joined(separator: " "))

                if let previousCamera, context.coordinator.hasFramedOnce {
                    let camera = ReceiverSceneBuilder.cameraNode()
                    camera.simdTransform = previousCamera
                    built.scene.rootNode.addChildNode(camera)
                    view.pointOfView = camera
                    view.defaultCameraController.target = previousTarget
                } else {
                    context.coordinator.hasFramedOnce = ReceiverSceneBuilder.frame(
                        view: view, surfaceRoot: built.surfaceRoot)
                }
                if let interactiveView = view as? ReceiverInteractiveSCNView {
                    interactiveView.configureCameraInteraction()
                }
            } catch {
                setLoadError(error.localizedDescription)
            }
        }

        if context.coordinator.frameRequest != frameRequest {
            context.coordinator.frameRequest = frameRequest
            if let root = context.coordinator.surfaceRoot {
                _ = ReceiverSceneBuilder.frame(view: view, surfaceRoot: root)
                (view as? ReceiverInteractiveSCNView)?.configureCameraInteraction()
            }
        }

        // Selection is not part of the expensive scene signature. Keep its
        // lightweight marker synchronized independently so clearing a pick on
        // alignment cannot leave a marker at the old model-space location.
        context.coordinator.installSelectionMarker(selection)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, loadError: $loadError)
    }

    private func setLoadError(_ message: String?) {
        guard loadError != message else { return }
        DispatchQueue.main.async { self.loadError = message }
    }

    private var sceneSignature: Int {
        var hasher = Hasher()
        hasher.combine(assets.fullLiDARURL)
        hasher.combine(assets.headLiDARURL)
        hasher.combine(assets.photogrammetryURL)
        hasher.combine(assets.contentRevision)
        hasher.combine(fusedDepth?.points.count)
        hasher.combine(fusedDepth?.acceptedDepthSamples)
        if let transform = assets.modelToWorld {
            for column in 0..<4 {
                for row in 0..<4 { hasher.combine(transform[column][row]) }
            }
        }
        hasher.combine(settings)
        for electrode in electrodes {
            hasher.combine(electrode.label)
            hasher.combine(electrode.coordinate)
            hasher.combine(electrode.state)
            hasher.combine(electrode.confidence)
        }
        for fiducial in fiducials {
            hasher.combine(fiducial.kind)
            hasher.combine(fiducial.coordinate)
        }
        for landmark in modelLandmarks { hasher.combine(landmark) }
        for landmark in worldTargetLandmarks { hasher.combine(landmark) }
        return hasher.finalize()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: SCNView?
        var selection: Binding<ReceiverSceneSelection?>
        var loadError: Binding<String?>
        var sceneSignature: Int?
        var surfaceRoot: SCNNode?
        var selectionMarker: SCNNode?
        weak var photogrammetryRoot: SCNNode?
        var frameRequest = 0
        var hasFramedOnce = false
        var photogrammetryAligned = false
        var photogrammetryPlacementLabel: String?
        var onPhotogrammetryPointPicked: ((SIMD3<Float>) -> Void)?
        var fiducialPlacementKind: FiducialKind?
        var worldPlacementLabel: String?
        var onWorldPointPicked: ((SIMD3<Double>) -> Void)?
        var metricPlacementPoints = [ReceiverMetricPlacementPoint]()

        init(
            selection: Binding<ReceiverSceneSelection?>,
            loadError: Binding<String?>
        ) {
            self.selection = selection
            self.loadError = loadError
        }

        func handleClick(at point: CGPoint, in view: SCNView) {
            let hits = view.hitTest(point, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .backFaceCulling: false,
                .ignoreHiddenNodes: true
            ])

            if worldPlacementLabel != nil {
                // Prefer the frontmost actual rendered surface. Previously the
                // point-cloud fallback ran first, so clicking an aligned model
                // could select a depth vertex hidden well behind that model.
                if let surfaceHit = hits.compactMap({ hit -> (
                    SCNHitTestResult, ReceiverSceneSelection.Surface
                )? in
                    placementSurface(for: hit).map { (hit, $0) }
                }).first {
                    acceptWorldPlacement(
                        worldCoordinates: surfaceHit.0.worldCoordinates,
                        surface: surfaceHit.1,
                        faceIndex: surfaceHit.0.faceIndex >= 0
                            ? surfaceHit.0.faceIndex : nil)
                    return
                }

                // SceneKit does not consistently hit point primitives. For an
                // exposed LiDAR/fused-depth point, use a tightly bounded screen
                // snap to an actual displayed metric vertex instead.
                guard let snapped = nearestMetricPoint(to: point, in: view) else {
                    loadError.wrappedValue =
                        "That click did not intersect a visible surface. Zoom in and click directly on the model, LiDAR mesh, or a fused-depth point."
                    return
                }
                acceptWorldPlacement(
                    point: snapped.point,
                    surface: snapped.surface,
                    faceIndex: snapped.pointIndex)
                return
            }

            guard let hit = hits.first(where: {
                $0.node.categoryBitMask & ReceiverSceneCategory.selectable != 0
            }) else {
                selection.wrappedValue = nil
                selectionMarker?.removeFromParentNode()
                selectionMarker = nil
                return
            }

            let category = hit.node.categoryBitMask
            let surface: ReceiverSceneSelection.Surface
            if category & ReceiverSceneCategory.annotation != 0 {
                surface = .annotation(hit.node.name ?? "marker")
            } else if category & ReceiverSceneCategory.fusedDepth != 0 {
                surface = .fusedDepth
            } else if category & ReceiverSceneCategory.photogrammetry != 0 {
                surface = .photogrammetry(aligned: photogrammetryAligned)
            } else {
                surface = .lidar
            }
            let p = hit.worldCoordinates
            if worldPlacementLabel != nil,
               surface == .lidar || surface == .fusedDepth
                    || surface == .photogrammetry(aligned: true) {
                onWorldPointPicked?(
                    SIMD3(Double(p.x), Double(p.y), Double(p.z)))
            }
            if case .photogrammetry = surface,
               photogrammetryPlacementLabel != nil,
               let photogrammetryRoot,
               let onPhotogrammetryPointPicked {
                let modelPoint = photogrammetryRoot.simdConvertPosition(
                    SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)), from: nil)
                onPhotogrammetryPointPicked(modelPoint)
            }
            let result = ReceiverSceneSelection(
                surface: surface,
                worldPosition: SIMD3(Double(p.x), Double(p.y), Double(p.z)),
                faceIndex: hit.faceIndex >= 0 ? hit.faceIndex : nil)
            selection.wrappedValue = result
            installSelectionMarker(result)
        }

        private func placementSurface(
            for hit: SCNHitTestResult
        ) -> ReceiverSceneSelection.Surface? {
            let category = hit.node.categoryBitMask
            // SCNView may return a nominal hit for `.point` primitives whose
            // worldCoordinates are unrelated to the rendered vertex. Never use
            // that coordinate for a fiducial. Point clouds are handled below by
            // nearestMetricPoint, which returns an actual stored world vertex.
            guard isTriangleSurface(hit) else { return nil }
            if category & ReceiverSceneCategory.lidar != 0 {
                return .lidar
            }
            if category & ReceiverSceneCategory.photogrammetry != 0,
               photogrammetryAligned {
                return .photogrammetry(aligned: true)
            }
            return nil
        }

        private func isTriangleSurface(_ hit: SCNHitTestResult) -> Bool {
            guard let geometry = hit.node.geometry,
                  geometry.elements.indices.contains(hit.geometryIndex) else {
                return false
            }
            switch geometry.elements[hit.geometryIndex].primitiveType {
            case .triangles, .triangleStrip, .polygon:
                return true
            case .line, .point:
                return false
            @unknown default:
                return false
            }
        }

        private func acceptWorldPlacement(
            worldCoordinates: SCNVector3,
            surface: ReceiverSceneSelection.Surface,
            faceIndex: Int?
        ) {
            acceptWorldPlacement(
                point: SIMD3(
                    Float(worldCoordinates.x), Float(worldCoordinates.y),
                    Float(worldCoordinates.z)),
                surface: surface,
                faceIndex: faceIndex)
        }

        private func acceptWorldPlacement(
            point: SIMD3<Float>,
            surface: ReceiverSceneSelection.Surface,
            faceIndex: Int?
        ) {
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                loadError.wrappedValue = "The selected surface returned an invalid coordinate."
                return
            }
            loadError.wrappedValue = nil
            let world = SIMD3(Double(point.x), Double(point.y), Double(point.z))
            onWorldPointPicked?(world)
            let result = ReceiverSceneSelection(
                surface: surface,
                worldPosition: world,
                faceIndex: faceIndex)
            selection.wrappedValue = result
            installSelectionMarker(result)
        }

        private func nearestMetricPoint(
            to click: CGPoint, in view: SCNView
        ) -> ReceiverMetricPlacementPoint? {
            let maximumScreenDistance: CGFloat = 12
            let maximumSquared = maximumScreenDistance * maximumScreenDistance
            var best: ReceiverMetricPlacementPoint?
            var bestSquared = CGFloat.greatestFiniteMagnitude
            var bestDepth = CGFloat.greatestFiniteMagnitude

            for candidate in metricPlacementPoints {
                let projected = view.projectPoint(SCNVector3(candidate.point))
                guard projected.z >= 0, projected.z <= 1 else { continue }
                let dx = CGFloat(projected.x) - click.x
                let dy = CGFloat(projected.y) - click.y
                let squared = dx * dx + dy * dy
                guard squared <= maximumSquared else { continue }
                // Within the small snap radius, choose the frontmost visible
                // layer first. Screen distance breaks ties on that layer.
                if CGFloat(projected.z) < bestDepth - 0.002
                    || (abs(CGFloat(projected.z) - bestDepth) <= 0.002
                        && squared < bestSquared) {
                    best = candidate
                    bestSquared = squared
                    bestDepth = CGFloat(projected.z)
                }
            }
            return best
        }

        func installSelectionMarker(_ selection: ReceiverSceneSelection?) {
            selectionMarker?.removeFromParentNode()
            selectionMarker = nil
            guard let selection, let scene = view?.scene else { return }
            let sphere = SCNSphere(radius: 0.0045)
            sphere.segmentCount = 18
            let material = SCNMaterial()
            material.diffuse.contents = NSColor.systemYellow
            material.emission.contents = NSColor.systemYellow
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.name = "Selected point"
            node.categoryBitMask = ReceiverSceneCategory.selection
            node.simdPosition = SIMD3(
                Float(selection.worldPosition.x),
                Float(selection.worldPosition.y),
                Float(selection.worldPosition.z))
            scene.rootNode.addChildNode(node)
            selectionMarker = node
        }
    }
}

private enum ReceiverSceneCategory {
    static let lidar = 1 << 0
    static let fusedDepth = 1 << 1
    static let photogrammetry = 1 << 2
    static let annotation = 1 << 3
    static let selection = 1 << 4
    /// Diagnostic-only overlays (head bounding box cube, world-target-landmark
    /// mismatch lines/spheres): useful to look at, but must never influence
    /// where the camera thinks "the head" is - unlike real annotations
    /// (electrodes/fiducials), which "Sensors Only" framing deliberately does
    /// fit to.
    static let diagnosticOverlay = 1 << 5
    static let selectable = lidar | fusedDepth | photogrammetry | annotation
}

private enum ReceiverSceneBuildError: LocalizedError {
    case invalidLiDAR(String)
    case invalidPhotogrammetry(String)

    var errorDescription: String? {
        switch self {
        case .invalidLiDAR(let name): "Could not decode LiDAR mesh \(name)."
        case .invalidPhotogrammetry(let name): "Could not load photogrammetry model \(name)."
        }
    }
}

private struct ReceiverMetricPlacementPoint {
    var point: SIMD3<Float>
    var surface: ReceiverSceneSelection.Surface
    var pointIndex: Int
}

@MainActor
private enum ReceiverSceneBuilder {
    struct Result {
        var scene: SCNScene
        var surfaceRoot: SCNNode
        var photogrammetryRoot: SCNNode?
        var metricPlacementPoints: [ReceiverMetricPlacementPoint]
        /// Non-fatal problems loading individual surfaces (e.g. a corrupted
        /// LiDAR or photogrammetry file). One broken surface must not blank the
        /// rest of the scene - fused depth, the other surface, annotations, and
        /// the bounding box cube all still build regardless.
        var partialLoadWarnings: [String] = []
    }

    static func build(
        assets: ReceiverSceneAssets,
        fusedDepth: ReceiverFusedDepthCloud?,
        settings: ReceiverSceneSettings,
        electrodes: [MANTAElectrodeSolution],
        fiducials: [MANTAFiducialSolution],
        modelLandmarks: [ReceiverModelLandmark],
        worldTargetLandmarks: [ReceiverModelLandmark] = []
    ) throws -> Result {
        let scene = SCNScene()
        let surfaceRoot = SCNNode()
        surfaceRoot.name = "Capture surfaces"
        scene.rootNode.addChildNode(surfaceRoot)
        var photogrammetryRoot: SCNNode?
        var metricPlacementPoints = [ReceiverMetricPlacementPoint]()
        var partialLoadWarnings = [String]()

        if settings.showLiDAR, let url = assets.url(for: settings.lidarChoice) {
            do {
                guard let mesh = try ReceiverPLYMesh(contentsOf: url) else {
                    throw ReceiverSceneBuildError.invalidLiDAR(url.lastPathComponent)
                }
                let node = mesh.makeNode(style: settings.lidarStyle)
                node.name = settings.lidarChoice.rawValue
                surfaceRoot.addChildNode(node)
                metricPlacementPoints.append(contentsOf: mesh.points.enumerated().map {
                    ReceiverMetricPlacementPoint(
                        point: $0.element, surface: .lidar, pointIndex: $0.offset)
                })
            } catch {
                partialLoadWarnings.append(
                    ReceiverSceneBuildError.invalidLiDAR(url.lastPathComponent).errorDescription
                        ?? "Could not load LiDAR mesh.")
            }
        }

        if settings.showFusedDepth, let fusedDepth {
            let node = fusedDepth.makeNode()
            node.name = "Fused RGB-D"
            node.categoryBitMask = ReceiverSceneCategory.fusedDepth
            surfaceRoot.addChildNode(node)
            metricPlacementPoints.append(contentsOf: fusedDepth.points.enumerated().map {
                ReceiverMetricPlacementPoint(
                    point: $0.element, surface: .fusedDepth, pointIndex: $0.offset)
            })
        }

        if settings.showPhotogrammetry, let url = assets.photogrammetryURL {
            if let loaded = try? SCNScene(url: url, options: nil) {
                let holder = SCNNode()
                holder.name = "Photogrammetry"
                loaded.rootNode.childNodes.forEach { holder.addChildNode($0.clone()) }
                if let transform = assets.modelToWorld { holder.simdTransform = transform }
                markPhotogrammetryNodes(holder)
                addModelLandmarks(modelLandmarks, to: holder)
                surfaceRoot.addChildNode(holder)
                photogrammetryRoot = holder
            } else {
                partialLoadWarnings.append(
                    ReceiverSceneBuildError.invalidPhotogrammetry(url.lastPathComponent).errorDescription
                        ?? "Could not load photogrammetry model.")
            }
        }

        if settings.showAnnotations {
            addAnnotations(electrodes: electrodes, fiducials: fiducials, to: surfaceRoot)
        }
        if !worldTargetLandmarks.isEmpty {
            addWorldTargetLandmarks(
                worldTargetLandmarks,
                modelLandmarks: modelLandmarks,
                modelToWorld: assets.modelToWorld,
                to: surfaceRoot)
        }
        if settings.showHeadBoundingBox {
            surfaceRoot.addChildNode(headBoundingBoxNode(
                center: settings.headBoundingBoxCenter,
                halfExtent: settings.headBoundingBoxHalfExtent))
        }

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 420
        ambient.color = NSColor(white: 0.72, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1_100
        key.castsShadow = false
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.7, 0.6, 0)
        scene.rootNode.addChildNode(keyNode)

        return Result(
            scene: scene,
            surfaceRoot: surfaceRoot,
            photogrammetryRoot: photogrammetryRoot,
            metricPlacementPoints: metricPlacementPoints,
            partialLoadWarnings: partialLoadWarnings)
    }

    static func cameraNode() -> SCNNode {
        let camera = SCNCamera()
        camera.zNear = 0.001
        camera.zFar = 100
        camera.fieldOfView = 42
        let node = SCNNode()
        node.name = "Interactive camera"
        node.camera = camera
        return node
    }

    @discardableResult
    static func frame(view: SCNView, surfaceRoot: SCNNode) -> Bool {
        guard let bounds = worldBounds(of: surfaceRoot) else { return false }
        let center = (bounds.min + bounds.max) / 2
        let diagonal = simd_length(bounds.max - bounds.min)
        let radius = max(0.05, diagonal / 2)
        let camera = cameraNode()

        // Fit the bounding sphere within BOTH the vertical and horizontal fields
        // of view for the actual viewport aspect. The previous fixed-multiplier
        // distance ignored aspect, so a tall/narrow panel (like the new equal-
        // width Align panels) cropped the model and made orbit pivot off-screen.
        let verticalFOV = Float(camera.camera?.fieldOfView ?? 42) * .pi / 180
        let aspect = Float(max(view.bounds.width, 1) / max(view.bounds.height, 1))
        let horizontalFOV = 2 * atan(tan(verticalFOV / 2) * aspect)
        let fitVertical = radius / max(sin(verticalFOV / 2), 0.05)
        let fitHorizontal = radius / max(sin(horizontalFOV / 2), 0.05)
        let distance = max(0.30, max(fitVertical, fitHorizontal) * 1.15)

        camera.simdPosition = center + SIMD3(0, radius * 0.12, distance)
        camera.look(at: SCNVector3(center))
        camera.camera?.zFar = Double(max(10, distance * 20))
        view.scene?.rootNode.addChildNode(camera)
        view.pointOfView = camera
        view.defaultCameraController.target = SCNVector3(center)
        return true
    }

    private static func worldBounds(of root: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        // Real content (surfaces, electrode/fiducial annotations - "Sensors
        // Only" framing depends on the latter) sets where the camera fits.
        // Diagnostic-only overlays and the transient selection marker must not:
        // the head bounding box cube (before its declared value is seeded, or
        // while being edited) and the world-target mismatch lines (which, by
        // definition, stretch away from the head exactly when alignment is
        // bad) previously dragged the orbit's pivot off the head entirely.
        let excludedCategories = ReceiverSceneCategory.diagnosticOverlay
            | ReceiverSceneCategory.selection
        root.enumerateChildNodes { node, _ in
            guard node.geometry != nil, node.categoryBitMask & excludedCategories == 0 else { return }
            let box = node.boundingBox
            let corners = [
                SIMD3(Float(box.min.x), Float(box.min.y), Float(box.min.z)),
                SIMD3(Float(box.max.x), Float(box.min.y), Float(box.min.z)),
                SIMD3(Float(box.min.x), Float(box.max.y), Float(box.min.z)),
                SIMD3(Float(box.max.x), Float(box.max.y), Float(box.min.z)),
                SIMD3(Float(box.min.x), Float(box.min.y), Float(box.max.z)),
                SIMD3(Float(box.max.x), Float(box.min.y), Float(box.max.z)),
                SIMD3(Float(box.min.x), Float(box.max.y), Float(box.max.z)),
                SIMD3(Float(box.max.x), Float(box.max.y), Float(box.max.z))
            ]
            for corner in corners {
                let world = node.simdConvertPosition(corner, to: nil)
                minimum = simd_min(minimum, world)
                maximum = simd_max(maximum, world)
                found = true
            }
        }
        return found ? (minimum, maximum) : nil
    }

    private static func markPhotogrammetryNodes(_ root: SCNNode) {
        root.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
            node.categoryBitMask = ReceiverSceneCategory.photogrammetry
            node.name = "Photogrammetry"
        }
    }

    private static func addModelLandmarks(
        _ landmarks: [ReceiverModelLandmark], to root: SCNNode
    ) {
        for landmark in landmarks {
            let sphere = SCNSphere(radius: 0.0045)
            sphere.segmentCount = 18
            let material = SCNMaterial()
            material.diffuse.contents = NSColor.systemPink
            material.emission.contents = NSColor.systemPink.withAlphaComponent(0.5)
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.name = landmark.kind.rawValue
            node.categoryBitMask = ReceiverSceneCategory.annotation
            node.simdPosition = landmark.point
            root.addChildNode(node)
        }
    }

    /// Renders the resolved image-click world points (cyan) attached directly to
    /// `root` in world space - unlike the pink model landmarks, these do not move
    /// when the photogrammetry model reposes. When a candidate `modelToWorld`
    /// transform exists, also draws a line from each model landmark's transformed
    /// world position to its matching world-target point, color-coded by residual,
    /// so an alignment problem is visible instead of only reported as an RMS
    /// number.
    private static func addWorldTargetLandmarks(
        _ landmarks: [ReceiverModelLandmark],
        modelLandmarks: [ReceiverModelLandmark],
        modelToWorld: simd_float4x4?,
        to root: SCNNode
    ) {
        for landmark in landmarks {
            let sphere = SCNSphere(radius: 0.0055)
            sphere.segmentCount = 18
            let material = SCNMaterial()
            material.diffuse.contents = NSColor.systemCyan
            material.emission.contents = NSColor.systemCyan.withAlphaComponent(0.6)
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.name = "\(landmark.kind.rawValue) (image target)"
            node.categoryBitMask = ReceiverSceneCategory.diagnosticOverlay
            node.simdPosition = landmark.point
            root.addChildNode(node)

            guard let modelToWorld,
                  let paired = modelLandmarks.first(where: { $0.kind == landmark.kind })
            else { continue }
            let mapped = modelToWorld * SIMD4<Float>(paired.point, 1)
            let modelWorldPoint = SIMD3<Float>(mapped.x, mapped.y, mapped.z)
            let residual = simd_distance(modelWorldPoint, landmark.point)
            root.addChildNode(residualLine(
                from: modelWorldPoint, to: landmark.point, residual: residual))
        }
    }

    /// A thin line between a model landmark's world position and its matching
    /// image-click target, colored green/yellow/red by how far apart they are.
    private static func residualLine(
        from: SIMD3<Float>, to: SIMD3<Float>, residual: Float
    ) -> SCNNode {
        let color: NSColor = residual <= 0.015 ? .systemGreen
            : residual <= 0.030 ? .systemYellow : .systemRed
        let vertices = [SCNVector3(from), SCNVector3(to)]
        let source = SCNGeometrySource(vertices: vertices)
        let indices: [Int32] = [0, 1]
        let element = SCNGeometryElement(
            data: Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size),
            primitiveType: .line,
            primitiveCount: 1,
            bytesPerIndex: MemoryLayout<Int32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = ReceiverSceneCategory.diagnosticOverlay
        return node
    }

    /// A wireframe cube showing the head bounding box that gates what counts as
    /// "the head" when building Fused Depth and the LiDAR-crop alignment
    /// fallback - editable from the sidebar so a box that clips real surface
    /// (an ear, the crown) can be caught by eye and widened.
    private static func headBoundingBoxNode(
        center: SIMD3<Float>, halfExtent: SIMD3<Float>
    ) -> SCNNode {
        let box = SCNBox(
            width: CGFloat(halfExtent.x * 2), height: CGFloat(halfExtent.y * 2),
            length: CGFloat(halfExtent.z * 2), chamferRadius: 0)
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemOrange
        material.emission.contents = NSColor.systemOrange
        material.lightingModel = .constant
        material.fillMode = .lines
        material.isDoubleSided = true
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.name = "Head bounding box"
        node.categoryBitMask = ReceiverSceneCategory.diagnosticOverlay
        node.simdPosition = center
        return node
    }

    private static func addAnnotations(
        electrodes: [MANTAElectrodeSolution],
        fiducials: [MANTAFiducialSolution],
        to root: SCNNode
    ) {
        for electrode in electrodes where electrode.coordinate.count == 3 {
            let color: NSColor
            if electrode.confidence == 0 || electrode.state == "Missing" {
                color = .systemGray
            } else if electrode.state == "Reviewed" {
                color = .systemGreen
            } else if electrode.state == "Guessed" {
                color = .systemYellow
            } else {
                color = .systemOrange
            }
            addMarker(
                electrode.coordinate,
                label: electrode.label,
                color: color,
                to: root)
        }
        for fiducial in fiducials {
            guard let coordinate = fiducial.coordinate, coordinate.count == 3 else { continue }
            addMarker(coordinate, label: fiducial.kind, color: .systemPurple, to: root)
        }
    }

    private static func addMarker(
        _ coordinate: [Double], label: String, color: NSColor, to root: SCNNode
    ) {
        let sphere = SCNSphere(radius: 0.0035)
        sphere.segmentCount = 16
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.35)
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.name = label
        node.categoryBitMask = ReceiverSceneCategory.annotation
        node.simdPosition = SIMD3(coordinate.map(Float.init))
        root.addChildNode(node)
    }
}

@MainActor
struct ReceiverPLYMesh {
    let points: [SIMD3<Float>]
    let vertices: [SCNVector3]
    let normals: [SCNVector3]
    let indices: [UInt32]

    // Parsing raw PLY bytes touches no AppKit/SceneKit state, so this needs no
    // main-actor isolation - callers off the main thread (e.g. background
    // bounding-box recrop) can construct one directly. Only `makeNode` builds
    // actual SceneKit UI objects and stays main-actor.
    nonisolated init?(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let marker = data.range(of: Data("end_header\n".utf8)) else { return nil }
        let header = String(decoding: data[..<marker.lowerBound], as: UTF8.self)
        guard header.contains("format binary_little_endian 1.0") else { return nil }
        var vertexCount = 0
        var faceCount = 0
        for line in header.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[0] == "element" else { continue }
            if fields[1] == "vertex" { vertexCount = Int(fields[2]) ?? 0 }
            if fields[1] == "face" { faceCount = Int(fields[2]) ?? 0 }
        }
        guard vertexCount > 0, faceCount > 0 else { return nil }

        let bytes = data[marker.upperBound...]
        var offset = bytes.startIndex
        func readUInt32() -> UInt32? {
            guard offset + 4 <= bytes.endIndex else { return nil }
            let value = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return value
        }

        var simdVertices = [SIMD3<Float>]()
        simdVertices.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            guard let x = readUInt32(), let y = readUInt32(), let z = readUInt32() else {
                return nil
            }
            let point = SIMD3(
                Float(bitPattern: x), Float(bitPattern: y), Float(bitPattern: z))
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
            simdVertices.append(point)
        }

        var indices = [UInt32]()
        indices.reserveCapacity(faceCount * 3)
        for _ in 0..<faceCount {
            guard offset < bytes.endIndex, bytes[offset] == 3 else { return nil }
            offset += 1
            guard let a = readUInt32(), let b = readUInt32(), let c = readUInt32(),
                  a < UInt32(vertexCount), b < UInt32(vertexCount),
                  c < UInt32(vertexCount) else { return nil }
            indices.append(contentsOf: [a, b, c])
        }

        var simdNormals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for face in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[face])
            let b = Int(indices[face + 1])
            let c = Int(indices[face + 2])
            let normal = simd_cross(
                simdVertices[b] - simdVertices[a],
                simdVertices[c] - simdVertices[a])
            if simd_length_squared(normal) > 1e-12 {
                simdNormals[a] += normal
                simdNormals[b] += normal
                simdNormals[c] += normal
            }
        }
        simdNormals = simdNormals.map {
            simd_length_squared($0) > 1e-12 ? simd_normalize($0) : SIMD3(0, 1, 0)
        }

        points = simdVertices
        vertices = simdVertices.map(SCNVector3.init)
        normals = simdNormals.map(SCNVector3.init)
        self.indices = indices
    }

    func makeNode(style: ReceiverLiDARStyle) -> SCNNode {
        if style == .pointCloud {
            return makePointCloudNode()
        }

        let sources = [
            SCNGeometrySource(vertices: vertices),
            SCNGeometrySource(normals: normals)
        ]
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.diffuse.contents = NSColor.systemTeal.withAlphaComponent(
            style == .solid ? 1.0 : 0.9)
        material.emission.contents = NSColor.systemTeal.withAlphaComponent(0.08)
        material.roughness.contents = 0.82
        material.metalness.contents = 0.02
        material.fillMode = style == .solid ? .fill : .lines
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = ReceiverSceneCategory.lidar
        return node
    }

    private func makePointCloudNode() -> SCNNode {
        let source = SCNGeometrySource(vertices: vertices)
        let pointIndices = Array(UInt32(0)..<UInt32(vertices.count))
        let indexData = pointIndices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: vertices.count,
            bytesPerIndex: MemoryLayout<UInt32>.size)
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 7

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.systemTeal.withAlphaComponent(0.92)
        material.emission.contents = NSColor.systemTeal.withAlphaComponent(0.12)
        material.writesToDepthBuffer = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = ReceiverSceneCategory.lidar
        return node
    }
}

private extension SCNVector3 {
    init(_ value: SIMD3<Float>) {
        self.init(value.x, value.y, value.z)
    }
}
