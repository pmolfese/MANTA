//
//  ContentView.swift
//  MANTA
//
//  Created by Molfese, Peter  [E] on 7/10/26.
//

import SwiftUI
import MANTACore

struct ContentView: View {
    @StateObject private var viewModel = ScanSessionViewModel()
    @State private var showSidebar = false
    @State private var showLibrary = false

    var body: some View {
        ZStack(alignment: .leading) {
            ScanReviewView(viewModel: viewModel, showSidebar: $showSidebar, showLibrary: $showLibrary)

            if showSidebar {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showSidebar = false }
                    .transition(.opacity)

                SidebarView(viewModel: viewModel)
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .trailing) { Divider() }
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showSidebar)
        .sheet(isPresented: $viewModel.promptForModelFiducials) {
            ModelFiducialPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showLibrary) {
            SessionLibraryView(viewModel: viewModel)
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        List {
            Section {
                Text("MANTA")
                    .font(.title2.weight(.bold))
            }

            Section("Capture") {
                Picker("Mode", selection: $viewModel.session.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                if viewModel.session.captureMode.usesPhotogrammetry && !viewModel.isPhotogrammetrySupported {
                    Label("Photogrammetry isn't supported on this device.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Layout", selection: $viewModel.selectedLayoutName) {
                    ForEach(viewModel.availableLayouts, id: \.name) { layout in
                        Text("\(layout.channelCount)").tag(layout.name)
                    }
                }
                .onChange(of: viewModel.selectedLayoutName) { _, newValue in
                    viewModel.selectLayout(named: newValue)
                }

                Button {
                    Task {
                        await viewModel.runInitialDetection()
                    }
                } label: {
                    Label("Detect Electrodes", systemImage: "viewfinder")
                }
                .disabled(viewModel.isDetecting)
            }

            if viewModel.session.captureMode.usesPhotogrammetry {
                Section("Photogrammetry") {
                    Picker("Alignment", selection: $viewModel.session.alignmentStrategy) {
                        ForEach(WorldAlignmentStrategy.allCases) { strategy in
                            Text(strategy.rawValue).tag(strategy)
                        }
                    }

                    Text(viewModel.session.alignmentStrategy.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("ICP Seed", selection: $viewModel.session.alignmentSeed) {
                        ForEach(AlignmentSeed.allCases) { seed in
                            Text(seed.rawValue).tag(seed)
                        }
                    }

                    Text(viewModel.session.alignmentSeed.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if viewModel.requiresSourceLandmarks {
                        LabeledContent(
                            "Model fiducials",
                            value: viewModel.session.modelFiducialsReady ? "Placed" : "Needed"
                        )
                        Button {
                            viewModel.promptForModelFiducials = true
                        } label: {
                            Label("Mark Model Fiducials", systemImage: "hand.point.up.left")
                        }
                        .disabled(!viewModel.session.hasReconstructedModel)
                    }

                    LabeledContent("Frames captured", value: "\(viewModel.session.captureObservations.count)")

                    Button {
                        Task {
                            await viewModel.runReconstruction()
                        }
                    } label: {
                        Label("Reconstruct & Fuse", systemImage: "cube.transparent")
                    }
                    .disabled(!viewModel.canReconstruct)

                    if let blocker = viewModel.reconstructionBlocker {
                        Label(blocker, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let hint = viewModel.reconstructionHint {
                        Label(hint, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.isReconstructing {
                        HStack {
                            ProgressView(value: viewModel.reconstructionProgress ?? 0)
                            Text("\(Int((viewModel.reconstructionProgress ?? 0) * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Model", value: viewModel.session.hasReconstructedModel ? "Ready" : "Not built")
                }
            }

            Section("Session") {
                LabeledContent("Layout", value: viewModel.session.layout.name)
                LabeledContent("AR Samples", value: "\(viewModel.session.captureObservations.count)")
                if !viewModel.diagnosticsPath.isEmpty {
                    LabeledContent("Diagnostics", value: URL(fileURLWithPath: viewModel.diagnosticsPath).lastPathComponent)
                }
                LabeledContent("Detected", value: "\(viewModel.session.detectedElectrodeCount)")
                LabeledContent("Reviewed", value: "\(viewModel.session.reviewedElectrodeCount)")
                LabeledContent("Fiducials", value: viewModel.session.fiducialsReady ? "Placed" : "Needed")
            }

            Section("Export") {
                Picker("Format", selection: $viewModel.selectedFormat) {
                    ForEach(ElectrodeExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .onChange(of: viewModel.selectedFormat) { _, newValue in
                    viewModel.updateFormat(newValue)
                }
            }
        }
    }
}

private struct ScanReviewView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @Binding var showSidebar: Bool
    @Binding var showLibrary: Bool
    @State private var showExportPreview = false

    var body: some View {
        VStack(spacing: 0) {
            ScanHeaderView(
                viewModel: viewModel,
                showSidebar: $showSidebar,
                showLibrary: $showLibrary,
                showExportPreview: $showExportPreview
            )

            Divider()

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        LiveScanPanel(viewModel: viewModel)
                            .frame(height: min(480, geometry.size.height * 0.58))

                        Divider()

                        DetectionSummaryView(viewModel: viewModel)
                    }

                    if showExportPreview {
                        Divider()

                        ExportPreviewView(viewModel: viewModel)
                            .frame(width: min(420, geometry.size.width * 0.4))
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: showExportPreview)
            }
        }
        .navigationTitle(viewModel.session.name)
    }
}

private struct ScanHeaderView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @Binding var showSidebar: Bool
    @Binding var showLibrary: Bool
    @Binding var showExportPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    showSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.bordered)
                .help("Show settings")

                Button {
                    showLibrary = true
                } label: {
                    Label("Subjects", systemImage: "person.crop.rectangle.stack")
                }
                .buttonStyle(.bordered)
                .help("Subject library")

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.session.displayName)
                        .font(.title2.weight(.semibold))
                    Text(viewModel.statusMessage)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showExportPreview.toggle()
                } label: {
                    Label("Preview", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.exportDiagnostics()
                } label: {
                    Label("Save JSON", systemImage: "doc.badge.gearshape")
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await viewModel.runInitialDetection()
                    }
                } label: {
                    Label(viewModel.isDetecting ? "Detecting" : "Run Detection", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isDetecting)
            }

            HStack(spacing: 20) {
                Text("Electrodes: \(viewModel.session.detectedElectrodeCount)")
                Text("Reviewed: \(viewModel.session.reviewedElectrodeCount)")
                Text("Fiducials: \(viewModel.session.fiducialsReady ? "3/3" : "0/3")")
                Text("AR Samples: \(viewModel.session.captureObservations.count)")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct LiveScanPanel: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                LiveARScanView(scanViewModel: viewModel.scanViewModel) { point in
                    viewModel.handleScanTap(viewPoint: point)
                }

                ScanStatusOverlay(scanViewModel: viewModel.scanViewModel)
                    .padding(12)
            }

            Divider()

            FiducialControlsView(viewModel: viewModel)

            Divider()

            ScanControlsView(viewModel: viewModel, scanViewModel: viewModel.scanViewModel)
        }
    }
}

private struct FiducialControlsView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Fiducials")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(FiducialKind.allCases) { kind in
                let isPlaced = viewModel.session.fiducials.first { $0.kind == kind }?.coordinate != nil
                let isArmed = viewModel.fiducialPlacementKind == kind

                Button {
                    viewModel.armFiducialPlacement(kind)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaced ? "checkmark.circle.fill" : "circle")
                        Text(kind.rawValue)
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(isArmed ? .orange : (isPlaced ? .green : .secondary))
            }

            Spacer()

            if viewModel.isExportHeadFramed {
                Label("Head frame", systemImage: "scale.3d")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ScanStatusOverlay: View {
    @ObservedObject var scanViewModel: ARScanViewModel

    private var status: LiveScanStatus {
        scanViewModel.status
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusPill(title: "Tracking", value: status.trackingSummary, systemImage: "location.viewfinder")
            StatusPill(title: "Depth", value: status.hasSceneDepth ? "On" : "Waiting", systemImage: "square.3.layers.3d")
            StatusPill(title: "Mesh", value: "\(status.meshAnchorCount)", systemImage: "cube.transparent")
            StatusPill(title: "Frames", value: "\(status.frameCount)", systemImage: "camera")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusPill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } icon: {
            Image(systemName: systemImage)
                .frame(width: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ScanControlsView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @ObservedObject var scanViewModel: ARScanViewModel
    @State private var showRatePopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(scanViewModel.status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()
            }

            HStack(spacing: 16) {
                Button {
                    viewModel.startLiveScan()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!scanViewModel.status.isSupported || scanViewModel.status.isRunning)

                Button {
                    viewModel.pauseLiveScan()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!scanViewModel.status.isRunning)

                if viewModel.isAutoSampling {
                    Button {
                        viewModel.stopAutoSampling()
                    } label: {
                        Label("Stop Auto", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!scanViewModel.status.isSupported)
                    .simultaneousGesture(LongPressGesture().onEnded { _ in showRatePopover = true })
                    .popover(isPresented: $showRatePopover) { ratePopover }
                } else {
                    Button {
                        viewModel.startAutoSampling()
                    } label: {
                        Label("Auto Sample", systemImage: "camera.metering.matrix")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!scanViewModel.status.isSupported)
                    .simultaneousGesture(LongPressGesture().onEnded { _ in showRatePopover = true })
                    .popover(isPresented: $showRatePopover) { ratePopover }
                }

                Button {
                    viewModel.sampleCurrentARFrame()
                } label: {
                    Label("Sample Frame", systemImage: "camera.badge.ellipsis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!scanViewModel.status.isRunning)
            }
        }
        .padding(12)
    }

    private var ratePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto Sample Rate")
                .font(.headline)
            Stepper(
                "\(viewModel.autoSamplingInterval, specifier: "%.2f")s per sample",
                value: $viewModel.autoSamplingInterval,
                in: 0.25...3,
                step: 0.25
            )
        }
        .padding()
        .frame(minWidth: 240)
        .presentationCompactAdaptation(.popover)
    }
}

private struct DetectionSummaryView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        HStack(spacing: 0) {
            NetPopulationView(session: viewModel.session)
                .padding(12)
                .frame(maxWidth: .infinity)

            Divider()

            List {
                Section("Electrodes") {
                    if viewModel.session.electrodes.isEmpty {
                        ContentUnavailableView(
                            "No detections yet",
                            systemImage: "viewfinder",
                            description: Text("Run detection to create the first mock triangulation set.")
                        )
                    } else {
                        ForEach(viewModel.session.electrodes) { electrode in
                            ElectrodeRow(electrode: electrode) {
                                viewModel.toggleReviewed(electrode)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct NetPopulationView: View {
    var session: ScanSession

    private var detectedByLabel: [String: ElectrodeAnnotation] {
        Dictionary(uniqueKeysWithValues: session.electrodes.map { ($0.label, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Net Population", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Text("\(session.detectedElectrodeCount)/\(session.layout.channelCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                Canvas { context, size in
                    let drawable = CGRect(origin: .zero, size: size).insetBy(dx: 14, dy: 12)
                    let points = projectedPoints(in: drawable)

                    for electrode in session.layout.electrodes {
                        guard let start = points[electrode.number] else { continue }

                        for neighbor in electrode.neighbors where electrode.number < neighbor {
                            guard let end = points[neighbor] else { continue }
                            var path = Path()
                            path.move(to: start)
                            path.addLine(to: end)
                            context.stroke(path, with: .color(.secondary.opacity(0.22)), lineWidth: 0.7)
                        }
                    }

                    for electrode in session.layout.electrodes {
                        guard let point = points[electrode.number] else { continue }
                        let annotation = detectedByLabel[electrode.label]
                        let isDetected = annotation != nil
                        let isCardinal = electrode.role == .cardinal
                        let radius: CGFloat = isCardinal ? 5.2 : 3.4
                        let fillColor = nodeColor(for: annotation, isCardinal: isCardinal)
                        let rect = CGRect(
                            x: point.x - radius,
                            y: point.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )

                        context.fill(Path(ellipseIn: rect), with: .color(fillColor))

                        if isDetected || isCardinal {
                            context.stroke(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(fillColor.opacity(0.55)), lineWidth: 1)
                        }

                        if isCardinal, isDetected {
                            context.draw(
                                Text(electrode.label)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.primary),
                                at: CGPoint(x: point.x, y: point.y - 11)
                            )
                        }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 10) {
                        LegendItem(title: "Expected", color: .secondary.opacity(0.45))
                        LegendItem(title: "Detected", color: .teal)
                        LegendItem(title: "Reviewed", color: .blue)
                        LegendItem(title: "Cardinal", color: .orange)
                    }
                    .padding(8)
                }
            }
        }
    }

    private func projectedPoints(in rect: CGRect) -> [Int: CGPoint] {
        let positioned = session.layout.electrodes.compactMap { electrode -> (ElectrodeDefinition, Coordinate2D)? in
            guard let position = electrode.displayPosition else { return nil }
            return (electrode, position)
        }

        guard !positioned.isEmpty else {
            return fallbackRadialPoints(in: rect)
        }

        let xs = positioned.map { $0.1.x }
        let ys = positioned.map { $0.1.y }
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 1
        let rangeX = max(maxX - minX, 1)
        let rangeY = max(maxY - minY, 1)

        return Dictionary(uniqueKeysWithValues: positioned.map { electrode, position in
            let normalizedX = (position.x - minX) / rangeX
            let normalizedY = (position.y - minY) / rangeY
            let point = CGPoint(
                x: rect.minX + CGFloat(normalizedX) * rect.width,
                y: rect.minY + CGFloat(normalizedY) * rect.height
            )
            return (electrode.number, point)
        })
    }

    private func fallbackRadialPoints(in rect: CGRect) -> [Int: CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.44
        let count = max(session.layout.electrodes.count, 1)

        return Dictionary(uniqueKeysWithValues: session.layout.electrodes.enumerated().map { index, electrode in
            let angle = (Double(index) / Double(count)) * 2 * Double.pi - Double.pi / 2
            return (
                electrode.number,
                CGPoint(
                    x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius
                )
            )
        })
    }

    private func nodeColor(for annotation: ElectrodeAnnotation?, isCardinal: Bool) -> Color {
        guard let annotation else {
            return isCardinal ? .orange.opacity(0.36) : .secondary.opacity(0.38)
        }

        switch annotation.state {
        case .reviewed:
            return .blue
        case .detected, .needsReview:
            return isCardinal ? .orange : .teal
        case .missing:
            return .red
        }
    }
}

private struct LegendItem: View {
    var title: String
    var color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ElectrodeRow: View {
    var electrode: ElectrodeAnnotation
    var toggleReviewed: () -> Void

    private var isReviewed: Bool { electrode.state == .reviewed }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: electrode.role == .cardinal ? "largecircle.fill.circle" : "circle.fill")
                .foregroundStyle(electrode.role == .cardinal ? .blue : .teal)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(electrode.label)
                    .font(.headline)
                Text("\(coordinate(electrode.coordinate.x)), \(coordinate(electrode.coordinate.y)), \(coordinate(electrode.coordinate.z))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(electrode.state.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(Int(electrode.confidence * 100))%")
                    .font(.caption.monospacedDigit())
            }

            Button {
                toggleReviewed()
            } label: {
                Image(systemName: isReviewed ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(isReviewed ? Color.blue : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isReviewed ? "Mark as detected (undo review)" : "Mark reviewed")
        }
    }

    private func coordinate(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

private struct ExportPreviewView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(viewModel.selectedFormat.rawValue)
                    .font(.headline)
                Spacer()
                Label("Preview", systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                Text(viewModel.exportPreview.isEmpty ? "Run detection to preview an export." : viewModel.exportPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(.secondarySystemBackground))
        }
    }
}
