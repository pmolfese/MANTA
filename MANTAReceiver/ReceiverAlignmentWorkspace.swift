import AppKit
import MANTACore
import SwiftUI
import simd

struct ReceiverAlignmentWorkspace: View {
    @ObservedObject var store: ReceiverStore
    let bundle: MANTAValidatedBundle
    let ephemeralReconstruction: ReceiverEphemeralReconstruction?

    @State private var selectedKind = FiducialKind.nasion
    @State private var observationIndex = 0
    @State private var orientedImage: ReceiverOrientedFrameImage?
    @State private var targetEvidence = [FiducialKind: [UUID: ReceiverImageFiducialHit]]()
    @State private var sourceLandmarks = [FiducialKind: SIMD3<Float>]()
    @State private var strategy = WorldAlignmentStrategy.fiducial
    @State private var seed = AlignmentSeed.landmarks
    @State private var outcome: ReceiverManualAlignmentOutcome?
    @State private var isSolving = false
    @State private var placementError: String?
    @State private var solveError: String?
    @State private var allowPlausibilityOverride = false
    @State private var isViewerExpanded = false
    @State private var imagePanelFraction: CGFloat = 0.58
    @State private var imageResizeStartFraction: CGFloat?

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

    private var hasArchivedCaptureFiducials: Bool {
        (bundle.capture.fiducials ?? []).contains {
            $0.coordinateSystem == "arkit-world" && $0.coordinate?.count == 3
        }
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
                HSplitView {
                    if !isViewerExpanded {
                        alignmentSidebar
                            .frame(minWidth: 420, idealWidth: 680, maxWidth: 1_200)
                    }

                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("3D photogrammetry placement · \(selectedKind.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !isViewerExpanded {
                                Text("Drag the divider to resize")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Button(
                                isViewerExpanded ? "Show Controls" : "Expand 3D",
                                systemImage: isViewerExpanded
                                    ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right"
                            ) {
                                isViewerExpanded.toggle()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(isViewerExpanded
                                  ? "Restore the image-placement and solver panels"
                                  : "Give the 3D model the full alignment workspace")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.bar)

                        CombinedModelViewer(
                            bundle: bundle,
                            modelToWorldOverride: outcome?.result.transform
                                ?? ephemeralReconstruction?.modelToWorld,
                            photogrammetryURLOverride: ephemeralReconstruction?.modelURL,
                            photogrammetryPlacementLabel: selectedKind.rawValue,
                            modelLandmarks: modelLandmarks,
                            onPhotogrammetryPointPicked: { point in
                            sourceLandmarks[selectedKind] = point
                            invalidateSolve()
                        })
                    }
                    .frame(minWidth: 360)
                    .layoutPriority(1)
                }
            }
        }
        .task(id: currentObservation?.id) { loadCurrentImage() }
    }

    /// A bounded sidebar avoids the oversized intrinsic width that VSplitView
    /// can assign to text-heavy children. The explicit divider also makes image
    /// resizing discoverable and leaves every control reachable by scrolling.
    private var alignmentSidebar: some View {
        GeometryReader { geometry in
            let minimumImageHeight: CGFloat = 300
            let minimumControlsHeight: CGFloat = 220
            let dividerHeight: CGFloat = 10
            let usableHeight = max(1, geometry.size.height - dividerHeight)
            let maximumImageHeight = max(
                minimumImageHeight,
                usableHeight - minimumControlsHeight)
            let imageHeight = min(
                maximumImageHeight,
                max(minimumImageHeight, usableHeight * imagePanelFraction))

            VStack(spacing: 0) {
                imagePlacementPanel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: imageHeight)

                imageResizeDivider(availableHeight: usableHeight)
                    .frame(height: dividerHeight)

                alignmentControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func imageResizeDivider(availableHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
            Capsule()
                .fill(.secondary.opacity(0.65))
                .frame(width: 38, height: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if imageResizeStartFraction == nil {
                        imageResizeStartFraction = imagePanelFraction
                    }
                    let initial = imageResizeStartFraction ?? imagePanelFraction
                    imagePanelFraction = min(
                        0.82,
                        max(0.32, initial + value.translation.height / availableHeight))
                }
                .onEnded { _ in imageResizeStartFraction = nil }
        )
        .help("Drag to resize the landmark image")
        .accessibilityLabel("Resize landmark image")
    }

    private var imagePlacementPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Landmark", selection: $selectedKind) {
                    ForEach(FiducialKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Button("Clear", systemImage: "xmark.circle") {
                    targetEvidence[selectedKind] = nil
                    sourceLandmarks[selectedKind] = nil
                    invalidateSolve()
                }
                .help("Clear this landmark on both images and the model")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ReceiverFiducialImageCanvas(
                image: orientedImage,
                observation: currentObservation,
                hits: currentObservation.flatMap { targetEvidence[selectedKind]?[$0.id] }.map { [$0] } ?? []
            ) { rawPoint in
                placeTarget(at: rawPoint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 170)

            HStack {
                Button("Previous", systemImage: "chevron.left") {
                    observationIndex = max(0, observationIndex - 1)
                }
                .disabled(observationIndex == 0)
                Spacer()
                Text("Depth frame \(observationIndex + 1) of \(observations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Next", systemImage: "chevron.right") {
                    observationIndex = min(observations.count - 1, observationIndex + 1)
                }
                .disabled(observationIndex >= observations.count - 1)
            }

            HStack(spacing: 8) {
                Text("1")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, alignment: .leading)
                if observations.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(observationIndex) },
                            set: { observationIndex = Int($0.rounded()) }),
                        in: 0...Double(observations.count - 1),
                        step: 1)
                    .help("Scrub through depth frames")
                } else {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)
                        .accessibilityHidden(true)
                }
                Text("\(observations.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
            .accessibilityLabel("Depth frame scrubber")

            Text("Click \(selectedKind.rawValue) in the image, then click the same landmark on the 3D photogrammetry model. Repeat the image click in another view to check depth consistency.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let placementError {
                Label(placementError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var alignmentControls: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                landmarkStatus

                if hasArchivedCaptureFiducials {
                    Label(
                        "Saved capture fiducials are reference data and are not counted as photo review. Place Nasion, LPA, and RPA in the RGB-D images for this alignment.",
                        systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Landmark").fontWeight(.semibold)
                Text("Image → world").fontWeight(.semibold)
                Text("3D model").fontWeight(.semibold)
            }
            ForEach(FiducialKind.allCases, id: \.rawValue) { kind in
                landmarkStatusRow(kind)
            }
        }
        .font(.caption)
    }

    private func landmarkStatusRow(_ kind: FiducialKind) -> some View {
        let target = targetSummary(for: kind)
        let imageCount = targetEvidence[kind]?.count ?? 0
        let targetLabel: String
        if imageCount > 0, let target {
            let views = "\(imageCount) view\(imageCount == 1 ? "" : "s")"
            targetLabel = target.outlierCount > 0
                ? "\(views) · \(target.outlierCount) ignored"
                : "\(views) · center"
        } else {
            targetLabel = "Missing"
        }
        let optionalTag = kind.isCardinal ? "" : "  (optional, recommended)"
        return GridRow {
            Text(kind.rawValue + optionalTag)
            Label(
                targetLabel,
                systemImage: target == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(target == nil ? Color.secondary : Color.green)
            Label(
                sourceLandmarks[kind] == nil ? "Missing" : "Placed",
                systemImage: sourceLandmarks[kind] == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(sourceLandmarks[kind] == nil ? Color.secondary : Color.green)
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
            targetSummary(for: $0) != nil && sourceLandmarks[$0] != nil
        }
    }

    /// Whether Cz is placed on both the image and the model. When present it is
    /// fed to the solver as an off-plane 4th correspondence.
    private var hasVertexPair: Bool {
        targetSummary(for: .vertex) != nil && sourceLandmarks[.vertex] != nil
    }

    private var solveReadinessMessage: String {
        if strategy == .icp, seed != .landmarks {
            return "Ready for surface alignment without landmark correspondences."
        }
        let imageCount = FiducialKind.cardinal.filter {
            targetSummary(for: $0) != nil
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
        do {
            let hit = try ReceiverImageFiducialResolver.resolve(
                rawImagePoint: rawPoint,
                observation: observation,
                rootDirectory: bundle.rootDirectory)
            var values = targetEvidence[selectedKind] ?? [:]
            values[observation.id] = hit
            targetEvidence[selectedKind] = values
            placementError = nil
            invalidateSolve()
        } catch {
            placementError = error.localizedDescription
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
        let request = ReceiverManualAlignmentRequest(
            strategy: strategy,
            seed: seed,
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
        Task {
            do {
                outcome = try await Task.detached(priority: .userInitiated) {
                    try ReceiverManualAlignmentWorkflow.solve(
                        bundle: sourceBundle,
                        request: request,
                        modelURLOverride: ephemeralReconstruction?.modelURL)
                }.value
            } catch {
                solveError = error.localizedDescription
                outcome = nil
            }
            isSolving = false
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
