import AppKit
import MANTACore
import SwiftUI

struct CaptureVisualizationView: View {
    @ObservedObject var store: ReceiverStore
    @ObservedObject var display: ReceiverDisplaySettings
    let bundle: MANTAValidatedBundle
    @State private var mode = CaptureViewMode.model
    @State private var observationIndex = 0
    @State private var cameraZoom: CGFloat = 1
    @State private var lidarPasses: [ReceiverArchivedLiDARPass] = []
    @State private var geometrySelection = "capture"
    @State private var passLoadError: String?

    private var selectedPass: ReceiverArchivedLiDARPass? {
        lidarPasses.first { $0.id.uuidString == geometrySelection }
    }

    private var visibleObservations: [MANTACaptureObservation] {
        guard let selectedPass else { return bundle.capture.observations }
        return bundle.capture.observations.filter { $0.quality?.motionAssessment?.segmentID == selectedPass.id }
    }
    private var visibleIndex: Int { min(observationIndex, max(0, visibleObservations.count - 1)) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Capture view", selection: $mode) {
                ForEach(CaptureViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 430)
            .padding(10)

            if !lidarPasses.isEmpty {
                HStack {
                    Picker("3D surface", selection: $geometrySelection) {
                        Text("Current capture / photo model").tag("capture")
                        ForEach(Array(lidarPasses.enumerated()), id: \.element.id) { index, pass in
                            Text("LiDAR pass \(index + 1) · \(pass.frameCount) frames").tag(pass.id.uuidString)
                        }
                    }
                    .frame(maxWidth: 430)
                    Text(selectedPass == nil
                         ? "Saved LiDAR is available by pass. Overlay and combined depth fusion require registration."
                         : "Saved pass surface · original coordinates · read-only")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).padding(.bottom, 8)
            }
            if let passLoadError { Text(passLoadError).font(.caption).foregroundStyle(.orange) }
            if store.hasMotionComparison {
                HStack {
                    Button("Original passes") { if let url = store.motionOriginalURL { Task { await store.importArchive(from: url) } } }
                    Button("Corrected capture") { if let url = store.motionCorrectedURL { Task { await store.importArchive(from: url) } } }
                }.padding(.bottom, 8)
            }
            Divider()

            switch mode {
            case .camera:
                camera
            case .model:
                modelViewer
            case .split:
                HSplitView {
                    camera
                    modelViewer
                }
            }
        }
        .task(id: bundle.manifest.bundleID) {
            do {
                lidarPasses = try ReceiverArchivedLiDARPass.load(from: bundle)
                passLoadError = nil
                if selectedPass == nil { geometrySelection = "capture" }
            } catch { lidarPasses = []; geometrySelection = "capture"; passLoadError = error.localizedDescription }
            display.isViewingArchivedPass = selectedPass != nil
        }
        .onChange(of: geometrySelection) { _, _ in
            observationIndex = 0
            display.isViewingArchivedPass = selectedPass != nil
            display.requestFrame()
        }
        .onAppear { display.isViewingArchivedPass = selectedPass != nil }
        .onDisappear { display.isViewingArchivedPass = false }
    }

    private var modelViewer: some View {
        CombinedModelViewer(
            bundle: selectedPass?.viewerBundle(from: bundle) ?? bundle,
            display: display,
            modelToWorldOverride: selectedPass == nil ? store.ephemeralReconstruction?.modelToWorld : nil,
            photogrammetryURLOverride: selectedPass == nil ? store.ephemeralReconstruction?.modelURL : nil,
            fiducialSaveInProgress: store.isApplyingAlignment,
            onFiducialsSaved: selectedPass == nil ? { fiducials in
                Task { await store.applyFiducialCorrections(fiducials) }
            } : nil
        )
        .id(geometrySelection)
    }

    @ViewBuilder private var camera: some View {
        if visibleObservations.isEmpty {
            ContentUnavailableView("No saved camera frames", systemImage: "camera")
        } else {
            VStack(spacing: 0) {
                ReceiverZoomableImageArea(zoom: $cameraZoom) {
                    StoredCameraFrameView(
                        root: bundle.rootDirectory,
                        observation: visibleObservations[visibleIndex],
                        electrodes: selectedPass == nil ? bundle.capture.electrodes ?? [] : [],
                        fiducials: selectedPass?.fiducials ?? bundle.capture.fiducials ?? [])
                }
                Divider()
                HStack {
                    Button("Previous", systemImage: "chevron.left") {
                        observationIndex = max(0, observationIndex - 1)
                    }.disabled(observationIndex == 0)
                    if visibleObservations.count > 1 {
                        Slider(
                            value: Binding(
                                get: { Double(visibleIndex) },
                                set: { observationIndex = Int($0.rounded()) }),
                            in: 0...Double(visibleObservations.count - 1), step: 1)
                    } else {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 4)
                            .accessibilityHidden(true)
                    }
                    Text("Frame \(visibleIndex + 1) of \(visibleObservations.count)")
                        .monospacedDigit()
                    Button("Next", systemImage: "chevron.right") {
                        observationIndex = min(visibleObservations.count - 1, observationIndex + 1)
                    }.disabled(observationIndex == visibleObservations.count - 1)
                }
                .padding(10)
            }
        }
    }
}

private enum CaptureViewMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case model = "Interactive 3D"
    case split = "Split"
    var id: String { rawValue }
}

private struct StoredCameraFrameView: View {
    let root: URL
    let observation: MANTACaptureObservation
    let electrodes: [MANTAElectrodeSolution]
    let fiducials: [MANTAFiducialSolution]

    var body: some View {
        GeometryReader { geometry in
            if let frameImage {
                let fitted = aspectFit(
                    image: frameImage.image.size,
                    in: geometry.size)
                ZStack {
                    Color.black
                    Image(nsImage: frameImage.image)
                        .resizable().aspectRatio(contentMode: .fit)
                    Canvas { context, _ in
                        drawAnnotations(
                            in: &context,
                            fitted: fitted,
                            orientation: frameImage.orientation)
                    }
                }
            } else {
                ContentUnavailableView("Frame image unavailable", systemImage: "photo.badge.exclamationmark")
            }
        }
        .overlay(alignment: .bottomLeading) { MarkerLegend().padding(12) }
    }

    private var frameImage: ReceiverOrientedFrameImage? {
        guard let path = observation.losslessImagePath ?? observation.imagePath else { return nil }
        return ReceiverOrientedFrameImage.load(
            from: root.appendingPathComponent(path),
            orientation: ReceiverStoredImageOrientation.displayOrientation(for: observation))
    }

    private func drawAnnotations(
        in context: inout GraphicsContext,
        fitted: CGRect,
        orientation: ReceiverStoredImageOrientation
    ) {
        guard let camera = PinholeCamera(
            intrinsics: observation.intrinsics.map(Float.init),
            transform: observation.cameraToWorld.map(Float.init)) else { return }
        let rawSize = CGSize(
            width: observation.imageDimensions.width,
            height: observation.imageDimensions.height)
        let displaySize = orientation.displaySize(for: rawSize)
        let sx = fitted.width / displaySize.width
        let sy = fitted.height / displaySize.height

        func screenPoint(_ coordinate: [Double]) -> CGPoint? {
            guard coordinate.count == 3,
                  let projection = camera.project(SIMD3<Float>(coordinate.map(Float.init))) else { return nil }
            let p = projection.pixel
            guard p.x >= 0, p.y >= 0,
                  p.x <= Float(observation.imageDimensions.width),
                  p.y <= Float(observation.imageDimensions.height) else { return nil }
            let displayed = orientation.displayPoint(
                CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), rawSize: rawSize)
            return CGPoint(
                x: fitted.minX + displayed.x * sx,
                y: fitted.minY + displayed.y * sy)
        }

        for electrode in electrodes {
            guard let point = screenPoint(electrode.coordinate) else { continue }
            let style = MarkerStyle(electrode: electrode)
            drawMarker(at: point, label: electrode.label, style: style, context: &context)
        }
        for fiducial in fiducials {
            guard let coordinate = fiducial.coordinate, let point = screenPoint(coordinate) else { continue }
            drawMarker(at: point, label: fiducial.kind,
                       style: MarkerStyle(color: .purple, filled: true), context: &context)
        }
    }

    private func drawMarker(
        at point: CGPoint, label: String, style: MarkerStyle, context: inout GraphicsContext
    ) {
        let rect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
        if style.filled { context.fill(Path(ellipseIn: rect), with: .color(style.color)) }
        context.stroke(Path(ellipseIn: rect), with: .color(style.color), lineWidth: 2)
        context.draw(Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.white),
                     at: CGPoint(x: point.x + 10, y: point.y - 10), anchor: .leading)
    }

    private func aspectFit(image: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

private struct MarkerLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            LegendItem("Confirmed", .green, true)
            LegendItem("Provisional", .orange, false)
            LegendItem("Missing", .gray, false)
            LegendItem("Fiducials", .purple, true)
        }
        .padding(9).background(.regularMaterial, in: Capsule())
    }
}

private struct LegendItem: View {
    let title: String; let color: Color; let filled: Bool
    init(_ title: String, _ color: Color, _ filled: Bool) {
        self.title = title; self.color = color; self.filled = filled
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(filled ? color : .clear).stroke(color, lineWidth: 2).frame(width: 9, height: 9)
            Text(title).font(.caption2)
        }
    }
}

private struct MarkerStyle {
    var color: Color
    var filled: Bool
    init(color: Color, filled: Bool) { self.color = color; self.filled = filled }
    init(electrode: MANTAElectrodeSolution) {
        if electrode.confidence == 0 || electrode.state == "Missing" {
            color = .gray; filled = false
        } else if electrode.state == "Reviewed" {
            color = .green; filled = true
        } else {
            color = .orange; filled = false
        }
    }
}

/// A read-only view of one archived coordinate world. The parent capture remains
/// the input to reconstruction/export; choosing a mesh never rewrites that capture.
struct ReceiverArchivedLiDARPass: Identifiable {
    let id: UUID
    let frameCount: Int
    let reconstruction: MANTAReconstructionReference
    let fiducials: [MANTAFiducialSolution]

    static func load(from bundle: MANTAValidatedBundle) throws -> [Self] {
        let root = bundle.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let declared = Set(bundle.manifest.files.map(\.path))
        func checkedURL(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard declared.contains(path), !path.hasPrefix("/"),
                  !path.split(separator: "/").contains(".."), url.path.hasPrefix(root.path + "/") else {
                throw MANTABundleValidationError.invalidCapture("Unsafe or undeclared archived pass artifact: \(path)")
            }
            return url
        }
        return try (bundle.capture.capturePasses ?? []).compactMap { pass in
            guard let metadata = pass.artifactPaths.filter({ $0.hasSuffix("/session.json") })
                .min(by: { $0.count < $1.count }) else { return nil }
            let snapshot = try JSONDecoder().decode(ScanSession.self, from: Data(contentsOf: checkedURL(metadata)))
            let prefix = String(metadata.dropLast("session.json".count))
            func resolve(_ path: String?) throws -> String? {
                guard let path else { return nil }
                // Native archives already use root-relative paths. Consolidated
                // legacy snapshots preserve their original relative filenames.
                let candidate = pass.artifactPaths.contains(path) ? path : prefix + path
                guard pass.artifactPaths.contains(candidate) else {
                    throw MANTABundleValidationError.invalidCapture("Missing archived LiDAR artifact: \(candidate)")
                }
                let url = try checkedURL(candidate)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw MANTARawSessionRecoveryError.missingReferencedFile(candidate)
                }
                return candidate
            }
            let full = try resolve(snapshot.lidarMeshFilename)
            let head = try resolve(snapshot.headCroppedLidarMeshFilename)
            guard full != nil || head != nil else { return nil }
            return Self(id: pass.segmentID, frameCount: snapshot.captureObservations.count,
                reconstruction: MANTAReconstructionReference(lidarMeshPath: full, headCroppedLidarMeshPath: head,
                    headBoundingBox: snapshot.headBoundingBox, worldCoordinateSystem: "arkit-world"),
                fiducials: snapshot.fiducials.map {
                    MANTAFiducialSolution(kind: $0.kind.rawValue, coordinateSystem: "arkit-world",
                        coordinate: $0.coordinate.map { [$0.x, $0.y, $0.z] }, state: $0.state.rawValue)
                })
        }
    }

    func viewerBundle(from source: MANTAValidatedBundle) -> MANTAValidatedBundle {
        var capture = source.capture
        capture.observations = [] // This view shows the saved mesh, not a new fusion.
        capture.reconstruction = reconstruction
        capture.fiducials = fiducials
        capture.electrodes = nil
        capture.capturePasses = nil
        return MANTAValidatedBundle(rootDirectory: source.rootDirectory, manifest: source.manifest,
            capture: capture, changeLog: nil, integrityWarnings: source.integrityWarnings)
    }
}
