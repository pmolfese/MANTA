//
//  ContentView.swift
//  MANTA
//
//  Created by Molfese, Peter  [E] on 7/10/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ScanSessionViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationTitle("MANTA")
        } detail: {
            ScanReviewView(viewModel: viewModel)
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        List {
            Section("Capture") {
                Picker("Mode", selection: $viewModel.session.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
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

            Section("Session") {
                LabeledContent("Layout", value: viewModel.session.layout.name)
                LabeledContent("AR Samples", value: "\(viewModel.session.captureObservations.count)")
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

    var body: some View {
        VStack(spacing: 0) {
            ScanHeaderView(viewModel: viewModel)

            Divider()

            GeometryReader { geometry in
                if geometry.size.width > 760 {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            LiveScanPanel(viewModel: viewModel)
                                .frame(height: min(360, geometry.size.height * 0.48))

                            Divider()

                            DetectionSummaryView(viewModel: viewModel)
                        }
                        .frame(width: min(460, geometry.size.width * 0.46))

                        Divider()

                        ExportPreviewView(viewModel: viewModel)
                    }
                } else {
                    VStack(spacing: 0) {
                        LiveScanPanel(viewModel: viewModel)
                            .frame(height: geometry.size.height * 0.46)

                        Divider()

                        DetectionSummaryView(viewModel: viewModel)
                            .frame(height: geometry.size.height * 0.28)

                        Divider()

                        ExportPreviewView(viewModel: viewModel)
                    }
                }
            }
        }
        .navigationTitle(viewModel.session.name)
    }
}

private struct ScanHeaderView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EEG Electrode Triangulation")
                        .font(.title2.weight(.semibold))
                    Text(viewModel.statusMessage)
                        .foregroundStyle(.secondary)
                }

                Spacer()

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

            HStack(spacing: 12) {
                MetricTile(title: "Electrodes", value: "\(viewModel.session.detectedElectrodeCount)", systemImage: "smallcircle.filled.circle")
                MetricTile(title: "Reviewed", value: "\(viewModel.session.reviewedElectrodeCount)", systemImage: "checkmark.circle")
                MetricTile(title: "Fiducials", value: viewModel.session.fiducialsReady ? "3/3" : "0/3", systemImage: "scope")
                MetricTile(title: "AR Samples", value: "\(viewModel.session.captureObservations.count)", systemImage: "camera.metering.matrix")
            }
        }
        .padding()
    }
}

private struct LiveScanPanel: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                LiveARScanView(scanViewModel: viewModel.scanViewModel)

                ScanStatusOverlay(scanViewModel: viewModel.scanViewModel)
                    .padding(12)
            }

            Divider()

            ScanControlsView(viewModel: viewModel, scanViewModel: viewModel.scanViewModel)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(scanViewModel.status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.startLiveScan()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!scanViewModel.status.isSupported || scanViewModel.status.isRunning)

                Button {
                    viewModel.pauseLiveScan()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!scanViewModel.status.isRunning)

                Button {
                    viewModel.sampleCurrentARFrame()
                } label: {
                    Label("Sample Frame", systemImage: "camera.badge.ellipsis")
                }
                .buttonStyle(.bordered)
                .disabled(!scanViewModel.status.isRunning)

                Spacer()

                LabeledContent("Samples", value: "\(viewModel.session.captureObservations.count)")
                    .font(.caption)
            }
        }
        .padding(12)
    }
}

private struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetectionSummaryView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        List {
            Section("Fiducials") {
                ForEach(viewModel.session.fiducials) { fiducial in
                    HStack {
                        Text(fiducial.kind.rawValue)
                        Spacer()
                        Text(fiducial.coordinate == nil ? "Needed" : fiducial.state.rawValue)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                            viewModel.markReviewed(electrode)
                        }
                    }
                }
            }
        }
    }
}

private struct ElectrodeRow: View {
    var electrode: ElectrodeAnnotation
    var markReviewed: () -> Void

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
                markReviewed()
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderless)
            .disabled(electrode.state == .reviewed)
            .help("Mark reviewed")
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
