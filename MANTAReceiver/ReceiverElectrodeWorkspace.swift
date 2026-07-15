import AppKit
import MANTACore
import SwiftUI
import simd

struct ReceiverElectrodeWorkspace: View {
    @ObservedObject var store: ReceiverStore
    @ObservedObject var display: ReceiverDisplaySettings
    let bundle: MANTAValidatedBundle

    @State private var selectedLabel: String? = "E1"
    @State private var filter = ReceiverElectrodeFilter.all
    @State private var workingElectrodes = [MANTAElectrodeSolution]()
    @State private var evidence: ReceiverElectrodeEvidenceDocument?
    @State private var frameIndex = 0
    @State private var imageZoom: CGFloat = 1
    @State private var showsAllFrames = false
    @State private var orientedImage: ReceiverOrientedFrameImage?
    @State private var isMovingIn3D = false
    @State private var placementError: String?
    @State private var relabelSource: String?
    @State private var replacementLabel = ""
    @State private var showsRelabelAlert = false
    @State private var guessThreshold = 0.60

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                sensorList
                    .frame(minWidth: 235, idealWidth: 275, maxWidth: 360)
                imageReview
                    .frame(minWidth: 390, idealWidth: 520)
                CombinedModelViewer(
                    bundle: bundle,
                    display: display,
                    electrodesOverride: displayedElectrodes,
                    electrodePlacementLabel: isMovingIn3D ? selectedLabel : nil,
                    onWorldElectrodePointPicked: placeFromModel,
                    annotationOnlyDefault: true,
                    includesFiducialAnnotations: false)
                    .frame(minWidth: 440)
            }
        }
        .task(id: bundle.manifest.bundleID) { loadSavedState() }
        .onChange(of: store.electrodeDraft?.evidence.generatedAt) { _, _ in
            guard let draft = store.electrodeDraft else { return }
            let previousSelection = selectedLabel
            workingElectrodes = draft.electrodes
            evidence = draft.evidence
            if let previousSelection, labels.contains(previousSelection) {
                selectedLabel = previousSelection
                frameIndex = min(frameIndex, max(0, frameObservations.count - 1))
                loadCurrentImage()
            } else {
                selectFirstUsefulSensor()
                resetFrameSelection()
            }
        }
        .onChange(of: selectedLabel) { _, _ in
            isMovingIn3D = false
            placementError = nil
            resetFrameSelection()
        }
        .onChange(of: alignmentSignature) { _, _ in loadSavedState() }
        .onChange(of: showsAllFrames) { _, _ in resetFrameSelection() }
        .task(id: currentObservation?.id) { loadCurrentImage() }
        .alert("Correct Sensor Label", isPresented: $showsRelabelAlert) {
            TextField("Sensor number", text: $replacementLabel)
            Button("Cancel", role: .cancel) {}
            Button("Apply") { applyRelabel() }
        } message: {
            Text("Enter a number from this net, such as 128 or E128.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Detect Sensors", systemImage: "viewfinder.circle") {
                store.detectElectrodes()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !hasAlignedModel || store.isDetectingElectrodes || store.isSavingElectrodes)

            if !hasAlignedModel {
                Label("Save an alignment first", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if store.isDetectingElectrodes {
                ProgressView(value: store.electrodeDetectionProgress)
                    .frame(width: 150)
                Text(store.electrodeDetectionStage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Cancel", systemImage: "xmark.circle", role: .cancel) {
                    store.cancelElectrodeDetection()
                }
            } else {
                Label("\(observedCount) observed", systemImage: "text.viewfinder")
                    .foregroundStyle(.secondary)
                if unlabeledCandidateCount > 0 {
                    Label("\(unlabeledCandidateCount) CV proposals", systemImage: "circle.dotted")
                        .foregroundStyle(.mint)
                }
                if guessedCount > 0 {
                    Label("\(visibleGuessCount)/\(guessedCount) guesses", systemImage: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.orange)
                }
                Label("\(reviewedCount) reviewed", systemImage: "checkmark.circle")
                    .foregroundStyle(reviewedCount > 0 ? .green : .secondary)
            }

            Divider().frame(height: 18)
            Text("Guesses ≥ \(guessThreshold.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: $guessThreshold, in: 0.10...0.95, step: 0.05)
                .frame(width: 120)

            if store.isUpdatingElectrodeGuesses {
                ProgressView().controlSize(.small)
                Text("Updating guesses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Save Sensors", systemImage: "checkmark.seal") {
                guard var evidence else { return }
                evidence.summaries = summaries(for: workingElectrodes, existing: evidence.summaries)
                Task { await store.saveElectrodes(workingElectrodes, evidence: evidence) }
            }
            .disabled(
                workingElectrodes.isEmpty || evidence == nil
                    || store.isDetectingElectrodes || store.isUpdatingElectrodeGuesses
                    || store.isSavingElectrodes)
            if store.isSavingElectrodes { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var sensorList: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(ReceiverElectrodeFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            List(filteredLabels, id: \.self, selection: $selectedLabel) { label in
                let solution = solution(for: label)
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(solution?.state))
                        .frame(width: 9, height: 9)
                    Text(label)
                        .font(.body.monospacedDigit())
                    Spacer()
                    if let solution {
                        Text(rowStatus(solution))
                            .font(.caption)
                            .foregroundStyle(solution.state == "Guessed" ? .orange : .secondary)
                    } else {
                        Text("Missing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(label)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if solution != nil { beginRelabel(label) }
                })
            }
            .listStyle(.sidebar)
        }
    }

    private var imageReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedLabel ?? "EEG Sensor")
                        .font(.headline)
                    if let summary = selectedSummary {
                        Text(summaryLine(summary))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No automatic candidate")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let diagnostic = selectedReprojectionDiagnostic {
                        Text(diagnostic.description)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(diagnostic.isLargeError ? .orange : .cyan)
                    }
                }
                Spacer()
                Toggle("All frames", isOn: $showsAllFrames)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button(
                    isMovingIn3D ? "Cancel Move" : "Move on 3D",
                    systemImage: isMovingIn3D ? "xmark" : "mappin.and.ellipse"
                ) {
                    isMovingIn3D.toggle()
                }
                .disabled(selectedLabel == nil || !hasAlignedModel)
                Button("Reviewed", systemImage: "checkmark.circle") {
                    markSelectedReviewed()
                }
                .disabled(solution(for: selectedLabel) == nil)
            }
            .controlSize(.small)

            ReceiverZoomableImageArea(zoom: $imageZoom) {
                ReceiverElectrodeImageCanvas(
                    image: orientedImage,
                    observation: currentObservation,
                    evidence: currentFrameEvidence,
                    cupCandidates: currentFrameCupEvidence,
                    selectedLabel: selectedLabel,
                    projectedRawImagePoint: selectedReprojectionDiagnostic?.rawPoint,
                    onPlace: placeFromImage,
                    onRelabel: beginRelabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 280)

            if !currentFrameCupEvidence.isEmpty {
                Label(
                    "Mint rings are unlabeled visual cup proposals; labels are assigned only after multi-view 3D fusion.",
                    systemImage: "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.mint)
            }

            if !frameObservations.isEmpty {
                HStack(spacing: 8) {
                    Button("Previous", systemImage: "chevron.left") {
                        frameIndex = max(0, frameIndex - 1)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(frameIndex == 0)
                    if frameObservations.count > 1 {
                        Slider(
                            value: Binding(
                                get: { Double(frameIndex) },
                                set: { frameIndex = Int($0.rounded()) }),
                            in: 0...Double(frameObservations.count - 1), step: 1)
                    } else {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 4)
                            .accessibilityHidden(true)
                    }
                    Text("\(frameIndex + 1) / \(frameObservations.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    Button("Next", systemImage: "chevron.right") {
                        frameIndex = min(frameObservations.count - 1, frameIndex + 1)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(frameIndex >= frameObservations.count - 1)
                }
                .controlSize(.small)
            }

            if let placementError {
                Label(placementError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    private var electrodeChannelCount: Int {
        bundle.capture.layoutID.localizedCaseInsensitiveContains("256") ? 256 : 128
    }

    private var labels: [String] {
        (1...electrodeChannelCount).map { "E\($0)" } + ["Cz"]
    }

    private var hasAlignedModel: Bool {
        guard let reconstruction = bundle.capture.reconstruction,
              reconstruction.modelToWorld?.count == 16,
              let path = reconstruction.objectCaptureModelPath else { return false }
        return FileManager.default.fileExists(
            atPath: bundle.rootDirectory.appendingPathComponent(path).path)
    }

    private var filteredLabels: [String] {
        labels.filter { label in
            let solution = solution(for: label)
            return switch filter {
            case .all: true
            case .review: solution?.state == "Needs Review" || solution?.state == "Detected"
            case .reviewed: solution?.state == "Reviewed"
            case .guesses: solution?.state == "Guessed"
            case .missing: solution == nil
            }
        }
    }

    private var reviewedCount: Int {
        workingElectrodes.filter { $0.state == "Reviewed" }.count
    }

    private var guessedCount: Int {
        workingElectrodes.filter { $0.state == "Guessed" }.count
    }

    private var visibleGuessCount: Int {
        workingElectrodes.filter {
            $0.state == "Guessed" && $0.confidence >= guessThreshold
        }.count
    }

    private var observedCount: Int {
        workingElectrodes.count - guessedCount
    }

    private var unlabeledCandidateCount: Int {
        evidence?.unlabeledCandidates?.count ?? 0
    }

    private var displayedElectrodes: [MANTAElectrodeSolution] {
        workingElectrodes.filter {
            $0.state != "Guessed" || $0.confidence >= guessThreshold
                || $0.label == selectedLabel
        }
    }

    private var selectedSummary: ReceiverElectrodeSummary? {
        guard let selectedLabel else { return nil }
        return evidence?.summaries.first { $0.label == selectedLabel }
    }

    private var frameObservations: [MANTACaptureObservation] {
        let all = bundle.capture.observations.filter {
            $0.depth != nil && imagePath(for: $0) != nil
        }
        guard !showsAllFrames, let selectedLabel else { return all }
        let ids = Set((evidence?.observations ?? []).filter {
            $0.label == selectedLabel
        }.map(\.observationID))
        let supporting = all.filter { ids.contains($0.id) }
        return supporting.isEmpty ? all : supporting
    }

    private var currentObservation: MANTACaptureObservation? {
        frameObservations.indices.contains(frameIndex) ? frameObservations[frameIndex] : nil
    }

    private var currentFrameEvidence: [ReceiverElectrodeObservationEvidence] {
        guard let id = currentObservation?.id else { return [] }
        return (evidence?.observations ?? []).filter { $0.observationID == id }
    }

    private var currentFrameCupEvidence: [ReceiverUnlabeledCupEvidence] {
        guard let id = currentObservation?.id else { return [] }
        return (evidence?.unlabeledCandidates ?? []).filter { $0.observationID == id }
    }

    private var selectedReprojectionDiagnostic: ReceiverReprojectionDiagnostic? {
        guard let observation = currentObservation,
              let solution = solution(for: selectedLabel),
              solution.coordinate.count == 3,
              let camera = PinholeCamera(
                intrinsics: observation.intrinsics.map(Float.init),
                transform: observation.cameraToWorld.map(Float.init)),
              let projected = camera.project(SIMD3(
                Float(solution.coordinate[0]), Float(solution.coordinate[1]),
                Float(solution.coordinate[2]))) else { return nil }
        let rawPoint = [Double(projected.pixel.x), Double(projected.pixel.y)]
        let candidates = currentFrameEvidence.filter { $0.label == solution.label }
        let error = candidates.compactMap { item -> Double? in
            guard item.rawImagePoint.count == 2 else { return nil }
            return hypot(
                item.rawImagePoint[0] - rawPoint[0],
                item.rawImagePoint[1] - rawPoint[1])
        }.min()
        let depthDelta = candidates.compactMap { item -> Double? in
            abs(item.depthMeters - Double(projected.depth))
        }.min()
        return ReceiverReprojectionDiagnostic(
            rawPoint: rawPoint, pixelError: error, depthDeltaMeters: depthDelta)
    }

    private func solution(for label: String?) -> MANTAElectrodeSolution? {
        guard let label else { return nil }
        return workingElectrodes.first { $0.label == label }
    }

    private func loadSavedState() {
        if let draft = store.electrodeDraft,
           draft.evidence.modelPath == bundle.capture.reconstruction?.objectCaptureModelPath,
           draft.evidence.modelToWorld == bundle.capture.reconstruction?.modelToWorld {
            workingElectrodes = draft.electrodes
            evidence = draft.evidence
        } else {
            workingElectrodes = bundle.capture.electrodes ?? []
            let loaded = ReceiverProcessedPackage.loadElectrodeEvidence(from: bundle)
            evidence = loaded?.modelPath == bundle.capture.reconstruction?.objectCaptureModelPath
                    && loaded?.modelToWorld == bundle.capture.reconstruction?.modelToWorld
                ? loaded : nil
        }
        selectFirstUsefulSensor()
        resetFrameSelection()
    }

    private func selectFirstUsefulSensor() {
        if let first = workingElectrodes.first(where: { $0.state == "Needs Review" }) {
            selectedLabel = first.label
        } else if let first = workingElectrodes.first {
            selectedLabel = first.label
        }
    }

    private func resetFrameSelection() {
        frameIndex = 0
        loadCurrentImage()
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

    private func placeFromImage(_ point: SIMD2<Float>) {
        guard let observation = currentObservation, let label = selectedLabel else { return }
        do {
            let hit = try ReceiverImageFiducialResolver.resolve(
                rawImagePoint: point, observation: observation,
                rootDirectory: bundle.rootDirectory)
            applyManualCoordinate(
                hit.worldPoint.doubles, label: label, source: "image-depth",
                observationID: observation.id, rawImagePoint: point.doubles)
            placementError = nil
        } catch {
            placementError = error.localizedDescription
        }
    }

    private func placeFromModel(_ point: SIMD3<Double>) {
        guard let label = selectedLabel else { return }
        applyManualCoordinate(
            [point.x, point.y, point.z], label: label, source: "3d-surface",
            observationID: nil, rawImagePoint: nil)
        isMovingIn3D = false
        placementError = nil
    }

    private func beginRelabel(_ label: String) {
        guard solution(for: label) != nil else { return }
        relabelSource = label
        replacementLabel = label
        showsRelabelAlert = true
    }

    private func applyRelabel() {
        guard let oldLabel = relabelSource,
              let newLabel = normalizedLabel(replacementLabel),
              labels.contains(newLabel) else {
            placementError = "Use a sensor number between 1 and \(electrodeChannelCount)."
            return
        }
        guard newLabel != oldLabel else { return }

        let sourceWasGuess = workingElectrodes.first(where: { $0.label == oldLabel })?.state
            == "Guessed"
        let destinationIsGuess = workingElectrodes.first(where: { $0.label == newLabel })?.state
            == "Guessed"
        if destinationIsGuess {
            workingElectrodes.removeAll { $0.label == newLabel }
            evidence?.summaries.removeAll { $0.label == newLabel }
        }
        let swapsObservedDestination = !destinationIsGuess
            && workingElectrodes.contains { $0.label == newLabel }

        func corrected(_ label: String) -> String {
            if label == oldLabel { return newLabel }
            if swapsObservedDestination && label == newLabel { return oldLabel }
            return label
        }
        for index in workingElectrodes.indices {
            workingElectrodes[index].label = corrected(workingElectrodes[index].label)
            workingElectrodes[index].role = cardinalLabels.contains(workingElectrodes[index].label)
                ? "Cardinal" : "Regular"
            if workingElectrodes[index].label == newLabel
                || (swapsObservedDestination && workingElectrodes[index].label == oldLabel) {
                workingElectrodes[index].state = sourceWasGuess
                    && workingElectrodes[index].label == newLabel ? "Reviewed" : "Needs Review"
                if workingElectrodes[index].state == "Reviewed" {
                    workingElectrodes[index].confidence = 1
                }
            }
        }
        if var document = evidence {
            for index in document.observations.indices {
                document.observations[index].label = corrected(document.observations[index].label)
            }
            for index in document.summaries.indices {
                document.summaries[index].label = corrected(document.summaries[index].label)
                if document.summaries[index].label == newLabel
                    || (swapsObservedDestination && document.summaries[index].label == oldLabel) {
                    document.summaries[index].state = sourceWasGuess
                        && document.summaries[index].label == newLabel
                        ? "Reviewed" : "Needs Review"
                    if document.summaries[index].state == "Reviewed" {
                        document.summaries[index].confidence = 1
                    }
                    document.summaries[index].geometryWarning = document.summaries[index].label == newLabel
                        ? "Label manually corrected from \(oldLabel)"
                        : "Label swapped with \(newLabel); verify position"
                }
            }
            if document.manualEdits != nil {
                for index in document.manualEdits!.indices {
                    document.manualEdits![index].label = corrected(document.manualEdits![index].label)
                }
            }
            if let coordinate = workingElectrodes.first(where: { $0.label == newLabel })?.coordinate {
                document.manualEdits = (document.manualEdits ?? []) + [
                    ReceiverElectrodeManualEdit(
                        id: UUID(), editedAt: Date(), label: newLabel,
                        source: "label-correction-from-\(oldLabel)", coordinate: coordinate,
                        observationID: nil, rawImagePoint: nil)
                ]
            }
            evidence = document
        }
        workingElectrodes.sort { electrodeNumber($0.label) < electrodeNumber($1.label) }
        selectedLabel = newLabel
        placementError = swapsObservedDestination
            ? "Swapped \(oldLabel) and \(newLabel); verify both sensor positions."
            : nil
        refreshGuesses()
    }

    private func normalizedLabel(_ value: String) -> String? {
        let compact = value.uppercased().filter(\.isNumber)
        guard let number = Int(compact), (1...electrodeChannelCount).contains(number) else { return nil }
        return "E\(number)"
    }

    private func applyManualCoordinate(
        _ coordinate: [Double], label: String, source: String,
        observationID: UUID?, rawImagePoint: [Double]?
    ) {
        if let index = workingElectrodes.firstIndex(where: { $0.label == label }) {
            workingElectrodes[index].coordinate = coordinate
            workingElectrodes[index].confidence = 1
            workingElectrodes[index].state = "Reviewed"
        } else {
            workingElectrodes.append(MANTAElectrodeSolution(
                label: label, role: cardinalLabels.contains(label) ? "Cardinal" : "Regular",
                coordinateSystem: "arkit-world", coordinate: coordinate,
                confidence: 1, state: "Reviewed"))
            workingElectrodes.sort { electrodeNumber($0.label) < electrodeNumber($1.label) }
        }
        guard evidence != nil else {
            evidence = ReceiverElectrodeEvidenceDocument(
                sessionID: bundle.manifest.sessionID,
                sourceBundleID: bundle.manifest.bundleID,
                generatedAt: Date(),
                modelPath: bundle.capture.reconstruction?.objectCaptureModelPath,
                modelToWorld: bundle.capture.reconstruction?.modelToWorld,
                observations: [], summaries: [], manualEdits: nil)
            return applyManualCoordinate(
                coordinate, label: label, source: source,
                observationID: observationID, rawImagePoint: rawImagePoint)
        }
        evidence?.manualEdits = (evidence?.manualEdits ?? []) + [
            ReceiverElectrodeManualEdit(
                id: UUID(), editedAt: Date(), label: label, source: source,
                coordinate: coordinate, observationID: observationID,
                rawImagePoint: rawImagePoint)
        ]
        updateSummary(label: label, coordinate: coordinate, state: "Reviewed", confidence: 1)
        refreshGuesses()
    }

    private func markSelectedReviewed() {
        guard let label = selectedLabel,
              let index = workingElectrodes.firstIndex(where: { $0.label == label }) else { return }
        workingElectrodes[index].state = "Reviewed"
        workingElectrodes[index].confidence = 1
        let coordinate = workingElectrodes[index].coordinate
        evidence?.manualEdits = (evidence?.manualEdits ?? []) + [
            ReceiverElectrodeManualEdit(
                id: UUID(), editedAt: Date(), label: label,
                source: "review-confirmation", coordinate: coordinate,
                observationID: nil, rawImagePoint: nil)
        ]
        updateSummary(
            label: label, coordinate: coordinate, state: "Reviewed",
            confidence: 1)
        refreshGuesses()
    }

    private func updateSummary(
        label: String, coordinate: [Double], state: String, confidence: Double
    ) {
        guard var document = evidence else { return }
        if let index = document.summaries.firstIndex(where: { $0.label == label }) {
            document.summaries[index].coordinate = coordinate
            document.summaries[index].state = state
            document.summaries[index].confidence = confidence
        } else {
            document.summaries.append(ReceiverElectrodeSummary(
                label: label, coordinate: coordinate, supportCount: 0,
                spreadMeters: 0, confidence: confidence, state: state,
                rayResidualMeters: nil, surfaceDistanceMeters: nil))
        }
        evidence = document
    }

    private func summaries(
        for electrodes: [MANTAElectrodeSolution],
        existing: [ReceiverElectrodeSummary]
    ) -> [ReceiverElectrodeSummary] {
        let byLabel = Dictionary(uniqueKeysWithValues: existing.map { ($0.label, $0) })
        return electrodes.map { electrode in
            var summary = byLabel[electrode.label] ?? ReceiverElectrodeSummary(
                label: electrode.label, coordinate: electrode.coordinate,
                supportCount: 0, spreadMeters: 0, confidence: electrode.confidence,
                state: electrode.state, rayResidualMeters: nil,
                surfaceDistanceMeters: nil)
            summary.coordinate = electrode.coordinate
            summary.confidence = electrode.confidence
            summary.state = electrode.state
            return summary
        }.sorted { electrodeNumber($0.label) < electrodeNumber($1.label) }
    }

    private var cardinalLabels: Set<String> {
        let values = bundle.capture.layoutID.localizedCaseInsensitiveContains("256")
            ? [31, 67, 36, 224, 219, 72, 173, 114, 119, 168, 234, 237, 216, 199, 165, 145, 111, 91, 247, 244]
            : [17, 43, 24, 124, 120, 47, 98, 72, 68, 94]
        return Set(values.map { "E\($0)" }).union(["Cz"])
    }

    private func electrodeNumber(_ label: String) -> Int {
        Int(label.drop(while: { !$0.isNumber })) ?? .max
    }

    private func statusColor(_ state: String?) -> Color {
        switch state {
        case "Reviewed": .green
        case "Detected": .blue
        case "Needs Review": .orange
        case "Guessed": .yellow
        default: .gray
        }
    }

    private func rowStatus(_ solution: MANTAElectrodeSolution) -> String {
        if solution.state == "Guessed" {
            return solution.confidence.formatted(.percent.precision(.fractionLength(0)))
        }
        return solution.state == "Needs Review" ? "Review" : solution.state
    }

    private func summaryLine(_ summary: ReceiverElectrodeSummary) -> String {
        if summary.state == "Guessed" {
            var values = [
                "guess \(summary.confidence.formatted(.percent.precision(.fractionLength(0))))"
            ]
            if let gap = summary.surfaceDistanceMeters {
                values.append("surface \((gap * 1_000).formatted(.number.precision(.fractionLength(1)))) mm")
            }
            if let warning = summary.geometryWarning { values.append(warning) }
            return values.joined(separator: " · ")
        }
        var values = [
            "\(summary.supportCount) view\(summary.supportCount == 1 ? "" : "s")",
            "spread \((summary.spreadMeters * 1_000).formatted(.number.precision(.fractionLength(1)))) mm"
        ]
        if let gap = summary.surfaceDistanceMeters {
            values.append("surface \((gap * 1_000).formatted(.number.precision(.fractionLength(1)))) mm")
        }
        if let warning = summary.geometryWarning { values.append(warning) }
        return values.joined(separator: " · ")
    }

    private func refreshGuesses() {
        guard let evidence else { return }
        store.recalculateElectrodeGuesses(
            electrodes: workingElectrodes, evidence: evidence)
    }

    private var alignmentSignature: String {
        let reconstruction = bundle.capture.reconstruction
        return (reconstruction?.objectCaptureModelPath ?? "none") + "|"
            + (reconstruction?.modelToWorld ?? []).map { String($0) }.joined(separator: ",")
    }
}

private enum ReceiverElectrodeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case review = "Review"
    case reviewed = "Reviewed"
    case guesses = "Guesses"
    case missing = "Missing"
    var id: String { rawValue }
}

private struct ReceiverReprojectionDiagnostic {
    var rawPoint: [Double]
    var pixelError: Double?
    var depthDeltaMeters: Double?

    var isLargeError: Bool {
        (pixelError ?? 0) > 18 || (depthDeltaMeters ?? 0) > 0.015
    }

    var description: String {
        var values = ["3D→image"]
        if let pixelError {
            values.append("error \(pixelError.formatted(.number.precision(.fractionLength(1)))) px")
        } else {
            values.append("no matching observation")
        }
        if let depthDeltaMeters {
            values.append(
                "depth Δ \((depthDeltaMeters * 1_000).formatted(.number.precision(.fractionLength(1)))) mm")
        }
        return values.joined(separator: " · ")
    }
}

private struct ReceiverElectrodeImageCanvas: View {
    let image: ReceiverOrientedFrameImage?
    let observation: MANTACaptureObservation?
    let evidence: [ReceiverElectrodeObservationEvidence]
    let cupCandidates: [ReceiverUnlabeledCupEvidence]
    let selectedLabel: String?
    let projectedRawImagePoint: [Double]?
    let onPlace: (SIMD2<Float>) -> Void
    let onRelabel: (String) -> Void

    @State private var draggingEvidenceID: UUID?
    @State private var dragPreview: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.94)
                if let image, let observation {
                    let rawSize = CGSize(
                        width: observation.imageDimensions.width,
                        height: observation.imageDimensions.height)
                    let displaySize = image.orientation.displaySize(for: rawSize)
                    let rect = aspectFit(displaySize, in: geometry.size)
                    Image(nsImage: image.image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if draggingEvidenceID == nil {
                                draggingEvidenceID = nearestSelectedEvidence(
                                    to: value.startLocation, rawSize: rawSize,
                                    displaySize: displaySize, orientation: image.orientation,
                                    rect: rect)?.id
                            }
                            guard draggingEvidenceID != nil else { return }
                            dragPreview = value.location
                        }.onEnded { value in
                            let grabbedMarker = draggingEvidenceID != nil
                            let isClick = hypot(value.translation.width, value.translation.height) <= 4
                            draggingEvidenceID = nil
                            dragPreview = nil
                            guard (grabbedMarker || isClick), rect.contains(value.location) else { return }
                            place(
                                value.location, rect: rect, displaySize: displaySize,
                                rawSize: rawSize, orientation: image.orientation)
                        })
                        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                            guard let item = nearestEvidence(
                                to: value.location, rawSize: rawSize,
                                displaySize: displaySize, orientation: image.orientation,
                                rect: rect, maximumDistance: 30) else { return }
                            onRelabel(item.label)
                        })
                    ForEach(evidence) { item in
                        let marker = markerPoint(
                            item, rawSize: rawSize, displaySize: displaySize,
                            orientation: image.orientation, rect: rect)
                        if let textPoint = evidenceTextPoint(
                            item, rawSize: rawSize, displaySize: displaySize,
                            orientation: image.orientation, rect: rect) {
                            Path { path in
                                path.move(to: textPoint)
                                path.addLine(to: marker)
                            }
                            .stroke(.white.opacity(0.35), lineWidth: 1)
                            .allowsHitTesting(false)
                        }
                        Text(item.label)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                item.label == selectedLabel ? Color.pink : Color.yellow,
                                in: Capsule())
                            .overlay(Capsule().stroke(.black.opacity(0.65), lineWidth: 1))
                            .position(marker)
                            .allowsHitTesting(false)
                    }
                    ForEach(cupCandidates) { candidate in
                        let point = displayPoint(
                            rawImagePoint: candidate.rawImagePoint, rawSize: rawSize,
                            displaySize: displaySize, orientation: image.orientation,
                            rect: rect)
                        Circle()
                            .stroke(.mint.opacity(0.85), lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                            .position(point)
                            .allowsHitTesting(false)
                    }
                    if let projectedRawImagePoint {
                        let projected = displayPoint(
                            rawImagePoint: projectedRawImagePoint, rawSize: rawSize,
                            displaySize: displaySize, orientation: image.orientation,
                            rect: rect)
                        if let observed = evidence.first(where: {
                            $0.label == selectedLabel && $0.rawImagePoint.count == 2
                        }) {
                            let observedPoint = markerPoint(
                                observed, rawSize: rawSize, displaySize: displaySize,
                                orientation: image.orientation, rect: rect)
                            Path { path in
                                path.move(to: observedPoint)
                                path.addLine(to: projected)
                            }
                            .stroke(.cyan.opacity(0.8), style: StrokeStyle(
                                lineWidth: 1.5, dash: [4, 3]))
                            .allowsHitTesting(false)
                        }
                        Circle()
                            .stroke(.cyan, lineWidth: 2)
                            .frame(width: 18, height: 18)
                            .position(projected)
                            .allowsHitTesting(false)
                    }
                    if let dragPreview {
                        Circle()
                            .stroke(.pink, lineWidth: 3)
                            .frame(width: 20, height: 20)
                            .position(dragPreview)
                            .allowsHitTesting(false)
                    }
                } else if observation != nil {
                    ProgressView("Loading image…")
                        .foregroundStyle(.white)
                } else {
                    ContentUnavailableView("No RGB-D frame", systemImage: "photo")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func markerPoint(
        _ evidence: ReceiverElectrodeObservationEvidence,
        rawSize: CGSize,
        displaySize: CGSize,
        orientation: ReceiverStoredImageOrientation,
        rect: CGRect
    ) -> CGPoint {
        displayPoint(
            rawImagePoint: evidence.rawImagePoint, rawSize: rawSize,
            displaySize: displaySize, orientation: orientation, rect: rect)
    }

    private func evidenceTextPoint(
        _ evidence: ReceiverElectrodeObservationEvidence,
        rawSize: CGSize,
        displaySize: CGSize,
        orientation: ReceiverStoredImageOrientation,
        rect: CGRect
    ) -> CGPoint? {
        let point = evidence.ocrRawImagePoint
        guard point.count == 2, point != evidence.rawImagePoint else { return nil }
        return displayPoint(
            rawImagePoint: point, rawSize: rawSize,
            displaySize: displaySize, orientation: orientation, rect: rect)
    }

    private func displayPoint(
        rawImagePoint: [Double],
        rawSize: CGSize,
        displaySize: CGSize,
        orientation: ReceiverStoredImageOrientation,
        rect: CGRect
    ) -> CGPoint {
        guard rawImagePoint.count == 2 else { return .zero }
        let display = orientation.displayPoint(
            CGPoint(x: rawImagePoint[0], y: rawImagePoint[1]),
            rawSize: rawSize)
        return CGPoint(
            x: rect.minX + display.x / displaySize.width * rect.width,
            y: rect.minY + display.y / displaySize.height * rect.height)
    }

    private func nearestSelectedEvidence(
        to point: CGPoint, rawSize: CGSize, displaySize: CGSize,
        orientation: ReceiverStoredImageOrientation, rect: CGRect
    ) -> ReceiverElectrodeObservationEvidence? {
        nearestEvidence(
            to: point, rawSize: rawSize, displaySize: displaySize,
            orientation: orientation, rect: rect, maximumDistance: 28,
            matching: selectedLabel)
    }

    private func nearestEvidence(
        to point: CGPoint, rawSize: CGSize, displaySize: CGSize,
        orientation: ReceiverStoredImageOrientation, rect: CGRect,
        maximumDistance: CGFloat, matching label: String? = nil
    ) -> ReceiverElectrodeObservationEvidence? {
        evidence.filter { label == nil || $0.label == label }.min { lhs, rhs in
            distance(markerPoint(
                lhs, rawSize: rawSize, displaySize: displaySize,
                orientation: orientation, rect: rect), point)
                < distance(markerPoint(
                    rhs, rawSize: rawSize, displaySize: displaySize,
                    orientation: orientation, rect: rect), point)
        }.flatMap { item in
            distance(markerPoint(
                item, rawSize: rawSize, displaySize: displaySize,
                orientation: orientation, rect: rect), point) <= maximumDistance ? item : nil
        }
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func place(
        _ point: CGPoint, rect: CGRect, displaySize: CGSize, rawSize: CGSize,
        orientation: ReceiverStoredImageOrientation
    ) {
        let display = CGPoint(
            x: (point.x - rect.minX) / rect.width * displaySize.width,
            y: (point.y - rect.minY) / rect.height * displaySize.height)
        let raw = orientation.rawPoint(display, rawSize: rawSize)
        onPlace(SIMD2(Float(raw.x), Float(raw.y)))
    }

    private func aspectFit(_ content: CGSize, in available: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(available.width / content.width, available.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}

private extension SIMD2 where Scalar == Float {
    var doubles: [Double] { [Double(x), Double(y)] }
}

private extension SIMD3 where Scalar == Float {
    var doubles: [Double] { [Double(x), Double(y), Double(z)] }
}
