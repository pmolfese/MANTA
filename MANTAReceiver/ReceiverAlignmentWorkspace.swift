import AppKit
import MANTACore
import SwiftUI
import simd

/// How a landmark's world-space target is recovered from its image clicks.
enum TargetResolutionMode: String, CaseIterable, Identifiable {
    /// Unproject a single frame's depth at the clicked pixel (robust-averaged
    /// across repeat clicks). Fast, but inherits that frame's depth bias.
    case depth = "Depth"
    /// Raycast the click through the LiDAR head mesh - one consistent metric
    /// surface, so it sidesteps per-frame depth bias.
    case snapToMesh = "Snap to LiDAR"
    /// Triangulate from the camera rays of the same landmark clicked in several
    /// photos. Uses no depth at all, so it is immune to depth bias entirely -
    /// the right tool for a grazing, cap-covered point like Cz.
    case triangulate = "Triangulate (multi-view)"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .depth:
            return "Each click is placed using that frame's depth map; repeats are averaged."
        case .snapToMesh:
            return "Each click is cast along its camera ray onto the LiDAR head mesh."
        case .triangulate:
            return "Click the same landmark in 2+ photos; its 3D point is where those rays intersect. Depth-independent."
        }
    }
}

struct ReceiverAlignmentWorkspace: View {
    @ObservedObject var store: ReceiverStore
    @ObservedObject var display: ReceiverDisplaySettings
    let bundle: MANTAValidatedBundle
    let ephemeralReconstruction: ReceiverEphemeralReconstruction?

    @State private var selectedKind = FiducialKind.nasion
    @State private var observationIndex = 0
    @State private var orientedImage: ReceiverOrientedFrameImage?
    @State private var targetEvidence = [FiducialKind: [UUID: ReceiverImageFiducialHit]]()
    @State private var sourceLandmarks = [FiducialKind: SIMD3<Float>]()
    // Default to landmark-seeded ICP: the fiducials you place seed the fit, then
    // it refines against the dense fused-depth surface. A pure fiducial fit on 3
    // coplanar points is available but degenerate; ICP against the metric depth
    // constrains the whole surface.
    @State private var strategy = WorldAlignmentStrategy.icp
    @State private var seed = AlignmentSeed.landmarks
    /// Degrees of freedom allowed for the landmark fit. Rigid/similarity/affine
    /// mirror the rigid -> affine -> nonlinear progression from image registration.
    @State private var fitModel = LandmarkFitModel.similarity
    /// How a landmark's world point is recovered from its image clicks.
    @State private var targetMode: TargetResolutionMode = .depth
    /// Gate ICP on a symmetric (bidirectional) surface RMS so a scale-collapsed
    /// fit can't pass on a deceptively low one-way residual.
    @State private var useSymmetricAcceptance = true
    @State private var outcome: ReceiverManualAlignmentOutcome?
    @State private var isSolving = false
    @State private var placementError: String?
    @State private var solveError: String?
    @State private var allowPlausibilityOverride = false
    @State private var debugLogURL: URL?
    @State private var imageZoom: CGFloat = 1
    // Head-cropped LiDAR mesh, loaded once for snap-to-surface raycasting.
    @State private var headMeshVertices: [SIMD3<Float>] = []
    @State private var headMeshIndices: [UInt32] = []
    // Per-landmark distance (m) the last click moved when snapped to the mesh -
    // a large value means that frame's depth disagreed with the surface.
    @State private var snapDistances = [FiducialKind: Float]()
    /// When on, Nasion/LPA/RPA use the device-recorded world fiducials from the
    /// original capture as the alignment target, instead of resolving fresh depth
    /// clicks. Useful when the per-frame depth data has a systematic bias: the
    /// archived fiducials and the LiDAR mesh are independently consistent with
    /// each other, so they sidestep that bias entirely. Cz has no archived value
    /// and always comes from a fresh click. Defaults on: the device fiducials are
    /// consistent with the LiDAR mesh, so they are the better target whenever they
    /// exist (the toggle is only shown when the capture carries them).
    @State private var useArchivedFiducials = true

    private var observations: [MANTACaptureObservation] {
        bundle.capture.observations.filter {
            $0.depth != nil && imagePath(for: $0) != nil
        }
    }

    private var currentObservation: MANTACaptureObservation? {
        observations.indices.contains(observationIndex) ? observations[observationIndex] : nil
    }

    private var modelLandmarks: [ReceiverModelLandmark] {
        FiducialKind.allCases.compactMap { kind in
            sourceLandmarks[kind].map { ReceiverModelLandmark(kind: kind, point: $0) }
        }
    }

    /// The resolved image-click world points (robust center across views), shown
    /// in the 3D panel as cyan markers alongside the pink model landmarks so a
    /// mismatch is visible directly instead of only as a residual number.
    private var worldTargetLandmarks: [ReceiverModelLandmark] {
        FiducialKind.allCases.compactMap { kind in
            worldTarget(for: kind).map { ReceiverModelLandmark(kind: kind, point: $0) }
        }
    }

    /// Device-recorded world fiducials from the original capture, keyed by kind.
    private var archivedFiducials: [FiducialKind: SIMD3<Float>] {
        Dictionary(uniqueKeysWithValues: (bundle.capture.fiducials ?? []).compactMap {
            fiducial -> (FiducialKind, SIMD3<Float>)? in
            guard fiducial.coordinateSystem == "arkit-world",
                  let coordinate = fiducial.coordinate, coordinate.count == 3,
                  let kind = FiducialKind(rawValue: fiducial.kind) else { return nil }
            return (kind, SIMD3(coordinate.map(Float.init)))
        })
    }

    private var hasArchivedCaptureFiducials: Bool { !archivedFiducials.isEmpty }

    /// The world-space point used for `kind`: the archived capture fiducial when
    /// the override is on and one exists, otherwise the robust center of this
    /// session's image clicks.
    private func worldTarget(for kind: FiducialKind) -> SIMD3<Float>? {
        if useArchivedFiducials, let archived = archivedFiducials[kind] { return archived }
        if targetMode == .triangulate, let result = triangulation(for: kind) {
            return result.point
        }
        return targetSummary(for: kind)?.center
    }

    /// Camera rays for every image click of `kind`, for depth-free triangulation.
    private func rays(
        for kind: FiducialKind
    ) -> [(origin: SIMD3<Float>, direction: SIMD3<Float>)] {
        guard let hits = targetEvidence[kind] else { return [] }
        return hits.compactMap { observationID, hit in
            guard let observation = observations.first(where: { $0.id == observationID }),
                  let camera = PinholeCamera(
                    intrinsics: observation.intrinsics.map(Float.init),
                    transform: observation.cameraToWorld.map(Float.init)) else { return nil }
            let column = camera.cameraToWorld.columns.3
            let origin = SIMD3<Float>(column.x, column.y, column.z)
            let along = camera.unproject(pixel: hit.rawImagePoint, depth: 1)
            return (origin, along - origin)
        }
    }

    private func triangulation(for kind: FiducialKind) -> MultiViewTriangulation.Result? {
        MultiViewTriangulation.triangulate(rays: rays(for: kind))
    }

    var body: some View {
        Group {
            if modelURL == nil {
                ContentUnavailableView(
                    "Reconstruct a model first",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("The alignment workspace needs a photogrammetry model. Run a Mac reconstruction, then return here."))
            } else if observations.isEmpty {
                ContentUnavailableView(
                    "No RGB-D frames",
                    systemImage: "camera.badge.ellipsis",
                    description: Text("Image fiducial placement needs saved images with metric depth and camera calibration."))
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        modelPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        imagePanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                    bottomDeck
                }
            }
        }
        .task(id: currentObservation?.id) { loadCurrentImage() }
        .task { loadHeadMesh() }
    }

    /// A bounded sidebar avoids the oversized intrinsic width that VSplitView
    /// can assign to text-heavy children. The explicit divider also makes image
    /// resizing discoverable and leaves every control reachable by scrolling.
    private func panelHeader(
        _ title: String, trailing: AnyView? = nil, subrow: AnyView? = nil
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            subrow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // LEFT: the 3D photogrammetry model you click on. Orbits + scroll-zooms.
    // The landmark picker lives here, above the model, since it's what governs
    // which landmark a click on the model places.
    private var modelPanel: some View {
        VStack(spacing: 0) {
            panelHeader(
                "3D model",
                trailing: AnyView(landmarkLegend),
                subrow: AnyView(landmarkPickerBar))
            CombinedModelViewer(
                bundle: bundle,
                display: display,
                modelToWorldOverride: outcome?.result.transform
                    ?? ephemeralReconstruction?.modelToWorld,
                photogrammetryURLOverride: ephemeralReconstruction?.modelURL,
                photogrammetryPlacementLabel: selectedKind.rawValue,
                modelLandmarks: modelLandmarks,
                worldTargetLandmarks: worldTargetLandmarks,
                onPhotogrammetryPointPicked: { point in
                    sourceLandmarks[selectedKind] = point
                    invalidateSolve()
                },
                // Archived capture fiducials live in ARKit-world meters; drawing
                // them beside model-space placement picks mixes two frames.
                includesFiducialAnnotations: false)
        }
    }

    private var landmarkLegend: some View {
        HStack(spacing: 10) {
            legendDot(.pink, "model click")
            legendDot(.cyan, "image target")
            Text("line = mismatch (green ≤15mm, yellow ≤30mm, red >30mm)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }

    // RIGHT: the RGB-D image you click on. Scroll wheel, pinch, or +/- to zoom.
    // The depth-frame selector lives here, above the photo, since it picks
    // which photo is showing.
    private var imagePanel: some View {
        VStack(spacing: 0) {
            panelHeader(
                "RGB-D image · \(selectedKind.rawValue)",
                trailing: AnyView(ReceiverZoomControls(zoom: $imageZoom, maximumZoom: 6)),
                subrow: AnyView(frameNavBar))

            ReceiverZoomableImageArea(zoom: $imageZoom, maximumZoom: 6) {
                ReceiverFiducialImageCanvas(
                    image: orientedImage,
                    observation: currentObservation,
                    hits: currentObservation.flatMap { targetEvidence[selectedKind]?[$0.id] }.map { [$0] } ?? []
                ) { rawPoint in
                    placeTarget(at: rawPoint)
                }
            }
        }
    }

    // A single control deck spanning the full width beneath both panels. The
    // landmark picker and depth-frame selector now live above their respective
    // panels, so this only holds status/help text and the solve controls
    // (landmark status is shown once, at the top of alignmentControls).
    private var bottomDeck: some View {
        alignmentControls
            .frame(height: 300)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var landmarkPickerBar: some View {
        HStack {
            Picker("Landmark", selection: $selectedKind) {
                ForEach(FiducialKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button("Clear", systemImage: "xmark.circle") {
                targetEvidence[selectedKind] = nil
                sourceLandmarks[selectedKind] = nil
                invalidateSolve()
            }
            .help("Clear this landmark on both images and the model")
        }
    }

    private var frameNavBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Previous", systemImage: "chevron.left") {
                    observationIndex = max(0, observationIndex - 1)
                }
                .disabled(observationIndex == 0)
                Spacer()
                Text("Depth frame \(observationIndex + 1) of \(observations.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Next", systemImage: "chevron.right") {
                    observationIndex = min(observations.count - 1, observationIndex + 1)
                }
                .disabled(observationIndex >= observations.count - 1)
            }
            HStack(spacing: 8) {
                Text("1").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                if observations.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(observationIndex) },
                            set: { observationIndex = Int($0.rounded()) }),
                        in: 0...Double(observations.count - 1), step: 1)
                    .help("Scrub through depth frames")
                } else {
                    Capsule().fill(.quaternary).frame(height: 4)
                }
                Text("\(observations.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    private var alignmentControls: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if let placementError {
                    Label(placementError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                landmarkStatus

                if hasArchivedCaptureFiducials {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Use archived capture fiducials as image targets", isOn: $useArchivedFiducials)
                            .toggleStyle(.checkbox)
                            .onChange(of: useArchivedFiducials) { _, _ in invalidateSolve() }
                        Text(useArchivedFiducials
                             ? "Nasion/LPA/RPA use the device-recorded world fiducials from the original capture instead of fresh depth clicks. Useful if per-frame depth has a systematic bias - the archived points and the LiDAR mesh are independently consistent with each other. Cz still needs a fresh click."
                             : "Saved capture fiducials are reference data and are not counted as photo review. Place Nasion, LPA, and RPA in the RGB-D images for this alignment, or check the box above to use the archived points instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                GroupBox("Purpose of Align") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Align estimates one scale, rotation, and translation that places the photogrammetry model into the metric ARKit/LiDAR coordinate system.")
                        Text("It does not locate electrodes. It gives the later electrode solver a correctly positioned surface on which to place and validate electrode detections.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Picker("Algorithm", selection: $strategy) {
                    ForEach(WorldAlignmentStrategy.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .onChange(of: strategy) { _, value in
                    if value != .icp { seed = .landmarks }
                    invalidateSolve()
                }
                Text(strategy.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Repeated image clicks use their least-squares center when they agree; inconsistent sets fall back to the minimum-distance observed point. The three landmark centers are then fit to the 3D model by least squares.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if strategy == .icp {
                    Picker("ICP seed", selection: $seed) {
                        ForEach(AlignmentSeed.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .onChange(of: seed) { _, _ in invalidateSolve() }
                    Text(seed.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Accept on symmetric surface RMS", isOn: $useSymmetricAcceptance)
                        .toggleStyle(.checkbox)
                        .onChange(of: useSymmetricAcceptance) { _, _ in invalidateSolve() }
                    Text("Judges the fit by the worse of both cloud directions, so a scale-collapsed model can't pass on a deceptively low one-way residual. Recommended, and especially for a metric depth model.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if strategy != .icp {
                    Picker("Fit model", selection: $fitModel) {
                        ForEach(LandmarkFitModel.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .onChange(of: fitModel) { _, _ in invalidateSolve() }
                    Text(fitModel.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if fitModel == .affine {
                        Text("Affine can absorb a non-uniform depth distortion the similarity fit cannot, but with only 3-4 head landmarks it easily overfits noise. Prefer it only when the plausibility table shows a consistent non-uniform edge-ratio pattern, not scattered single-point errors.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                let availableModes = TargetResolutionMode.allCases.filter {
                    $0 != .snapToMesh || canSnapToMesh
                }
                Picker("Click resolution", selection: $targetMode) {
                    ForEach(availableModes) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: targetMode) { _, _ in invalidateSolve() }
                Text(targetMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if targetMode == .triangulate {
                    Text("Place the same landmark in 2+ photos from different angles, then solve. Cz especially benefits: depth at the grazing, cap-covered vertex is unreliable, but rays from several views cross cleanly. Re-place clicks after switching modes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Align Model and Preview", systemImage: "wand.and.sparkles") {
                        solve()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSolving || store.isApplyingAlignment || !canSolve)
                    .help(solveReadinessMessage)
                    if isSolving { ProgressView().controlSize(.small) }
                    Spacer()
                    if outcome != nil {
                        Button("Reset Preview") {
                            outcome = nil
                            allowPlausibilityOverride = false
                        }
                    }
                }

                Label(solveReadinessMessage, systemImage: canSolve
                      ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(canSolve ? Color.green : Color.secondary)

                if let solveError {
                    Label(solveError, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let debugLogURL {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Debug log: \(debugLogURL.path)")
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([debugLogURL])
                        }
                        .controlSize(.small)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let outcome { resultPanel(outcome) }
                if store.isApplyingAlignment {
                    ProgressView(store.alignmentStage)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var landmarkStatus: some View {
        // Compute plausibility once for the whole table; each leave-one-out fit is
        // cheap but there is no reason to redo it per row.
        let plausibility = landmarkPlausibility
        let plausibilityMeaningful = plausibility.count >= 4
        return VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Landmark").fontWeight(.semibold)
                    Text("Image → world").fontWeight(.semibold)
                    Text("3D model").fontWeight(.semibold)
                    Text("Geometry").fontWeight(.semibold)
                    Text(targetMode == .triangulate ? "Ray RMS" : "Snap Δ").fontWeight(.semibold)
                }
                ForEach(FiducialKind.allCases, id: \.rawValue) { kind in
                    landmarkStatusRow(
                        kind,
                        plausibility: plausibility[kind],
                        plausibilityMeaningful: plausibilityMeaningful)
                }
            }
            Text("Geometry = how far this landmark's distances to the others disagree with a single consistent scale (leave-one-out; needs Cz for a 4th point). ⚠ marks the geometric outlier. Last column: how far a click moved onto the LiDAR surface (snap), or the ray-agreement RMS and view count (triangulate).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func geometryCell(
        _ plausibility: LandmarkPlausibility?, meaningful: Bool
    ) -> some View {
        if let plausibility, meaningful {
            let mm = plausibility.geometryErrorMeters * 1_000
            let color: Color = plausibility.isLikelyOutlier || mm > 20
                ? .red : (mm > 10 ? .orange : .green)
            HStack(spacing: 3) {
                if plausibility.isLikelyOutlier {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                Text(mm.formatted(.number.precision(.fractionLength(1))) + " mm")
            }
            .foregroundStyle(color)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func snapCell(_ kind: FiducialKind) -> some View {
        if targetMode == .triangulate, let result = triangulation(for: kind) {
            let mm = result.rmsMeters * 1_000
            Text("\(mm.formatted(.number.precision(.fractionLength(1)))) mm · \(result.rayCount)v")
                .foregroundStyle(mm > 15 ? .orange : (mm > 8 ? .yellow : .green))
        } else if let delta = snapDistances[kind] {
            let mm = delta * 1_000
            Text(mm.formatted(.number.precision(.fractionLength(1))) + " mm")
                .foregroundStyle(mm > 20 ? .orange : .secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func landmarkStatusRow(
        _ kind: FiducialKind,
        plausibility: LandmarkPlausibility?,
        plausibilityMeaningful: Bool
    ) -> some View {
        let target = targetSummary(for: kind)
        let imageCount = targetEvidence[kind]?.count ?? 0
        let targetLabel: String
        if useArchivedFiducials, archivedFiducials[kind] != nil {
            targetLabel = "Archived (device)"
        } else if imageCount > 0, let target {
            let views = "\(imageCount) view\(imageCount == 1 ? "" : "s")"
            targetLabel = target.outlierCount > 0
                ? "\(views) · \(target.outlierCount) ignored"
                : "\(views) · center"
        } else {
            targetLabel = "Missing"
        }
        let optionalTag = kind.isCardinal ? "" : "  (optional, recommended)"
        let hasTarget = worldTarget(for: kind) != nil
        return GridRow {
            Text(kind.rawValue + optionalTag)
            Label(
                targetLabel,
                systemImage: hasTarget ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(hasTarget ? Color.green : Color.secondary)
            Label(
                sourceLandmarks[kind] == nil ? "Missing" : "Placed",
                systemImage: sourceLandmarks[kind] == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(sourceLandmarks[kind] == nil ? Color.secondary : Color.green)
            geometryCell(plausibility, meaningful: plausibilityMeaningful)
            snapCell(kind)
        }
    }

    @ViewBuilder
    private func resultPanel(_ value: ReceiverManualAlignmentOutcome) -> some View {
        let diagnostics = value.diagnostics
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            Label(
                diagnostics.accepted ? "Plausibility checks passed" : "Plausibility checks need attention",
                systemImage: diagnostics.accepted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostics.accepted ? .green : .orange)
            if let residual = diagnostics.landmarkRMSMeters {
                LabeledContent("Landmark RMS") {
                    rmsValue(
                        residual,
                        cautionThreshold: 0.015,
                        badThreshold: 0.025)
                }
            }
            if let residual = diagnostics.solverRMSMeters {
                let isSurfaceICP = diagnostics.strategy == WorldAlignmentStrategy.icp.rawValue
                LabeledContent("Solver RMS") {
                    rmsValue(
                        residual,
                        cautionThreshold: isSurfaceICP ? 0.040 : 0.015,
                        badThreshold: isSurfaceICP ? 0.060 : 0.025)
                }
            }
            if let symmetric = diagnostics.symmetricSurfaceRMSMeters {
                LabeledContent("Symmetric surface RMS") {
                    rmsValue(symmetric, cautionThreshold: 0.040, badThreshold: 0.060)
                }
            }
            LabeledContent("Fit model", value: diagnostics.fitModel)
            LabeledContent("Click resolution", value: diagnostics.targetResolution)
            if let spread = diagnostics.edgeRatioSpread {
                LabeledContent("Edge-ratio spread") {
                    Text(spread.formatted(.number.precision(.fractionLength(2))) + "×")
                        .foregroundStyle(spread > 1.2 ? .red : (spread > 1.1 ? .orange : .green))
                }
            }
            LabeledContent("Model scale", value: diagnostics.scale.formatted(.number.precision(.fractionLength(5))))
            LabeledContent("Iterations", value: "\(diagnostics.iterations)")
            ForEach(diagnostics.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !diagnostics.accepted {
                Toggle(
                    "Use this fit despite plausibility warnings",
                    isOn: $allowPlausibilityOverride)
                    .toggleStyle(.checkbox)
                Text("This records an explicit manual override in the derived bundle diagnostics; it does not remove or conceal the warnings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(
                ephemeralReconstruction != nil
                    ? "SAVE PREVIEW TO PROCESSED"
                    : diagnostics.accepted
                        ? "Save Alignment to PROCESSED"
                        : "Save Override to PROCESSED",
                systemImage: ephemeralReconstruction == nil
                    ? "checkmark.seal" : "bolt.fill"
            ) {
                var approved = value
                approved.diagnostics.userOverrideAccepted =
                    !diagnostics.accepted && allowPlausibilityOverride
                let preview = ephemeralReconstruction
                Task {
                    await store.applyManualAlignment(
                        approved, ephemeralReconstruction: preview)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(ephemeralReconstruction == nil ? nil : .orange)
            .disabled(
                (!diagnostics.accepted && !allowPlausibilityOverride)
                    || store.isApplyingAlignment)
            Text(ephemeralReconstruction == nil
                 ? "This updates only changed files in the PROCESSED package. RAW remains unchanged."
                 : "This adds the temporary model, camera poses, diagnostics, and alignment to PROCESSED. Future edits replace only changed files; RAW remains unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canSolve: Bool {
        if strategy == .icp, seed != .landmarks { return true }
        return FiducialKind.cardinal.allSatisfy {
            worldTarget(for: $0) != nil && sourceLandmarks[$0] != nil
        }
    }

    /// Whether Cz is placed on both the image and the model. When present it is
    /// fed to the solver as an off-plane 4th correspondence.
    private var hasVertexPair: Bool {
        worldTarget(for: .vertex) != nil && sourceLandmarks[.vertex] != nil
    }

    private var solveReadinessMessage: String {
        if strategy == .icp, seed != .landmarks {
            return "Ready for surface alignment without landmark correspondences."
        }
        let imageCount = FiducialKind.cardinal.filter {
            worldTarget(for: $0) != nil
        }.count
        let modelCount = FiducialKind.cardinal.filter {
            sourceLandmarks[$0] != nil
        }.count
        if imageCount == 3, modelCount == 3 {
            return hasVertexPair
                ? "Ready: 3 cardinal landmarks + Cz. The off-plane Cz stabilizes the fit."
                : "Ready: cardinal landmarks 3/3. Add Cz (below) to stabilize an otherwise coplanar, mirror-ambiguous fit."
        }
        if imageCount == 3, modelCount < 3 {
            return "Image landmarks 3/3 · model landmarks \(modelCount)/3. Select each landmark above, then click it on the 3D model."
        }
        return "Image landmarks \(imageCount)/3 · model landmarks \(modelCount)/3. Each landmark needs a click in an RGB-D image and on the 3D model."
    }

    private func placeTarget(at rawPoint: SIMD2<Float>) {
        guard let observation = currentObservation else { return }
        func store(_ hit: ReceiverImageFiducialHit) {
            var values = targetEvidence[selectedKind] ?? [:]
            values[observation.id] = hit
            targetEvidence[selectedKind] = values
            placementError = nil
            invalidateSolve()
        }
        // A depth resolve, if the frame supports it - reused for the record and as
        // the world point in depth mode / the snap-distance reference.
        let depthHit = try? ReceiverImageFiducialResolver.resolve(
            rawImagePoint: rawPoint, observation: observation,
            rootDirectory: bundle.rootDirectory)

        switch targetMode {
        case .triangulate:
            // Only the pixel matters; the 3D point is triangulated later from all
            // views. Store the click even when this frame has no usable depth.
            snapDistances[selectedKind] = nil
            store(depthHit ?? ReceiverImageFiducialHit(
                worldPoint: .zero, rawImagePoint: rawPoint,
                depthMeters: 0, confidence: 0, contributingDepthPixels: 0))

        case .snapToMesh:
            let snapped = ReceiverMeshSnap.snap(
                rawImagePoint: rawPoint, observation: observation,
                meshVertices: headMeshVertices, meshIndices: headMeshIndices)
            if let snapped {
                if let depthHit {
                    snapDistances[selectedKind] = simd_distance(depthHit.worldPoint, snapped)
                }
                store(ReceiverImageFiducialHit(
                    worldPoint: snapped, rawImagePoint: rawPoint,
                    depthMeters: depthHit?.depthMeters ?? 0,
                    confidence: depthHit?.confidence ?? 0, contributingDepthPixels: 0))
            } else if let depthHit {
                snapDistances[selectedKind] = nil
                store(depthHit)   // ray missed the mesh; fall back to depth
            } else {
                placementError = ReceiverFiducialPlacementError.noReliableDepth.localizedDescription
            }

        case .depth:
            snapDistances[selectedKind] = nil
            if let depthHit {
                store(depthHit)
            } else {
                // Re-run to surface the specific depth error.
                do {
                    _ = try ReceiverImageFiducialResolver.resolve(
                        rawImagePoint: rawPoint, observation: observation,
                        rootDirectory: bundle.rootDirectory)
                } catch {
                    placementError = error.localizedDescription
                }
            }
        }
    }

    private func solve() {
        var targets = [FiducialKind: SIMD3<Float>]()
        var counts = [FiducialKind: Int]()
        var usedCounts = [FiducialKind: Int]()
        var spreads = [FiducialKind: Float]()
        var rawSpreads = [FiducialKind: Float]()
        var centerMethods = [FiducialKind: String]()
        for kind in FiducialKind.allCases {
            if useArchivedFiducials, let archived = archivedFiducials[kind] {
                targets[kind] = archived
                counts[kind] = 1
                usedCounts[kind] = 1
                spreads[kind] = 0
                rawSpreads[kind] = 0
                centerMethods[kind] = "archived device fiducial"
                continue
            }
            if targetMode == .triangulate, let result = triangulation(for: kind) {
                targets[kind] = result.point
                counts[kind] = result.rayCount
                usedCounts[kind] = result.rayCount
                // Ray-agreement RMS stands in for placement spread here.
                spreads[kind] = result.rmsMeters
                rawSpreads[kind] = result.rmsMeters
                centerMethods[kind] = "multi-view triangulation (\(result.rayCount) views)"
                continue
            }
            guard let summary = targetSummary(for: kind) else { continue }
            targets[kind] = summary.center
            counts[kind] = summary.totalCount
            usedCounts[kind] = summary.inlierCount
            spreads[kind] = summary.maximumInlierDistance
            rawSpreads[kind] = summary.maximumRawDistance
            centerMethods[kind] = switch summary.method {
            case .singleObservation: "single image click"
            case .leastSquaresCentroid: "least-squares center"
            case .minimumDistanceObservation: "minimum-distance image click"
            }
        }
        let evidence = imageEvidenceRecords()
        var triangulationRMS = [FiducialKind: Float]()
        if targetMode == .triangulate {
            for kind in FiducialKind.allCases {
                if let result = triangulation(for: kind) { triangulationRMS[kind] = result.rmsMeters }
            }
        }
        let request = ReceiverManualAlignmentRequest(
            strategy: strategy,
            seed: seed,
            fitModel: fitModel,
            useSymmetricAcceptance: useSymmetricAcceptance,
            targetResolution: targetMode.rawValue,
            snapDistances: snapDistances,
            triangulationRMS: triangulationRMS,
            sourceLandmarks: sourceLandmarks,
            targetLandmarks: targets,
            targetEvidenceCounts: counts,
            targetUsedEvidenceCounts: usedCounts,
            targetMaximumSpreads: spreads,
            targetRawMaximumSpreads: rawSpreads,
            targetCenterMethods: centerMethods,
            imageEvidence: evidence)
        let sourceBundle = bundle
        isSolving = true
        solveError = nil
        allowPlausibilityOverride = false
        let modelURLForLog = ephemeralReconstruction?.modelURL
        Task {
            var solvedOutcome: ReceiverManualAlignmentOutcome?
            var failure: String?
            do {
                solvedOutcome = try await Task.detached(priority: .userInitiated) {
                    try ReceiverManualAlignmentWorkflow.solve(
                        bundle: sourceBundle,
                        request: request,
                        modelURLOverride: modelURLForLog)
                }.value
            } catch {
                failure = error.localizedDescription
            }
            outcome = solvedOutcome
            solveError = failure
            isSolving = false
            let logURL = ReceiverAlignmentDebugLog.record(
                packageRoot: sourceBundle.rootDirectory,
                request: request, outcome: solvedOutcome, errorMessage: failure)
            if let logURL { debugLogURL = logURL }
        }
    }

    private func targetSummary(
        for kind: FiducialKind
    ) -> RobustPointSetCenterResult? {
        guard let values = targetEvidence[kind]?.values, !values.isEmpty else { return nil }
        return RobustPointSetCenter.fit(values.map(\.worldPoint))
    }

    private func imageEvidenceRecords() -> [ReceiverManualImageEvidence] {
        var records = [ReceiverManualImageEvidence]()
        for kind in FiducialKind.allCases {
            for (observationID, hit) in targetEvidence[kind] ?? [:] {
                records.append(ReceiverManualImageEvidence(
                    kind: kind.rawValue,
                    observationID: observationID,
                    rawImagePoint: [Double(hit.rawImagePoint.x), Double(hit.rawImagePoint.y)],
                    worldPoint: [
                        Double(hit.worldPoint.x), Double(hit.worldPoint.y),
                        Double(hit.worldPoint.z)
                    ],
                    depthMeters: Double(hit.depthMeters),
                    confidence: hit.confidence,
                    contributingDepthPixels: hit.contributingDepthPixels))
            }
        }
        return records.sorted {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.observationID.uuidString < $1.observationID.uuidString
        }
    }

    private func loadCurrentImage() {
        guard let observation = currentObservation,
              let path = imagePath(for: observation) else {
            orientedImage = nil
            return
        }
        orientedImage = ReceiverOrientedFrameImage.load(
            from: bundle.rootDirectory.appendingPathComponent(path),
            orientation: ReceiverStoredImageOrientation(observation.imageOrientation))
    }

    private func imagePath(for observation: MANTACaptureObservation) -> String? {
        observation.losslessImagePath ?? observation.imagePath ?? observation.compressedImagePath
    }

    private var modelURL: URL? {
        if let ephemeralReconstruction { return ephemeralReconstruction.modelURL }
        guard let path = bundle.capture.reconstruction?.objectCaptureModelPath else { return nil }
        let url = bundle.rootDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func invalidateSolve() {
        outcome = nil
        solveError = nil
        allowPlausibilityOverride = false
    }

    /// Loads the head-cropped LiDAR mesh (falling back to the full LiDAR mesh)
    /// once, for snap-to-surface raycasting. Runs off the main actor since PLY
    /// parsing is pure bytes.
    private func loadHeadMesh() {
        guard headMeshVertices.isEmpty,
              let reconstruction = bundle.capture.reconstruction,
              let path = reconstruction.headCroppedLidarMeshPath ?? reconstruction.lidarMeshPath
        else { return }
        let url = bundle.rootDirectory.appendingPathComponent(path)
        Task.detached(priority: .userInitiated) {
            guard let mesh = try? ReceiverPLYMesh(contentsOf: url) else { return }
            await MainActor.run {
                headMeshVertices = mesh.points
                headMeshIndices = mesh.indices
            }
        }
    }

    private var canSnapToMesh: Bool { !headMeshVertices.isEmpty }

    /// Live per-landmark plausibility from the currently placed model + world
    /// points, computed without solving so a bad click shows up immediately.
    private var landmarkPlausibility: [FiducialKind: LandmarkPlausibility] {
        let kinds = FiducialKind.allCases.filter {
            sourceLandmarks[$0] != nil && worldTarget(for: $0) != nil
        }
        guard kinds.count >= 3 else { return [:] }
        let source = kinds.map { sourceLandmarks[$0]! }
        let target = kinds.map { worldTarget(for: $0)! }
        let scores = LandmarkPlausibilityAnalyzer.evaluate(source: source, target: target)
        return Dictionary(uniqueKeysWithValues: zip(kinds, scores).compactMap { kind, score in
            score.map { (kind, $0) }
        })
    }

    private func millimeters(_ meters: Double) -> String {
        (meters * 1_000).formatted(.number.precision(.fractionLength(1))) + " mm"
    }

    private func rmsValue(
        _ meters: Double,
        cautionThreshold: Double,
        badThreshold: Double
    ) -> some View {
        let rating: (name: String, color: Color)
        if meters <= cautionThreshold {
            rating = ("Good", .green)
        } else if meters <= badThreshold {
            rating = ("Okay — caution", .yellow)
        } else {
            rating = ("Bad", .red)
        }
        return HStack(spacing: 7) {
            Text(millimeters(meters))
                .monospacedDigit()
            Circle()
                .fill(rating.color)
                .overlay(Circle().stroke(.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 11, height: 11)
                .accessibilityLabel(rating.name)
        }
        .help(
            "\(rating.name). Green ≤ \(millimeters(cautionThreshold)); "
                + "yellow ≤ \(millimeters(badThreshold)); red above that.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(millimeters(meters)), \(rating.name)")
    }
}

private struct ReceiverFiducialImageCanvas: View {
    let image: ReceiverOrientedFrameImage?
    let observation: MANTACaptureObservation?
    let hits: [ReceiverImageFiducialHit]
    let onPlace: (SIMD2<Float>) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.92)
                if let image, let observation {
                    let displaySize = image.orientation.displaySize(for: rawSize(observation))
                    let rect = aspectFit(displaySize, in: geometry.size)
                    Image(nsImage: image.image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                        let point = markerPoint(hit, observation: observation, orientation: image.orientation, rect: rect)
                        Circle()
                            .fill(.pink)
                            .stroke(.white, lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                            .position(point)
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            guard rect.contains(value.location) else { return }
                            let display = CGPoint(
                                x: (value.location.x - rect.minX) / rect.width * displaySize.width,
                                y: (value.location.y - rect.minY) / rect.height * displaySize.height)
                            let raw = image.orientation.rawPoint(display, rawSize: rawSize(observation))
                            guard raw.x >= 0, raw.y >= 0,
                                  raw.x < CGFloat(observation.imageDimensions.width),
                                  raw.y < CGFloat(observation.imageDimensions.height) else { return }
                            onPlace(SIMD2(Float(raw.x), Float(raw.y)))
                        })
                } else {
                    ProgressView("Loading image…")
                        .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func markerPoint(
        _ hit: ReceiverImageFiducialHit,
        observation: MANTACaptureObservation,
        orientation: ReceiverStoredImageOrientation,
        rect: CGRect
    ) -> CGPoint {
        let rawSize = rawSize(observation)
        let displaySize = orientation.displaySize(for: rawSize)
        let display = orientation.displayPoint(
            CGPoint(x: CGFloat(hit.rawImagePoint.x), y: CGFloat(hit.rawImagePoint.y)),
            rawSize: rawSize)
        return CGPoint(
            x: rect.minX + display.x / displaySize.width * rect.width,
            y: rect.minY + display.y / displaySize.height * rect.height)
    }

    private func rawSize(_ observation: MANTACaptureObservation) -> CGSize {
        CGSize(width: observation.imageDimensions.width, height: observation.imageDimensions.height)
    }

    private func aspectFit(_ content: CGSize, in available: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(available.width / content.width, available.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }
}
