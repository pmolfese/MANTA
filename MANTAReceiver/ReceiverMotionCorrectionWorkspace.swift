import AppKit
import SwiftUI
import SceneKit
import simd
import MANTACore
import MANTAProcessing

struct ReceiverMotionPass: Identifiable {
    let surface: ReceiverArchivedLiDARPass
    let observations: [MANTACaptureObservation]
    var id: UUID { surface.id }
    var included: Bool
    var reviewedStable = false
    var firstFrame = 0
    var lastFrame: Int
    var bounds: HeadBoundingBox
    var landmarks: [FiducialKind: SIMD3<Float>] = [:]

    var selectedFrames: [MANTACaptureObservation] {
        guard !observations.isEmpty, firstFrame >= 0, lastFrame >= firstFrame, lastFrame < observations.count else { return [] }
        return Array(observations[max(0, min(firstFrame, observations.count - 1))...max(0, min(lastFrame, observations.count - 1))])
    }
    var depthCount: Int { selectedFrames.filter { $0.depth?.confidencePath != nil }.count }
}

@MainActor final class ReceiverMotionCorrectionModel: ObservableObject {
    let bundle: MANTAValidatedBundle
    @Published var passes: [ReceiverMotionPass] = []
    @Published var referenceID: UUID?
    @Published var selectedID: UUID?
    @Published var landmark: FiducialKind = .nasion
    @Published private(set) var busy = false
    @Published private(set) var status = "Select stable intervals and mark matching landmarks."
    @Published private(set) var error: String?
    @Published private(set) var report: StableSegmentRecoveryReport?
    @Published private(set) var savedPackage: URL?
    private var approvedRequest: StableSegmentRecoveryRequest?
    private var previewDirectory: URL?

    init(bundle: MANTAValidatedBundle) {
        self.bundle = bundle
        do {
            var surfaces = try ReceiverArchivedLiDARPass.load(from: bundle)
            let grouped = Dictionary(grouping: bundle.capture.observations) { $0.quality?.motionAssessment?.segmentID }
            // The last pass of a native session is the active surface, not yet archived.
            if let reconstruction = bundle.capture.reconstruction,
               reconstruction.lidarMeshPath != nil || reconstruction.headCroppedLidarMeshPath != nil {
                let remaining = grouped.keys.compactMap { $0 }.filter { id in !surfaces.contains { $0.id == id } }
                if remaining.count == 1, let id = remaining.first {
                    surfaces.append(ReceiverArchivedLiDARPass(id: id, frameCount: grouped[id]?.count ?? 0,
                        reconstruction: reconstruction, fiducials: bundle.capture.fiducials ?? []))
                }
            }
            passes = surfaces.compactMap { surface in
                let frames = (grouped[surface.id] ?? []).sorted { $0.capturedAt < $1.capturedAt }
                guard !frames.isEmpty else { return nil }
                return ReceiverMotionPass(surface: surface, observations: frames,
                    included: frames.filter { $0.depth?.confidencePath != nil }.count >= 3,
                    lastFrame: frames.count - 1,
                    bounds: surface.reconstruction.headBoundingBox ?? HeadBoundingBox(
                        center: Coordinate3D(x: 0, y: 0, z: -0.5), widthMeters: 0.4, heightMeters: 0.46, depthMeters: 0.4))
            }
            referenceID = passes.first(where: \.included)?.id
            selectedID = passes.first(where: { $0.included && $0.id != referenceID })?.id ?? passes.first?.id
        } catch { self.error = error.localizedDescription }
    }

    deinit { if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) } }

    func update(_ id: UUID, _ change: (inout ReceiverMotionPass) -> Void) {
        guard !busy, let index = passes.firstIndex(where: { $0.id == id }) else { return }
        change(&passes[index])
        invalidate()
    }
    func invalidate() {
        report = nil; approvedRequest = nil; error = nil; savedPackage = nil
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
        status = "Selection changed. Preview the correction before saving."
    }
    func request(automatic: Bool = false) throws -> StableSegmentRecoveryRequest {
        func fail(_ message: String) -> NSError { NSError(domain: "MANTA.MotionCorrection", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        let chosen = passes.filter(\.included)
        guard (2...8).contains(chosen.count), let referenceID, chosen.contains(where: { $0.id == referenceID }) else {
            throw fail("Include 2–8 passes and choose an included reference pass.")
        }
        let ordered = chosen.sorted { lhs, rhs in
            if lhs.id == referenceID { return rhs.id != referenceID }; if rhs.id == referenceID { return false }
            return (lhs.observations.first?.capturedAt ?? .distantPast) < (rhs.observations.first?.capturedAt ?? .distantPast)
        }
        let kinds = automatic ? [] : FiducialKind.allCases.filter { ordered[0].landmarks[$0] != nil }
        guard automatic || kinds.count >= 3 else { throw fail("Mark at least three matching, well-spread landmarks on the reference and every included pass.") }
        var segments: [StableSegmentRecoveryRequest.Segment] = []
        for pass in ordered {
            guard pass.reviewedStable else { throw fail("Confirm that every selected interval shows a stable head and unchanged cap.") }
            guard pass.depthCount >= 3 else { throw fail("Every included interval needs at least three frames with depth and confidence. Exclude short passes or select a longer interval.") }
            guard pass.selectedFrames.count <= 256 else { throw fail("Select at most 256 frames per interval.") }
            guard automatic || Set(pass.landmarks.keys) == Set(kinds) else { throw fail("Use the same landmark names on every included pass. Clear unmatched optional landmarks or place their counterparts.") }
            let points = kinds.compactMap { pass.landmarks[$0] }
            guard automatic || SegmentRegistration.noncollinear(points) else { throw fail("Landmarks must be well spread and noncollinear.") }
            segments.append(.init(bundlePath: bundle.rootDirectory.path, segmentID: pass.id,
                observationIDs: pass.selectedFrames.map(\.id), reviewedStable: true, headBounds: pass.bounds,
                landmarks: kinds.map { kind in
                    let point = pass.landmarks[kind]!
                    return .init(name: kind.rawValue, coordinate: [point.x, point.y, point.z])
                }))
        }
        return .init(acquisitionGroupID: bundle.manifest.sessionID.uuidString, segments: segments, automaticAlignment: automatic)
    }

    var readiness: String? { do { _ = try request(); return nil } catch { return error.localizedDescription } }

    var automaticReadiness: String? { do { _ = try request(automatic: true); return nil } catch { return error.localizedDescription } }

    func preview(automatic: Bool = false) async {
        guard !busy else { return }
        invalidate()
        do {
            let request = try request(automatic: automatic)
            busy = true; defer { busy = false }
            status = automatic ? "Searching geometric alignments, checking ambiguity and withheld frames…" : "Checking depth, registering passes, and checking each selected frame…"
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("manta-motion-preview-\(UUID())")
            previewDirectory = output
            let report = try await Task.detached(priority: .userInitiated) {
                try StableSegmentRecovery.run(request, output: output)
            }.value
            self.report = report
            approvedRequest = report.accepted ? request : nil
            status = report.accepted ? "Preview passed geometric checks. Inspect the colored overlay before accepting."
                : "Correction rejected. Review the reported frames, interval selection, and landmarks."
        } catch { self.error = error.localizedDescription; status = "Preview could not complete." }
    }

    func save(to output: URL) async {
        guard !busy, let report, report.accepted, let request = approvedRequest else { return }
        busy = true; defer { busy = false }
        error = nil; status = "Verifying the approved correction and rebuilding fused depth…"
        do {
            let package = try await Task.detached(priority: .userInitiated) {
                try Self.saveReviewed(request: request, report: report, output: output)
            }.value
            savedPackage = package
            status = "Corrected capture and fused depth saved. Original passes are unchanged."
        } catch { self.error = error.localizedDescription; status = "Save failed; originals are unchanged." }
    }

    nonisolated static func saveReviewed(request: StableSegmentRecoveryRequest, report: StableSegmentRecoveryReport, output: URL) throws -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let staging = output.deletingLastPathComponent().appendingPathComponent(".motion-correction-\(UUID()).partial")
        defer { try? fm.removeItem(at: staging) }
        _ = try StableSegmentRecovery.run(request, output: staging, emitDerived: true, approvedPreview: report)
        guard let package = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "manta" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let corrected = try MANTABundleValidator().validate(directory: package)
        let cloud = try ReceiverDepthFusion.fuse(.init(rootDirectory: package, observations: corrected.capture.observations,
            declaredBounds: corrected.capture.reconstruction?.headBoundingBox, headMeshURL: nil, fiducialCoordinates: []))
        try ReceiverSurfaceExporter.writePointCloud(cloud, to: staging.appendingPathComponent("corrected-depth.ply"))
        try fm.moveItem(at: staging, to: output)
        return output.appendingPathComponent(package.lastPathComponent)
    }
}

struct ReceiverMotionCorrectionWorkspace: View {
    @ObservedObject var store: ReceiverStore
    @StateObject private var model: ReceiverMotionCorrectionModel
    @State private var hiddenSegments: Set<UUID> = []

    init(store: ReceiverStore, bundle: MANTAValidatedBundle) {
        self.store = store
        _model = StateObject(wrappedValue: ReceiverMotionCorrectionModel(bundle: bundle))
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text("Register stable passes").font(.title2.bold())
            Text("Select intervals with a stable head and unchanged cap. Attempt automatic alignment, or mark matching landmarks. Inspect the preview before saving a separate corrected capture.")
                .font(.callout).foregroundStyle(.secondary)
            if model.passes.count < 2 {
                ContentUnavailableView("At least two saved passes are needed", systemImage: "square.stack.3d.up",
                    description: Text("Open a consolidated capture with LiDAR surfaces and depth. Already corrected captures can be viewed and exported in the other tabs."))
            } else {
                selectionBar
                HSplitView {
                    if let reference = model.passes.first(where: { $0.id == model.referenceID }) {
                        ReceiverMotionPassPanel(model: model, passID: reference.id, title: "Reference pass")
                            .id(reference.id)
                            .frame(minWidth: 290)
                    }
                    if let selected = model.passes.first(where: { $0.id == model.selectedID }) {
                        ReceiverMotionPassPanel(model: model, passID: selected.id, title: "Pass to match")
                            .id(selected.id)
                            .frame(minWidth: 290)
                    }
                }.frame(height: 570)
                if let report = model.report { previewResults(report).frame(height: 280) }
                HStack {
                    Button("Attempt automatic alignment") { Task {
                        store.isCorrectingMotion = true
                        defer { store.isCorrectingMotion = false }
                        await model.preview(automatic: true)
                    } }.buttonStyle(.borderedProminent)
                        .disabled(model.automaticReadiness != nil || model.busy)
                    Button("Preview with landmarks") { Task {
                        store.isCorrectingMotion = true
                        defer { store.isCorrectingMotion = false }
                        await model.preview()
                    } }
                        .disabled(model.readiness != nil || model.busy)
                    Button("Accept preview & save…") { Task { await save() } }
                        .disabled(model.report?.accepted != true || model.busy || model.savedPackage != nil)
                    if let package = model.savedPackage {
                        Button("Open corrected capture") { Task { await store.importArchive(from: package) } }
                        Button("Reveal result") { NSWorkspace.shared.activateFileViewerSelecting([package]) }
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if model.report == nil, let readiness = model.automaticReadiness {
                    Text(readiness).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.status).font(.callout)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(12)
        }
        .disabled(store.isImporting || store.isReconstructing || store.isApplyingAlignment || store.isDetectingElectrodes || store.isSavingElectrodes)
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker("Reference", selection: Binding(get: { model.referenceID }, set: { model.referenceID = $0; model.invalidate() })) {
                    ForEach(Array(model.passes.enumerated()), id: \.element.id) { index, pass in Text("Pass \(index + 1)").tag(Optional(pass.id)) }
                }
                Picker("Match", selection: $model.selectedID) {
                    ForEach(Array(model.passes.enumerated()), id: \.element.id) { index, pass in Text("Pass \(index + 1)").tag(Optional(pass.id)) }
                }
                Picker("Place landmark", selection: $model.landmark) {
                    ForEach(FiducialKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
            }
            HStack(alignment: .top) {
                ForEach(Array(model.passes.enumerated()), id: \.element.id) { index, pass in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Include pass \(index + 1)", isOn: Binding(get: { pass.included }, set: { value in model.update(pass.id) { $0.included = value } }))
                        Text("\(pass.observations.count) frames · \(pass.observations.filter { $0.depth?.confidencePath != nil }.count) depth")
                            .font(.caption).foregroundStyle(.secondary)
                        if pass.observations.filter({ $0.depth?.confidencePath != nil }).count < 3 {
                            Text("Too short: needs 3 depth frames").font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func previewResults(_ report: StableSegmentRecoveryReport) -> some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(report.accepted ? "Geometric checks passed — inspect before saving" : "Correction rejected").font(.headline)
                    ForEach(Array(report.entries.enumerated()), id: \.element.segmentID) { index, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("Show pass \((model.passes.firstIndex { $0.id == entry.segmentID } ?? index) + 1)\(index == 0 ? " (reference)" : "")", isOn: Binding(
                                get: { !hiddenSegments.contains(entry.segmentID) },
                                set: { if $0 { hiddenSegments.remove(entry.segmentID) } else { hiddenSegments.insert(entry.segmentID) } }))
                            Text(entry.registration.method == "geometry-multistart-rigid-icp-v1" ? "Automatic geometry alignment · held-out frame checks" : entry.registration.method == "reference-coordinate-frame" ? "Reference frame" : "Landmark-guided alignment").font(.caption.bold())
                            Text(entry.registration.reason).font(.caption)
                            Text("RMS \(millimeters(entry.registration.rmsMeters)) · landmarks \(millimeters(entry.registration.landmarkRMSMeters))")
                                .font(.caption.monospacedDigit())
                            Text("Overlap: \(percent(entry.registration.sourceOverlap)) / \(percent(entry.registration.referenceOverlap)) · rejected frames: \(entry.rejectedFrameIDs.count)")
                                .font(.caption)
                            if !entry.rejectedFrameIDs.isEmpty {
                                Text(entry.rejectedFrameIDs.map(\.uuidString).joined(separator: "\n"))
                                    .font(.caption2.monospaced()).textSelection(.enabled)
                            }
                            ForEach(entry.integrityWarnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        }.padding(6)
                    }
                    Text("Rigid correction only. These checks are not an independent accuracy measurement.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minWidth: 280, idealWidth: 360, maxWidth: 420)
            ReceiverMotionOverlay(report: report, hidden: hiddenSegments).frame(minWidth: 280)
        }
    }

    private func millimeters(_ value: Float?) -> String { value.map { String(format: "%.1f mm", $0 * 1000) } ?? "—" }
    private func percent(_ value: Float?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }

    private func save() async {
        let panel = NSOpenPanel()
        panel.title = "Save corrected capture"
        panel.message = "Choose a destination outside the original capture. A new folder will contain the corrected package, registration report, and fused depth."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let parent = panel.url else { return }
        let access = parent.startAccessingSecurityScopedResource()
        defer { if access { parent.stopAccessingSecurityScopedResource() } }
        let output = parent.appendingPathComponent("MANTA Motion Correction \(UUID().uuidString.prefix(8))")
        store.isCorrectingMotion = true
        await model.save(to: output)
        store.isCorrectingMotion = false
        if let corrected = model.savedPackage {
            store.rememberMotionCorrection(original: model.bundle.rootDirectory, corrected: corrected, outputAccess: parent)
        }
    }
}

private struct ReceiverMotionPassPanel: View {
    @ObservedObject var model: ReceiverMotionCorrectionModel
    let passID: UUID
    let title: String
    @StateObject private var display = ReceiverDisplaySettings()
    @State private var frame = 0
    @State private var showBounds = false

    private var pass: ReceiverMotionPass { model.passes.first { $0.id == passID }! }
    private var currentFrame: MANTACaptureObservation { pass.observations[min(frame, pass.observations.count - 1)] }
    private var viewBundle: MANTAValidatedBundle {
        let source = pass.surface.viewerBundle(from: model.bundle)
        var capture = source.capture
        capture.reconstruction?.headBoundingBox = pass.bounds
        return MANTAValidatedBundle(rootDirectory: source.rootDirectory, manifest: source.manifest, capture: capture, changeLog: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                Stepper("First: \(pass.firstFrame + 1)", value: Binding(get: { pass.firstFrame }, set: { value in
                    model.update(passID) { $0.firstFrame = min(value, $0.lastFrame); $0.reviewedStable = false }
                }), in: 0...max(0, pass.observations.count - 1))
                Stepper("Last: \(pass.lastFrame + 1)", value: Binding(get: { pass.lastFrame }, set: { value in
                    model.update(passID) { $0.lastFrame = max(value, $0.firstFrame); $0.reviewedStable = false }
                }), in: 0...max(0, pass.observations.count - 1))
            }.font(.caption)
            HStack {
                if let path = currentFrame.losslessImagePath ?? currentFrame.imagePath,
                   let image = ReceiverOrientedFrameImage.load(from: model.bundle.rootDirectory.appendingPathComponent(path),
                    orientation: ReceiverStoredImageOrientation.displayOrientation(for: currentFrame)) {
                    Image(nsImage: image.image).resizable().scaledToFit().frame(height: 100)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Frame \(min(frame + 1, pass.observations.count)) / \(pass.observations.count)").font(.caption)
                    Text(currentFrame.capturedAt.formatted(date: .omitted, time: .standard)).font(.caption)
                    Text(currentFrame.quality?.motionAssessment?.state.rawValue ?? "Motion unassessed").font(.caption)
                    Slider(value: Binding(get: { Double(frame) }, set: { frame = Int($0) }), in: 0...Double(max(1, pass.observations.count - 1)), step: 1)
                        .disabled(pass.observations.count <= 1)
                    HStack {
                        Button("Set first") { model.update(passID) { $0.firstFrame = frame; $0.lastFrame = max(frame, $0.lastFrame); $0.reviewedStable = false } }
                        Button("Set last") { model.update(passID) { $0.lastFrame = frame; $0.firstFrame = min(frame, $0.firstFrame); $0.reviewedStable = false } }
                    }.controlSize(.small)
                }
            }
            Toggle("I reviewed this interval: stable head, unchanged cap", isOn: Binding(get: { pass.reviewedStable }, set: { value in model.update(passID) { $0.reviewedStable = value } }))
                .font(.caption)
            DisclosureGroup("Head region (meters)", isExpanded: $showBounds) {
                HStack { boundsField("X", \.center.x); boundsField("Y", \.center.y); boundsField("Z", \.center.z) }
                HStack { boundsField("Width", \.widthMeters); boundsField("Height", \.heightMeters); boundsField("Depth", \.depthMeters) }
            }.font(.caption)
            HStack {
                Text("Click surface to place \(model.landmark.rawValue)").font(.caption)
                Spacer()
                Button("Frame") { display.requestFrame() }
                Picker("Surface", selection: $display.lidarChoice) {
                    ForEach(display.lidarChoices) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(maxWidth: 150)
            }
            CombinedModelViewer(bundle: viewBundle, display: display,
                worldTargetLandmarks: pass.landmarks.map { ReceiverModelLandmark(kind: $0.key, point: $0.value) },
                electrodesOverride: [], electrodePlacementLabel: model.landmark.rawValue,
                onWorldElectrodePointPicked: { point in
                    model.update(passID) { $0.landmarks[model.landmark] = SIMD3(Float(point.x), Float(point.y), Float(point.z)) }
                }, includesFiducialAnnotations: false)
                .frame(minHeight: 180)
            HStack {
                ForEach(FiducialKind.allCases) { kind in
                    VStack(spacing: 2) {
                        Text(kind.rawValue).font(.caption.bold())
                        if let point = pass.landmarks[kind] {
                            Text(String(format: "%.3f, %.3f, %.3f", point.x, point.y, point.z)).font(.system(size: 9, design: .monospaced))
                            Button("Clear") { model.update(passID) { $0.landmarks.removeValue(forKey: kind) } }.controlSize(.mini)
                        } else { Text("Not placed").font(.caption2).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(6)
        .onAppear { display.lidarStyle = .solid; display.showHeadBoundingBox = true }
        .onChange(of: pass.bounds) { _, bounds in
            display.configureBoundsDefaults(key: "\(passID)-\(bounds)", declared: bounds)
        }
    }

    private func boundsField(_ label: String, _ key: WritableKeyPath<HeadBoundingBox, Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            TextField(label, value: Binding(get: { pass.bounds[keyPath: key] }, set: { value in
                model.update(passID) { $0.bounds[keyPath: key] = value; $0.reviewedStable = false }
            }), format: .number.precision(.fractionLength(3)))
            .textFieldStyle(.roundedBorder).help(label + " in meters")
        }
    }
}

private struct ReceiverMotionOverlay: NSViewRepresentable {
    let report: StableSegmentRecoveryReport
    let hidden: Set<UUID>
    final class Coordinator { var key = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.backgroundColor = .black
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        let key = report.runID.uuidString + hidden.map(\.uuidString).sorted().joined()
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let scene = SCNScene()
        let palette: [NSColor] = [.cyan, .systemPink, .systemYellow, .systemGreen, .systemOrange, .systemPurple, .white, .systemBlue]
        var all: [SIMD3<Float>] = []
        for (index, entry) in report.entries.enumerated() where !hidden.contains(entry.segmentID) {
            guard let values = entry.registration.referenceFromSource, let transform = SegmentRegistration.matrix(values) else { continue }
            let points = (entry.previewPoints ?? []).filter { $0.count == 3 }.map {
                SegmentRegistration.point(SIMD3($0[0], $0[1], $0[2]), transform)
            }
            all += points
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points.map { SCNVector3($0.x, $0.y, $0.z) })],
                elements: [SCNGeometryElement(indices: Array(UInt32(0)..<UInt32(points.count)), primitiveType: .point)])
            geometry.elements.first?.pointSize = 4
            geometry.elements.first?.minimumPointScreenSpaceRadius = 2
            geometry.elements.first?.maximumPointScreenSpaceRadius = 4
            let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = palette[index % palette.count]
            geometry.materials = [material]
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        }
        let center = all.isEmpty ? SIMD3<Float>.zero : all.reduce(.zero, +) / Float(all.count)
        let radius = max(0.1, all.map { simd_distance($0, center) }.max() ?? 0.3)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.zNear = 0.001; camera.camera?.zFar = 100
        camera.simdPosition = center + SIMD3(radius * 1.2, radius * 0.5, radius * 3)
        camera.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(camera)
        view.scene = scene; view.pointOfView = camera
    }
}
