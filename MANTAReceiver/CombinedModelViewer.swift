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

    @State private var showLiDAR: Bool
    @State private var showPhotogrammetry: Bool
    @State private var showFusedDepth = false
    @State private var showAnnotations = true
    @State private var lidarChoice: ReceiverLiDARChoice
    @State private var lidarStyle = ReceiverLiDARStyle.solid
    @State private var selection: ReceiverSceneSelection?
    @State private var loadError: String?
    @State private var frameRequest = 0
    @State private var fusedDepth: ReceiverFusedDepthCloud?
    @State private var fusionState = ReceiverFusionState.unavailable
    @State private var fiducialPlacementKind: FiducialKind?
    @State private var fiducialOverrides = [FiducialKind: SIMD3<Double>]()

    init(
        bundle: MANTAValidatedBundle,
        modelToWorldOverride: simd_float4x4? = nil,
        photogrammetryURLOverride: URL? = nil,
        photogrammetryPlacementLabel: String? = nil,
        modelLandmarks: [ReceiverModelLandmark] = [],
        onPhotogrammetryPointPicked: ((SIMD3<Float>) -> Void)? = nil,
        fiducialSaveInProgress: Bool = false,
        onFiducialsSaved: (([MANTAFiducialSolution]) -> Void)? = nil
    ) {
        self.bundle = bundle
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
        self.onPhotogrammetryPointPicked = onPhotogrammetryPointPicked
        self.onFiducialsSaved = onFiducialsSaved
        self.fiducialSaveInProgress = fiducialSaveInProgress
        let initialLiDAR = assets.defaultLiDARChoice
        _lidarChoice = State(initialValue: initialLiDAR ?? .fullEnvironment)
        _showLiDAR = State(initialValue: photogrammetryPlacementLabel == nil && initialLiDAR != nil)
        _showPhotogrammetry = State(
            initialValue: assets.photogrammetryURL != nil
                && (photogrammetryPlacementLabel != nil
                    || initialLiDAR == nil || assets.modelToWorld != nil))
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            ZStack {
                if assets.hasAnySurface || fusedDepth != nil || fusionState == .loading {
                    ReceiverCombinedSceneView(
                        assets: assets,
                        fusedDepth: fusedDepth,
                        settings: ReceiverSceneSettings(
                            showLiDAR: showLiDAR,
                            showPhotogrammetry: showPhotogrammetry,
                            showFusedDepth: showFusedDepth,
                            showAnnotations: showAnnotations && annotationsAreSpatiallyValid,
                            lidarChoice: lidarChoice,
                            lidarStyle: lidarStyle),
                        electrodes: bundle.capture.electrodes ?? [],
                        fiducials: displayedFiducials,
                        modelLandmarks: modelLandmarks,
                        selection: $selection,
                        loadError: $loadError,
                        frameRequest: frameRequest,
                        photogrammetryPlacementLabel: photogrammetryPlacementLabel,
                        onPhotogrammetryPointPicked: onPhotogrammetryPointPicked,
                        fiducialPlacementKind: fiducialPlacementKind,
                        onWorldFiducialPointPicked: placeFiducial)
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
            }
        }
        .task(id: bundle.manifest.bundleID) {
            if photogrammetryPlacementLabel == nil {
                await loadDepthFusion()
            }
        }
        .onChange(of: bundle.manifest.bundleID) { _, _ in
            fiducialPlacementKind = nil
            fiducialOverrides.removeAll()
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Toggle("LiDAR", isOn: lidarVisibility)
                .disabled(assets.defaultLiDARChoice == nil)

            if assets.lidarChoices.count > 1 {
                Picker("LiDAR mesh", selection: $lidarChoice) {
                    ForEach(assets.lidarChoices) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Picker("LiDAR style", selection: $lidarStyle) {
                ForEach(ReceiverLiDARStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .labelsHidden()
            .frame(width: 125)
            .disabled(!showLiDAR)

            Toggle("Photogrammetry", isOn: photogrammetryVisibility)
                .disabled(assets.photogrammetryURL == nil)

            Toggle("Fused Depth", isOn: $showFusedDepth)
                .disabled(fusedDepth == nil)

            if fusionState == .loading {
                ProgressView()
                    .controlSize(.small)
                    .help("Fusing confidence-filtered RGB-D observations")
            }

            Toggle("Annotations", isOn: $showAnnotations)
                .disabled(!hasAnnotations || !annotationsAreSpatiallyValid)

            if onFiducialsSaved != nil {
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
                    if fiducialSaveInProgress {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Spacer()

            Button("Frame All", systemImage: "viewfinder") {
                frameRequest &+= 1
            }
            .keyboardShortcut("f", modifiers: [])
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var lidarVisibility: Binding<Bool> {
        Binding(
            get: { showLiDAR },
            set: { enabled in
                showLiDAR = enabled
                if enabled, showPhotogrammetry, !assets.canOverlay {
                    showPhotogrammetry = false
                }
                selection = nil
            })
    }

    private var photogrammetryVisibility: Binding<Bool> {
        Binding(
            get: { showPhotogrammetry },
            set: { enabled in
                showPhotogrammetry = enabled
                if enabled, showLiDAR, !assets.canOverlay {
                    showLiDAR = false
                }
                selection = nil
            })
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
        Text(fiducialPlacementKind.map {
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
        !(bundle.capture.electrodes ?? []).isEmpty
            || !assets.fiducials.isEmpty
    }

    private var hasWorldPlacementSurface: Bool {
        showLiDAR || showFusedDepth || (showPhotogrammetry && assets.modelToWorld != nil)
    }

    private var displayedFiducials: [MANTAFiducialSolution] {
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

    private func placeFiducial(_ point: SIMD3<Double>) {
        guard let kind = fiducialPlacementKind else { return }
        fiducialOverrides[kind] = point
        fiducialPlacementKind = nil
        showAnnotations = true
        selection = nil
    }

    private var annotationsAreSpatiallyValid: Bool {
        showLiDAR || showFusedDepth || (showPhotogrammetry && assets.modelToWorld != nil)
    }

    @MainActor
    private func loadDepthFusion() async {
        guard fusedDepth == nil, let input = assets.fusionInput else {
            if assets.fusionInput == nil { fusionState = .unavailable }
            return
        }
        fusionState = .loading
        do {
            let cloud = try await Task.detached(priority: .userInitiated) {
                try ReceiverDepthFusion.fuse(input)
            }.value
            guard !Task.isCancelled else { return }
            fusedDepth = cloud
            showFusedDepth = true
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

private enum ReceiverLiDARChoice: String, CaseIterable, Identifiable, Hashable {
    case headRegion = "Head Region"
    case fullEnvironment = "Full Environment"
    var id: String { rawValue }
}

private enum ReceiverLiDARStyle: String, CaseIterable, Identifiable, Hashable {
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

    init(bundle: MANTAValidatedBundle, photogrammetryURLOverride: URL? = nil) {
        let reconstruction = bundle.capture.reconstruction
        fullLiDARURL = Self.existingURL(
            root: bundle.rootDirectory, path: reconstruction?.lidarMeshPath)
        headLiDARURL = Self.existingURL(
            root: bundle.rootDirectory, path: reconstruction?.headCroppedLidarMeshPath)
        photogrammetryURL = photogrammetryURLOverride ?? Self.existingURL(
            root: bundle.rootDirectory, path: reconstruction?.objectCaptureModelPath)
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
    @Binding var selection: ReceiverSceneSelection?
    @Binding var loadError: String?
    let frameRequest: Int
    let photogrammetryPlacementLabel: String?
    let onPhotogrammetryPointPicked: ((SIMD3<Float>) -> Void)?
    let fiducialPlacementKind: FiducialKind?
    let onWorldFiducialPointPicked: ((SIMD3<Double>) -> Void)?

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
        context.coordinator.onWorldFiducialPointPicked = onWorldFiducialPointPicked
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
                    modelLandmarks: modelLandmarks)
                view.scene = built.scene
                context.coordinator.surfaceRoot = built.surfaceRoot
                context.coordinator.photogrammetryRoot = built.photogrammetryRoot
                context.coordinator.metricPlacementPoints = built.metricPlacementPoints
                context.coordinator.sceneSignature = signature
                context.coordinator.installSelectionMarker(selection)
                setLoadError(nil)

                if let previousCamera, context.coordinator.hasFramedOnce {
                    let camera = ReceiverSceneBuilder.cameraNode()
                    camera.simdTransform = previousCamera
                    built.scene.rootNode.addChildNode(camera)
                    view.pointOfView = camera
                    view.defaultCameraController.target = previousTarget
                } else {
                    ReceiverSceneBuilder.frame(view: view, surfaceRoot: built.surfaceRoot)
                    context.coordinator.hasFramedOnce = true
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
                ReceiverSceneBuilder.frame(view: view, surfaceRoot: root)
                (view as? ReceiverInteractiveSCNView)?.configureCameraInteraction()
            }
        }
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
        var onWorldFiducialPointPicked: ((SIMD3<Double>) -> Void)?
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

            if fiducialPlacementKind != nil {
                // Prefer the frontmost actual rendered surface. Previously the
                // point-cloud fallback ran first, so clicking an aligned model
                // could select a depth vertex hidden well behind that model.
                if let surfaceHit = hits.compactMap({ hit -> (
                    SCNHitTestResult, ReceiverSceneSelection.Surface
                )? in
                    placementSurface(for: hit).map { (hit, $0) }
                }).first {
                    acceptFiducialPlacement(
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
                acceptFiducialPlacement(
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
            if fiducialPlacementKind != nil,
               surface == .lidar || surface == .fusedDepth
                    || surface == .photogrammetry(aligned: true) {
                onWorldFiducialPointPicked?(
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
            if category & ReceiverSceneCategory.lidar != 0 {
                return .lidar
            }
            if category & ReceiverSceneCategory.fusedDepth != 0 {
                return .fusedDepth
            }
            if category & ReceiverSceneCategory.photogrammetry != 0,
               photogrammetryAligned {
                return .photogrammetry(aligned: true)
            }
            return nil
        }

        private func acceptFiducialPlacement(
            worldCoordinates: SCNVector3,
            surface: ReceiverSceneSelection.Surface,
            faceIndex: Int?
        ) {
            acceptFiducialPlacement(
                point: SIMD3(
                    Float(worldCoordinates.x), Float(worldCoordinates.y),
                    Float(worldCoordinates.z)),
                surface: surface,
                faceIndex: faceIndex)
        }

        private func acceptFiducialPlacement(
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
            onWorldFiducialPointPicked?(world)
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
    }

    static func build(
        assets: ReceiverSceneAssets,
        fusedDepth: ReceiverFusedDepthCloud?,
        settings: ReceiverSceneSettings,
        electrodes: [MANTAElectrodeSolution],
        fiducials: [MANTAFiducialSolution],
        modelLandmarks: [ReceiverModelLandmark]
    ) throws -> Result {
        let scene = SCNScene()
        let surfaceRoot = SCNNode()
        surfaceRoot.name = "Capture surfaces"
        scene.rootNode.addChildNode(surfaceRoot)
        var photogrammetryRoot: SCNNode?
        var metricPlacementPoints = [ReceiverMetricPlacementPoint]()

        if settings.showLiDAR, let url = assets.url(for: settings.lidarChoice) {
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
            guard let loaded = try? SCNScene(url: url, options: nil) else {
                throw ReceiverSceneBuildError.invalidPhotogrammetry(url.lastPathComponent)
            }
            let holder = SCNNode()
            holder.name = "Photogrammetry"
            loaded.rootNode.childNodes.forEach { holder.addChildNode($0.clone()) }
            if let transform = assets.modelToWorld { holder.simdTransform = transform }
            markPhotogrammetryNodes(holder)
            addModelLandmarks(modelLandmarks, to: holder)
            surfaceRoot.addChildNode(holder)
            photogrammetryRoot = holder
        }

        if settings.showAnnotations {
            addAnnotations(electrodes: electrodes, fiducials: fiducials, to: scene)
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
            metricPlacementPoints: metricPlacementPoints)
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

    static func frame(view: SCNView, surfaceRoot: SCNNode) {
        guard let bounds = worldBounds(of: surfaceRoot) else { return }
        let center = (bounds.min + bounds.max) / 2
        let diagonal = simd_length(bounds.max - bounds.min)
        let distance = max(0.30, diagonal * 1.55)
        let camera = cameraNode()
        camera.simdPosition = center + SIMD3(0, diagonal * 0.12, distance)
        camera.look(at: SCNVector3(center))
        camera.camera?.zFar = Double(max(10, distance * 20))
        view.scene?.rootNode.addChildNode(camera)
        view.pointOfView = camera
        view.defaultCameraController.target = SCNVector3(center)
    }

    private static func worldBounds(of root: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        root.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
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

    private static func addAnnotations(
        electrodes: [MANTAElectrodeSolution],
        fiducials: [MANTAFiducialSolution],
        to scene: SCNScene
    ) {
        for electrode in electrodes where electrode.coordinate.count == 3 {
            let color: NSColor
            if electrode.confidence == 0 || electrode.state == "Missing" {
                color = .systemGray
            } else if electrode.state == "Reviewed" {
                color = .systemGreen
            } else {
                color = .systemOrange
            }
            addMarker(
                electrode.coordinate,
                label: electrode.label,
                color: color,
                to: scene)
        }
        for fiducial in fiducials {
            guard let coordinate = fiducial.coordinate, coordinate.count == 3 else { continue }
            addMarker(coordinate, label: fiducial.kind, color: .systemPurple, to: scene)
        }
    }

    private static func addMarker(
        _ coordinate: [Double], label: String, color: NSColor, to scene: SCNScene
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
        scene.rootNode.addChildNode(node)
    }
}

@MainActor
private struct ReceiverPLYMesh {
    let points: [SIMD3<Float>]
    let vertices: [SCNVector3]
    let normals: [SCNVector3]
    let indices: [UInt32]

    init?(contentsOf url: URL) throws {
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
