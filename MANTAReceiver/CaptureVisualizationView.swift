import AppKit
import MANTACore
import SwiftUI

struct CaptureVisualizationView: View {
    @ObservedObject var store: ReceiverStore
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
                modelViewer
            case .split:
                HSplitView {
                    camera
                    modelViewer
                }
            }
        }
    }

    private var modelViewer: some View {
        CombinedModelViewer(
            bundle: bundle,
            modelToWorldOverride: store.ephemeralReconstruction?.modelToWorld,
            photogrammetryURLOverride: store.ephemeralReconstruction?.modelURL,
            fiducialSaveInProgress: store.isApplyingAlignment
        ) { fiducials in
            Task { await store.applyFiducialCorrections(fiducials) }
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
            orientation: ReceiverStoredImageOrientation(observation.imageOrientation))
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
