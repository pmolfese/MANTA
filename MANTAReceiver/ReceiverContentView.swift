import AppKit
import MANTACore
import SwiftUI
import UniformTypeIdentifiers

struct ReceiverContentView: View {
    @StateObject private var store = ReceiverStore()
    @State private var showsImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Transfer") {
                    Button("Import MANTA Capture…", systemImage: "square.and.arrow.down") {
                        showsImporter = true
                    }
                    .disabled(
                        store.isImporting || store.isReconstructing || store.isApplyingAlignment
                            || store.isDetectingElectrodes || store.isSavingElectrodes)
                }

                if let bundle = store.bundle {
                    Section("Imported Capture") {
                        Label("Validated", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        LabeledContent("Observations", value: "\(bundle.capture.observations.count)")
                        LabeledContent("Files", value: "\(bundle.manifest.files.count)")
                        LabeledContent(
                            "LiDAR",
                            value: bundle.capture.reconstruction?.lidarMeshPath == nil ? "None" : "Available")
                        LabeledContent(
                            "Head crop",
                            value: bundle.capture.reconstruction?.headCroppedLidarMeshPath == nil ? "None" : "Available")
                        LabeledContent(
                            "Photogrammetry",
                            value: bundle.capture.reconstruction?.objectCaptureModelPath == nil ? "None" : "Available")
                        LabeledContent(
                            "RGB-D frames",
                            value: "\(bundle.capture.observations.filter { $0.depth != nil }.count)")
                        if bundle.capture.reconstruction?.headCroppedLidarMeshPath != nil {
                            LabeledContent(
                                "Head bounds",
                                value: bundle.capture.reconstruction?.headBoundingBox == nil
                                    ? "Inferred by receiver" : "Declared")
                        }
                        if bundle.capture.reconstruction?.objectCaptureModelPath != nil {
                            LabeledContent(
                                "3D alignment",
                                value: bundle.capture.reconstruction?.modelToWorld == nil
                                    ? "Not declared" : "ARKit world")
                        }
                    }
                }

                if store.isReconstructing {
                    Section("Mac Reconstruction") {
                        ProgressView(value: store.reconstructionProgress)
                        Text(store.reconstructionStage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.isApplyingAlignment {
                    Section("Alignment Export") {
                        ProgressView()
                        Text(store.alignmentStage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("MANTA Receiver")
        } detail: {
            if store.isImporting {
                ProgressView("Copying and validating capture…")
            } else if let bundle = store.bundle {
                BundleInspector(store: store, bundle: bundle, archiveURL: store.importedArchiveURL)
            } else {
                ContentUnavailableView(
                    "Import a Capture",
                    systemImage: "wave.3.right.circle",
                    description: Text("Drop a RAW .manta archive, recovered .manta package, PROCESSED package, or iPad session folder here.")
                )
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted && !store.isImporting && !store.isReconstructing
                && !store.isApplyingAlignment && !store.isDetectingElectrodes
                && !store.isSavingElectrodes
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .padding(8)
                    .allowsHitTesting(false)
                    .overlay {
                        Label("Open MANTA Capture", systemImage: "square.and.arrow.down.fill")
                            .font(.title2.weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.regularMaterial, in: Capsule())
                    }
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.mantaArchive, .folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
                return
            }
            Task { await store.importArchive(from: url) }
        }
        .alert("Operation Failed", isPresented: errorIsPresented) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "The capture could not be imported.")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard !store.isImporting, !store.isReconstructing, !store.isApplyingAlignment,
              !store.isDetectingElectrodes, !store.isSavingElectrodes,
              let url = urls.first(where: Self.isMANTAArchive) else { return false }
        Task { await store.importArchive(from: url) }
        return true
    }

    nonisolated private static func isMANTAArchive(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return true
        }
        let name = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "manta" || name.hasSuffix(".manta.zip")
    }
}

private struct BundleInspector: View {
    @ObservedObject var store: ReceiverStore
    let bundle: MANTAValidatedBundle
    let archiveURL: URL?

    var body: some View {
        TabView {
            CaptureVisualizationView(store: store, bundle: bundle)
                .tabItem { Label("Viewer", systemImage: "viewfinder") }
            ReceiverReconstructionView(store: store, bundle: bundle)
                .tabItem { Label("Reconstruct", systemImage: "camera.metering.matrix") }
            ReceiverAlignmentWorkspace(
                store: store,
                bundle: bundle,
                ephemeralReconstruction: store.ephemeralReconstruction)
                .tabItem { Label("Align", systemImage: "point.3.connected.trianglepath.dotted") }
            ReceiverElectrodeWorkspace(store: store, bundle: bundle)
                .tabItem { Label("EEG Sensors", systemImage: "dot.scope") }
            ReceiverExportView(
                bundle: bundle,
                ephemeralReconstruction: store.ephemeralReconstruction)
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            metadata
                .tabItem { Label("Metadata", systemImage: "list.bullet.rectangle") }
        }
        .navigationTitle("Capture Inspector")
    }

    private var metadata: some View {
        Form {
            Section("Identity") {
                LabeledContent(
                    "Package",
                    value: bundle.manifest.parentBundleID == nil ? "RAW" : "PROCESSED")
                LabeledContent("Bundle ID", value: bundle.manifest.bundleID.uuidString.lowercased())
                LabeledContent("Session ID", value: bundle.manifest.sessionID.uuidString.lowercased())
                LabeledContent("Schema", value: bundle.manifest.schemaVersion)
                LabeledContent("Finalized", value: bundle.manifest.finalizedAt.formatted())
                if let parent = bundle.manifest.parentBundleID {
                    LabeledContent("Parent bundle", value: parent.uuidString.lowercased())
                }
            }

            Section("Capture") {
                LabeledContent("Mode", value: bundle.capture.captureMode)
                LabeledContent("Layout", value: bundle.capture.layoutID)
                LabeledContent("Observations", value: "\(bundle.capture.observations.count)")
                LabeledContent("Electrodes", value: "\(bundle.capture.electrodes?.count ?? 0)")
                LabeledContent("Fiducials", value: "\(bundle.capture.fiducials?.count ?? 0)")
            }

            Section("Producer") {
                LabeledContent("Application", value: bundle.manifest.producer.application)
                LabeledContent("Version", value: "\(bundle.manifest.producer.version) (\(bundle.manifest.producer.build))")
                LabeledContent("Platform", value: bundle.manifest.producer.platform)
                LabeledContent("Device", value: bundle.manifest.producer.deviceModel)
                LabeledContent("Operating system", value: bundle.manifest.producer.operatingSystemVersion)
            }

            Section("Files") {
                ForEach(bundle.manifest.files, id: \.path) { file in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(file.path).font(.system(.body, design: .monospaced))
                            Text(file.role).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let archiveURL {
                Section("Stored Copy") {
                    Text(archiveURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReceiverReconstructionView: View {
    @ObservedObject var store: ReceiverStore
    let bundle: MANTAValidatedBundle
    @State private var detail: ReceiverPhotogrammetryDetail = .full
    @State private var outputMode = ReceiverReconstructionOutputMode.derivedBundle

    private var estimate: ReceiverReconstructionEstimate? {
        store.reconstructionEstimate(for: detail)
    }

    var body: some View {
        Form {
            Section("Offline Object Capture") {
                Picker("Detail", selection: $detail) {
                    ForEach(ReceiverPhotogrammetryDetail.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(store.isReconstructing)

                Text(detail.explanation)
                    .foregroundStyle(.secondary)

                if detail == .raw {
                    Label(
                        "Raw can require tens of gigabytes of reconstruction workspace and model storage.",
                        systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }

                Picker("Output", selection: $outputMode) {
                    ForEach(ReceiverReconstructionOutputMode.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(store.isReconstructing)

                Text(outputMode == .preview
                     ? "Keeps the USDZ in temporary app storage for interactive inspection. PROCESSED is not changed."
                     : "Creates a mutable PROCESSED package from RAW, then writes only files changed by later edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preflight") {
                if let estimate {
                    LabeledContent("Source images", value: "\(estimate.imageCount)")
                    LabeledContent(
                        "Source image data",
                        value: bytes(estimate.sourceImageBytes))
                    LabeledContent(
                        "Conservative free-space target",
                        value: bytes(estimate.requiredWorkingBytes))
                    if let available = estimate.availableBytes {
                        LabeledContent("Available space", value: bytes(available))
                    }
                    if !estimate.hasEnoughSpace {
                        Label("Free additional storage before starting.", systemImage: "externaldrive.badge.xmark")
                            .foregroundStyle(.red)
                    }
                }

                if !store.supportsPhotogrammetryReconstruction {
                    Label("Object Capture is not supported on this Mac.", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
            }

            Section("Run") {
                if store.isReconstructing {
                    ProgressView(value: store.reconstructionProgress) {
                        Text(store.reconstructionStage)
                    } currentValueLabel: {
                        Text(store.reconstructionProgress, format: .percent.precision(.fractionLength(0)))
                    }

                    HStack {
                        if let started = store.reconstructionStartedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("Elapsed \(elapsed(from: started, to: context.date))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Cancel", role: .cancel) {
                            store.cancelReconstruction()
                        }
                        .disabled(!store.reconstructionCanCancel)
                    }

                    if !store.reconstructionCanCancel {
                        Text("The model is complete; MANTA is writing the changed model and metadata into PROCESSED.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(
                        outputMode == .preview
                            ? "Reconstruct \(detail.title) Preview"
                            : "Reconstruct \(detail.title) Model",
                        systemImage: "cube.transparent"
                    ) {
                        store.startReconstruction(detail: detail, outputMode: outputMode)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)

                    Text("Full is the recommended first pass. RAW is never modified; saved edits update individual files in one PROCESSED package.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let preview = store.ephemeralReconstruction {
                Section("Session Preview") {
                    Label(
                        preview.alignmentAccepted
                            ? "Interactive model ready and aligned"
                            : "Interactive model ready; automatic alignment was not accepted",
                        systemImage: preview.alignmentAccepted
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(preview.alignmentAccepted ? .green : .orange)
                    Text("Open Viewer → Interactive 3D to inspect it. The temporary model is removed when discarded, replaced, or the app session ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Discard Preview", role: .destructive) {
                        store.discardReconstructionPreview()
                    }
                }
            }

            if let archive = store.processedPackageURL {
                Section("PROCESSED Package") {
                    Label(
                        store.reconstructionAlignmentAccepted
                            ? "Photogrammetry aligned to the ARKit head geometry"
                            : "Model saved; automatic ARKit-world alignment was not accepted",
                        systemImage: store.reconstructionAlignmentAccepted
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.reconstructionAlignmentAccepted ? .green : .orange)
                    if let rms = store.reconstructionAlignmentRMSMeters {
                        LabeledContent(
                            "Alignment RMS",
                            value: Measurement(value: Double(rms), unit: UnitLength.meters)
                                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                        numberFormatStyle: .number.precision(.fractionLength(3)))))
                    }
                    Text(archive.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Reveal in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([archive])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var canStart: Bool {
        guard !store.isReconstructing,
              store.supportsPhotogrammetryReconstruction,
              let estimate else { return false }
        return estimate.imageCount > 0 && estimate.hasEnoughSpace
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
}

private extension UTType {
    static let mantaArchive = UTType(filenameExtension: "manta") ?? .zip
}
