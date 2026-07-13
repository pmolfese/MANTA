import AppKit
import MANTACore
import SceneKit
import SwiftUI
import simd

struct CaptureVisualizationView: View {
    let bundle: MANTAValidatedBundle
    @State private var mode = CaptureViewMode.model
    @State private var observationIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Capture view", selection: $mode) {
                ForEach(CaptureViewMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 430)
            .padding(10)

            Divider()

            switch mode {
            case .camera:
                camera
            case .model:
                ReceiverHeadModelView(bundle: bundle)
            case .split:
                HSplitView {
                    camera
                    ReceiverHeadModelView(bundle: bundle)
                }
            }
        }
    }

    @ViewBuilder private var camera: some View {
        if bundle.capture.observations.isEmpty {
            ContentUnavailableView("No saved camera frames", systemImage: "camera")
        } else {
            VStack(spacing: 0) {
                StoredCameraFrameView(
                    root: bundle.rootDirectory,
                    observation: bundle.capture.observations[observationIndex],
                    electrodes: bundle.capture.electrodes ?? [],
                    fiducials: bundle.capture.fiducials ?? [])
                Divider()
                HStack {
                    Button("Previous", systemImage: "chevron.left") {
                        observationIndex = max(0, observationIndex - 1)
                    }.disabled(observationIndex == 0)
                    Slider(
                        value: Binding(
                            get: { Double(observationIndex) },
                            set: { observationIndex = Int($0.rounded()) }),
                        in: 0...Double(max(0, bundle.capture.observations.count - 1)), step: 1)
                    Text("Frame \(observationIndex + 1) of \(bundle.capture.observations.count)")
                        .monospacedDigit()
                    Button("Next", systemImage: "chevron.right") {
                        observationIndex = min(bundle.capture.observations.count - 1, observationIndex + 1)
                    }.disabled(observationIndex == bundle.capture.observations.count - 1)
                }
                .padding(10)
            }
        }
    }
}

private enum CaptureViewMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case model = "Live Model"
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
            if let image {
                let fitted = aspectFit(
                    image: CGSize(width: image.size.width, height: image.size.height),
                    in: geometry.size)
                ZStack {
                    Color.black
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit)
                    Canvas { context, _ in
                        drawAnnotations(in: &context, fitted: fitted)
                    }
                }
            } else {
                ContentUnavailableView("Frame image unavailable", systemImage: "photo.badge.exclamationmark")
            }
        }
        .overlay(alignment: .bottomLeading) { MarkerLegend().padding(12) }
    }

    private var image: NSImage? {
        guard let path = observation.imagePath else { return nil }
        return NSImage(contentsOf: root.appendingPathComponent(path))
    }

    private func drawAnnotations(in context: inout GraphicsContext, fitted: CGRect) {
        guard let camera = PinholeCamera(
            intrinsics: observation.intrinsics.map(Float.init),
            transform: observation.cameraToWorld.map(Float.init)) else { return }
        let sx = fitted.width / CGFloat(observation.imageDimensions.width)
        let sy = fitted.height / CGFloat(observation.imageDimensions.height)

        func screenPoint(_ coordinate: [Double]) -> CGPoint? {
            guard coordinate.count == 3,
                  let projection = camera.project(SIMD3<Float>(coordinate.map(Float.init))) else { return nil }
            let p = projection.pixel
            guard p.x >= 0, p.y >= 0,
                  p.x <= Float(observation.imageDimensions.width),
                  p.y <= Float(observation.imageDimensions.height) else { return nil }
            return CGPoint(x: fitted.minX + CGFloat(p.x) * sx, y: fitted.minY + CGFloat(p.y) * sy)
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

private struct ReceiverHeadModelView: View {
    let bundle: MANTAValidatedBundle
    private var surface: ReceiverSurface { ReceiverSurface(bundle: bundle) }

    var body: some View {
        ZStack {
            if surface.url != nil {
                ReceiverSceneView(
                    surface: surface,
                    electrodes: bundle.capture.electrodes ?? [],
                    fiducials: bundle.capture.fiducials ?? [])
            } else {
                ContentUnavailableView(
                    "No reconstructed surface",
                    systemImage: "cube.transparent",
                    description: Text("This capture contains camera evidence but no LiDAR mesh or ObjectCapture model."))
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 3) {
                Text(surface.title).font(.headline)
                Text("\(localizedCount) localized · \(provisionalCount) provisional · \(missingCount) missing")
                    .font(.caption).foregroundStyle(.secondary)
                if surface.needsAlignment {
                    Label("ObjectCapture model is not aligned to ARKit world coordinates",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
        .overlay(alignment: .bottomLeading) { MarkerLegend().padding(12) }
    }

    private var localizedCount: Int {
        (bundle.capture.electrodes ?? []).filter { $0.confidence > 0 && $0.state == "Reviewed" }.count
    }
    private var provisionalCount: Int {
        (bundle.capture.electrodes ?? []).filter { $0.confidence > 0 && $0.state != "Reviewed" }.count
    }
    private var missingCount: Int {
        (bundle.capture.electrodes ?? []).filter { $0.confidence == 0 || $0.state == "Missing" }.count
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

private struct ReceiverSurface {
    enum Kind { case lidar, objectCapture }
    var url: URL?
    var kind: Kind = .lidar
    var modelToWorld: simd_float4x4?
    var title: String { kind == .lidar ? "LiDAR Head Surface" : "ObjectCapture Head Model" }
    var needsAlignment: Bool { kind == .objectCapture && modelToWorld == nil }

    init(bundle: MANTAValidatedBundle) {
        let reconstruction = bundle.capture.reconstruction
        let meshPath = reconstruction?.lidarMeshPath
        let modelPath = reconstruction?.objectCaptureModelPath
        if let meshPath {
            url = bundle.rootDirectory.appendingPathComponent(meshPath); kind = .lidar
        } else if let modelPath {
            url = bundle.rootDirectory.appendingPathComponent(modelPath); kind = .objectCapture
        }
        if let values = reconstruction?.modelToWorld, values.count == 16 {
            modelToWorld = simd_float4x4(
                SIMD4(Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3])),
                SIMD4(Float(values[4]), Float(values[5]), Float(values[6]), Float(values[7])),
                SIMD4(Float(values[8]), Float(values[9]), Float(values[10]), Float(values[11])),
                SIMD4(Float(values[12]), Float(values[13]), Float(values[14]), Float(values[15])))
        }
    }
}

private struct ReceiverSceneView: NSViewRepresentable {
    let surface: ReceiverSurface
    let electrodes: [MANTAElectrodeSolution]
    let fiducials: [MANTAFiducialSolution]

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(white: 0.035, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        let scene = SCNScene()
        if let url = surface.url {
            if surface.kind == .lidar, let mesh = PLYMesh(data: try? Data(contentsOf: url)) {
                scene.rootNode.addChildNode(mesh.node)
            } else if let loaded = try? SCNScene(url: url) {
                let holder = SCNNode()
                loaded.rootNode.childNodes.forEach { holder.addChildNode($0.clone()) }
                if let transform = surface.modelToWorld { holder.simdTransform = transform }
                scene.rootNode.addChildNode(holder)
            }
        }
        if !surface.needsAlignment { addMarkers(to: scene) }
        view.scene = scene
        view.pointOfView = nil
        view.prepare(scene, shouldAbortBlock: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var signature = 0 }
    private var signature: Int {
        var hasher = Hasher()
        hasher.combine(surface.url)
        hasher.combine(electrodes.count)
        hasher.combine(fiducials.count)
        for electrode in electrodes {
            hasher.combine(electrode.label); hasher.combine(electrode.state)
            hasher.combine(electrode.confidence)
        }
        return hasher.finalize()
    }

    private func addMarkers(to scene: SCNScene) {
        for electrode in electrodes where electrode.coordinate.count == 3 {
            let style = MarkerStyle(electrode: electrode)
            addMarker(electrode.coordinate, label: electrode.label, color: style.nsColor,
                      wireframe: !style.filled, to: scene)
        }
        for fiducial in fiducials {
            guard let coordinate = fiducial.coordinate, coordinate.count == 3 else { continue }
            addMarker(coordinate, label: fiducial.kind, color: .systemPurple, wireframe: false, to: scene)
        }
    }

    private func addMarker(
        _ coordinate: [Double], label: String, color: NSColor, wireframe: Bool, to scene: SCNScene
    ) {
        let sphere = SCNSphere(radius: 0.0035)
        sphere.segmentCount = 14
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.35)
        material.fillMode = wireframe ? .lines : .fill
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.simdPosition = SIMD3(coordinate.map(Float.init))
        scene.rootNode.addChildNode(node)

        let text = SCNText(string: label, extrusionDepth: 0)
        text.font = NSFont.systemFont(ofSize: 7, weight: .semibold)
        text.flatness = 0.4
        text.firstMaterial?.diffuse.contents = NSColor.white
        let textNode = SCNNode(geometry: text)
        textNode.simdScale = SIMD3(repeating: 0.00045)
        textNode.simdPosition = node.simdPosition + SIMD3(0.006, 0.006, 0)
        textNode.constraints = [SCNBillboardConstraint()]
        scene.rootNode.addChildNode(textNode)
    }
}

private extension MarkerStyle {
    var nsColor: NSColor {
        if color == .green { return .systemGreen }
        if color == .orange { return .systemOrange }
        if color == .purple { return .systemPurple }
        return .systemGray
    }
}

private struct PLYMesh {
    let node: SCNNode
    init?(data: Data?) {
        guard let data, let marker = data.range(of: Data("end_header\n".utf8)) else { return nil }
        let header = String(decoding: data[..<marker.lowerBound], as: UTF8.self)
        var vertexCount = 0, faceCount = 0
        for line in header.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            if fields.count == 3, fields[0] == "element", fields[1] == "vertex" { vertexCount = Int(fields[2]) ?? 0 }
            if fields.count == 3, fields[0] == "element", fields[1] == "face" { faceCount = Int(fields[2]) ?? 0 }
        }
        guard vertexCount > 0 else { return nil }
        let bytes = [UInt8](data[marker.upperBound...]); var offset = 0
        func u32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
                UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        var points = [SCNVector3](); points.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            guard let x = u32(), let y = u32(), let z = u32() else { return nil }
            points.append(SCNVector3(Float(bitPattern: x), Float(bitPattern: y), Float(bitPattern: z)))
        }
        var indices = [UInt32](); indices.reserveCapacity(faceCount * 3)
        for _ in 0..<faceCount {
            guard offset < bytes.count, bytes[offset] == 3 else { break }; offset += 1
            guard let a = u32(), let b = u32(), let c = u32() else { break }
            indices.append(contentsOf: [a, b, c])
        }
        let source = SCNGeometrySource(vertices: points)
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: indices.count / 3, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemTeal.withAlphaComponent(0.28)
        material.emission.contents = NSColor.systemTeal.withAlphaComponent(0.12)
        material.fillMode = .lines; material.isDoubleSided = true
        geometry.materials = [material]; node = SCNNode(geometry: geometry)
    }
}
