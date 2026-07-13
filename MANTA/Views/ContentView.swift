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
    @State private var showExportPreview = false

    var body: some View {
        List {
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

                Toggle("Live Electrode Detection", isOn: $viewModel.liveDetectionEnabled)
                    .onChange(of: viewModel.liveDetectionEnabled) { _, enabled in
                        viewModel.setLiveDetectionEnabled(enabled)
                    }

                LabeledContent("Live results", value: "\(viewModel.liveDirectElectrodeCount)")
                Text(viewModel.liveDetectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await viewModel.finalizeElectrodeDetection()
                    }
                } label: {
                    Label("Finalize Electrode Detection", systemImage: "viewfinder")
                }
                .disabled(viewModel.isDetecting || viewModel.session.captureObservations.isEmpty)
            }

            if !viewModel.liveElectrodes.isEmpty || !viewModel.session.electrodes.isEmpty {
                Section("Detection Comparison") {
                    LabeledContent("Live localized", value: "\(viewModel.liveDirectElectrodeCount)")
                    LabeledContent("Finalized localized", value: "\(viewModel.finalizedDirectElectrodeCount)")
                    if let mean = viewModel.detectionComparisonMeanDistanceMM {
                        LabeledContent("Mean disagreement", value: String(format: "%.1f mm", mean))
                    } else {
                        Text("Finalize detection to compare shared electrode coordinates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

                Button {
                    showExportPreview.toggle()
                } label: {
                    Label(showExportPreview ? "Hide Preview" : "Preview", systemImage: "doc.text.magnifyingglass")
                }

                if showExportPreview {
                    ScrollView(.horizontal) {
                        Text(viewModel.exportPreview.isEmpty ? "Finalize detection to preview an export." : viewModel.exportPreview)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
    }
}

private struct ScanReviewView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @Binding var showSidebar: Bool
    @Binding var showLibrary: Bool
    @State private var visualMode: CaptureVisualMode = .split
    @State private var showPhoneReview = false

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        VStack(spacing: 0) {
            ScanHeaderView(
                viewModel: viewModel,
                showSidebar: $showSidebar,
                showLibrary: $showLibrary,
                compact: isPhone
            )

            Divider()

            GeometryReader { geometry in
                if isPhone {
                    VStack(spacing: 0) {
                        CaptureVisualTabs(
                            viewModel: viewModel,
                            selection: $visualMode,
                            splitHorizontally: geometry.size.width > geometry.size.height
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider()

                        PhoneCaptureBar(
                            viewModel: viewModel,
                            scanViewModel: viewModel.scanViewModel,
                            showReview: { showPhoneReview = true }
                        )
                    }
                } else if geometry.size.width > geometry.size.height {
                    HStack(spacing: 0) {
                        CaptureVisualTabs(
                            viewModel: viewModel,
                            selection: $visualMode,
                            splitHorizontally: true
                        )
                        .frame(width: geometry.size.width * 0.82)

                        Divider()

                        CaptureControlRail(
                            viewModel: viewModel,
                            scanViewModel: viewModel.scanViewModel
                        )
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        CaptureVisualTabs(
                            viewModel: viewModel,
                            selection: $visualMode,
                            splitHorizontally: true
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: geometry.size.height * 0.62)

                        Divider()

                        HStack(spacing: 0) {
                            PortraitReviewTabs(viewModel: viewModel)
                                .frame(width: geometry.size.width * 0.8)

                            Divider()

                            CompactCaptureControls(
                                viewModel: viewModel,
                                scanViewModel: viewModel.scanViewModel
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .navigationTitle(viewModel.session.name)
        .onAppear {
            if isPhone, visualMode == .split { visualMode = .camera }
        }
        .sheet(isPresented: $showPhoneReview) {
            NavigationStack {
                PortraitReviewTabs(viewModel: viewModel)
                    .navigationTitle("Capture Review")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showPhoneReview = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct ScanHeaderView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @Binding var showSidebar: Bool
    @Binding var showLibrary: Bool
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 12) {
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
                            Image(systemName: "person.crop.rectangle.stack")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Subjects")
                        .help("Subject library")
                    }

                    Text(viewModel.session.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: compact ? 150 : 230, alignment: .leading)
                        .padding(.leading, compact ? 0 : 48)
                }

                Spacer(minLength: 12)

                if compact {
                    CompactPhoneStatus(viewModel: viewModel)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 6) {
                        ScanStatusOverlay(viewModel: viewModel)
                        SessionStatusOverlay(viewModel: viewModel)
                    }
                    .frame(maxWidth: 520)
                    .layoutPriority(1)
                }
            }
        }
        .padding(compact ? 10 : 16)
    }
}

private struct CompactPhoneStatus: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        HStack(spacing: 8) {
            Label(viewModel.scanViewModel.status.trackingSummary, systemImage: "location.viewfinder")
            Divider().frame(height: 18)
            Label("\(viewModel.session.captureObservations.count)", systemImage: "camera")
            Divider().frame(height: 18)
            Label("\(viewModel.captureCoverageSectorCount)/24", systemImage: "circle.grid.3x3")
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct SessionStatusOverlay: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        HStack(spacing: 6) {
            StatusPill(
                title: "Electrodes",
                value: "\(viewModel.session.detectedElectrodeCount)",
                systemImage: "point.3.connected.trianglepath.dotted")
            StatusPill(
                title: "Live",
                value: "\(viewModel.liveDirectElectrodeCount)",
                systemImage: "dot.radiowaves.left.and.right")
            StatusPill(
                title: "Reviewed",
                value: "\(viewModel.session.reviewedElectrodeCount)",
                systemImage: "checkmark.seal")
            StatusPill(
                title: "Fiducials",
                value: viewModel.session.fiducialsReady ? "3/3" : "0/3",
                systemImage: "scope")
            StatusPill(
                title: "AR Samples",
                value: "\(viewModel.session.captureObservations.count)",
                systemImage: "camera")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LiveCameraSurface: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveARScanView(scanViewModel: viewModel.scanViewModel) { point in
                viewModel.handleScanTap(viewPoint: point)
            }

            if let prompt = viewModel.fiducialPlacementPrompt {
                Label(prompt, systemImage: "hand.tap.fill")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThickMaterial, in: Capsule())
                    .foregroundStyle(.orange)
                    .padding(12)
            }
        }
    }
}

private struct CaptureControlRail: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @ObservedObject var scanViewModel: ARScanViewModel
    @State private var showRatePopover = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            RoundCaptureButton(
                title: scanViewModel.status.isRunning ? "Pause" : "Start",
                systemImage: scanViewModel.status.isRunning ? "pause.fill" : "play.fill",
                tint: scanViewModel.status.isRunning ? .orange : .blue
            ) {
                if scanViewModel.status.isRunning {
                    viewModel.pauseLiveScan()
                } else {
                    viewModel.startLiveScan()
                }
            }
            .disabled(!scanViewModel.status.isSupported)

            RoundCaptureButton(
                title: viewModel.isAutoSampling ? "Stop Auto" : "Auto Sample",
                systemImage: viewModel.isAutoSampling ? "stop.fill" : "camera.metering.matrix",
                tint: viewModel.isAutoSampling ? .red : .blue
            ) {
                if viewModel.isAutoSampling {
                    viewModel.stopAutoSampling()
                } else {
                    viewModel.startAutoSampling()
                }
            }
            .disabled(!scanViewModel.status.isSupported || viewModel.isGuidedFiducialPlacementActive)
            .simultaneousGesture(LongPressGesture().onEnded { _ in showRatePopover = true })
            .popover(isPresented: $showRatePopover) { ratePopover }

            RoundCaptureButton(
                title: "Sample Frame",
                systemImage: "camera.badge.ellipsis",
                tint: .teal
            ) {
                viewModel.sampleCurrentARFrame()
            }
            .disabled(!scanViewModel.status.isRunning || viewModel.isGuidedFiducialPlacementActive)

            RoundCaptureButton(
                title: viewModel.isGuidedFiducialPlacementActive ? "Cancel Marks" : "Mark Fiducials",
                systemImage: viewModel.isGuidedFiducialPlacementActive ? "xmark" : "scope",
                tint: viewModel.isGuidedFiducialPlacementActive ? .orange : .purple
            ) {
                if viewModel.isGuidedFiducialPlacementActive {
                    viewModel.cancelGuidedFiducialPlacement()
                } else {
                    viewModel.startGuidedFiducialPlacement()
                }
            }
            .disabled(!scanViewModel.status.isRunning)

            Spacer(minLength: 8)

            Text(scanViewModel.status.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
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

private struct CompactCaptureControls: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @ObservedObject var scanViewModel: ARScanViewModel
    @State private var showRatePopover = false

    var body: some View {
        GeometryReader { geometry in
            let diameter = max(42, min(60, geometry.size.width - 16))
            VStack(spacing: 6) {
                Spacer(minLength: 4)

                RoundCaptureButton(
                    title: scanViewModel.status.isRunning ? "Pause" : "Start",
                    systemImage: scanViewModel.status.isRunning ? "pause.fill" : "play.fill",
                    tint: scanViewModel.status.isRunning ? .orange : .blue,
                    diameter: diameter
                ) {
                    if scanViewModel.status.isRunning {
                        viewModel.pauseLiveScan()
                    } else {
                        viewModel.startLiveScan()
                    }
                }
                .disabled(!scanViewModel.status.isSupported)

                RoundCaptureButton(
                    title: viewModel.isAutoSampling ? "Stop Auto" : "Auto Sample",
                    systemImage: viewModel.isAutoSampling ? "stop.fill" : "camera.metering.matrix",
                    tint: viewModel.isAutoSampling ? .red : .blue,
                    diameter: diameter
                ) {
                    if viewModel.isAutoSampling {
                        viewModel.stopAutoSampling()
                    } else {
                        viewModel.startAutoSampling()
                    }
                }
                .disabled(
                    !scanViewModel.status.isSupported
                        || viewModel.isGuidedFiducialPlacementActive)
                .simultaneousGesture(
                    LongPressGesture().onEnded { _ in showRatePopover = true })
                .popover(isPresented: $showRatePopover) { ratePopover }

                RoundCaptureButton(
                    title: "Sample Frame",
                    systemImage: "camera.badge.ellipsis",
                    tint: .teal,
                    diameter: diameter
                ) {
                    viewModel.sampleCurrentARFrame()
                }
                .disabled(
                    !scanViewModel.status.isRunning
                        || viewModel.isGuidedFiducialPlacementActive)

                RoundCaptureButton(
                    title: viewModel.isGuidedFiducialPlacementActive
                        ? "Cancel Marks" : "Mark Fiducials",
                    systemImage: viewModel.isGuidedFiducialPlacementActive ? "xmark" : "scope",
                    tint: viewModel.isGuidedFiducialPlacementActive ? .orange : .purple,
                    diameter: diameter
                ) {
                    if viewModel.isGuidedFiducialPlacementActive {
                        viewModel.cancelGuidedFiducialPlacement()
                    } else {
                        viewModel.startGuidedFiducialPlacement()
                    }
                }
                .disabled(!scanViewModel.status.isRunning)

                Text(scanViewModel.status.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 4)

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.secondarySystemBackground))
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

private struct PhoneCaptureBar: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @ObservedObject var scanViewModel: ARScanViewModel
    var showReview: () -> Void
    @State private var showRatePopover = false

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 0) {
                PhoneActionButton(
                    title: scanViewModel.status.isRunning ? "Pause" : "Start",
                    systemImage: scanViewModel.status.isRunning ? "pause.fill" : "play.fill",
                    tint: scanViewModel.status.isRunning ? .orange : .blue
                ) {
                    scanViewModel.status.isRunning
                        ? viewModel.pauseLiveScan() : viewModel.startLiveScan()
                }
                .disabled(!scanViewModel.status.isSupported)

                PhoneActionButton(
                    title: viewModel.isAutoSampling ? "Stop Auto" : "Auto",
                    systemImage: viewModel.isAutoSampling ? "stop.fill" : "camera.metering.matrix",
                    tint: viewModel.isAutoSampling ? .red : .blue
                ) {
                    viewModel.isAutoSampling
                        ? viewModel.stopAutoSampling() : viewModel.startAutoSampling()
                }
                .disabled(!scanViewModel.status.isSupported || viewModel.isGuidedFiducialPlacementActive)
                .simultaneousGesture(LongPressGesture().onEnded { _ in showRatePopover = true })
                .popover(isPresented: $showRatePopover) { ratePopover }

                PhoneActionButton(title: "Sample", systemImage: "camera.badge.ellipsis", tint: .teal) {
                    viewModel.sampleCurrentARFrame()
                }
                .disabled(!scanViewModel.status.isRunning || viewModel.isGuidedFiducialPlacementActive)

                PhoneActionButton(
                    title: viewModel.isGuidedFiducialPlacementActive ? "Cancel" : "Fiducials",
                    systemImage: viewModel.isGuidedFiducialPlacementActive ? "xmark" : "scope",
                    tint: viewModel.isGuidedFiducialPlacementActive ? .orange : .purple
                ) {
                    viewModel.isGuidedFiducialPlacementActive
                        ? viewModel.cancelGuidedFiducialPlacement()
                        : viewModel.startGuidedFiducialPlacement()
                }
                .disabled(!scanViewModel.status.isRunning)

                PhoneActionButton(title: "Review", systemImage: "point.3.connected.trianglepath.dotted", tint: .indigo) {
                    showReview()
                }
            }

            Text(scanViewModel.status.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground))
    }

    private var ratePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto Sample Rate").font(.headline)
            Stepper(
                "\(viewModel.autoSamplingInterval, specifier: "%.2f")s per sample",
                value: $viewModel.autoSamplingInterval, in: 0.25...3, step: 0.25)
        }
        .padding().frame(minWidth: 240)
        .presentationCompactAdaptation(.popover)
    }
}

private struct PhoneActionButton: View {
    var title: String
    var systemImage: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum CaptureVisualMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case model = "Live Model"
    case split = "Split"
    var id: String { rawValue }
}

private struct CaptureVisualTabs: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @Binding var selection: CaptureVisualMode
    var splitHorizontally: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Capture view", selection: $selection) {
                ForEach(CaptureVisualMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch selection {
            case .camera:
                LiveCameraSurface(viewModel: viewModel)
            case .model:
                LiveHeadModelView(viewModel: viewModel)
            case .split:
                if splitHorizontally {
                    HStack(spacing: 0) {
                        LiveCameraSurface(viewModel: viewModel)
                        Divider()
                        LiveHeadModelView(viewModel: viewModel)
                    }
                } else {
                    VStack(spacing: 0) {
                        LiveCameraSurface(viewModel: viewModel)
                        Divider()
                        LiveHeadModelView(viewModel: viewModel)
                    }
                }
            }
        }
        .onChange(of: viewModel.isGuidedFiducialPlacementActive) { _, active in
            if active, selection == .model { selection = .camera }
        }
    }
}

private struct RoundCaptureButton: View {
    var title: String
    var systemImage: String
    var tint: Color
    var diameter: CGFloat = 88
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: diameter < 72 ? 15 : 22, weight: .semibold))
                Text(title)
                    .font(.system(size: diameter < 72 ? 9 : 12, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(tint, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct ScanStatusOverlay: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    private var status: LiveScanStatus {
        viewModel.scanViewModel.status
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusPill(title: "Tracking", value: status.trackingSummary, systemImage: "location.viewfinder")
            StatusPill(title: "Depth", value: status.hasSceneDepth ? "On" : "Waiting", systemImage: "square.3.layers.3d")
            StatusPill(title: "Mesh", value: "\(status.meshAnchorCount)", systemImage: "cube.transparent")
            StatusPill(title: "Saved", value: "\(viewModel.session.captureObservations.count)", systemImage: "camera")
            StatusPill(title: "Coverage", value: "\(viewModel.captureCoverageSectorCount)", systemImage: "circle.grid.3x3")
        }
        .frame(maxWidth: .infinity)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PortraitReviewTabs: View {
    enum ReviewTab: String, CaseIterable, Identifiable {
        case population = "Net Population"
        case electrodes = "Electrodes"
        var id: String { rawValue }
    }

    @ObservedObject var viewModel: ScanSessionViewModel
    @State private var selection: ReviewTab = .population

    var body: some View {
        VStack(spacing: 0) {
            Picker("Review", selection: $selection) {
                ForEach(ReviewTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            switch selection {
            case .population:
            NetPopulationView(session: viewModel.session)
                .padding(10)
                .frame(maxWidth: .infinity)
            case .electrodes:
            List {
                Section("Electrodes") {
                    if viewModel.session.electrodes.isEmpty {
                        ContentUnavailableView(
                            "No detections yet",
                            systemImage: "viewfinder",
                            description: Text("Finalize detection to solve electrodes from the captured frames.")
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
