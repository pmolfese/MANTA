import AppKit
import MANTACore
import SwiftUI
import UniformTypeIdentifiers

struct ReceiverContentView: View {
    @StateObject private var store = ReceiverStore()
    @StateObject private var display = ReceiverDisplaySettings()
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

                if let bundle = store.bundle {
                    Section {
                        ReceiverDisplayControls(display: display)
                    } header: {
                        Text("Display")
                    }

                    Section {
                        ReceiverHeadBoundingBoxControls(store: store, display: display)
                    } header: {
                        HStack(spacing: 4) {
                            Text("Head Bounding Box")
                            ReceiverInfoButton(text: ReceiverGlossary.headBoundingBox)
                        }
                    }

                    ReconstructionSidebarSection(store: store, bundle: bundle)

                    MetadataSidebarSection(bundle: bundle, archiveURL: store.importedArchiveURL)
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
                BundleInspector(store: store, display: display, bundle: bundle)
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
    @ObservedObject var display: ReceiverDisplaySettings
    let bundle: MANTAValidatedBundle

    var body: some View {
        TabView {
            CaptureVisualizationView(store: store, display: display, bundle: bundle)
                .tabItem { Label("Viewer", systemImage: "viewfinder") }
            ReceiverAlignmentWorkspace(
                store: store,
                display: display,
                bundle: bundle,
                ephemeralReconstruction: store.ephemeralReconstruction)
                .id(alignmentWorkspaceID)
                .tabItem { Label("Align", systemImage: "point.3.connected.trianglepath.dotted") }
            ReceiverElectrodeWorkspace(store: store, display: display, bundle: bundle)
                .tabItem { Label("EEG Sensors", systemImage: "dot.scope") }
            ReceiverExportView(
                bundle: bundle,
                ephemeralReconstruction: store.ephemeralReconstruction)
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .navigationTitle("Capture Inspector")
    }

    /// Landmark clicks belong to one specific bundle and photogrammetry model.
    /// Reset the Align tab when either changes so picks from a recovered archive,
    /// an earlier reconstruction, or a newly saved PROCESSED child cannot leak
    /// into the next registration.
    private var alignmentWorkspaceID: String {
        let modelIdentity = store.ephemeralReconstruction?.modelURL.standardizedFileURL.path
            ?? bundle.capture.reconstruction?.objectCaptureModelPath
            ?? "no-model"
        return "\(bundle.manifest.bundleID.uuidString)|\(modelIdentity)"
    }

}

private struct ReceiverReconstructionView: View {
    @ObservedObject var store: ReceiverStore
    let bundle: MANTAValidatedBundle
    @State private var detail: ReceiverPhotogrammetryDetail = .full
    @State private var outputMode = ReceiverReconstructionOutputMode.derivedBundle
    @State private var inputMode = ReceiverPhotogrammetryInputMode.imagesOnly

    private var estimate: ReceiverReconstructionEstimate? {
        store.reconstructionEstimate(for: detail)
    }

    /// Depth-guided reconstruction is only offered when at least one frame has a
    /// saved depth map to hand Object Capture.
    private var hasDepthObservations: Bool {
        bundle.capture.observations.contains { $0.depth != nil }
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

                Picker("Inputs", selection: $inputMode) {
                    ForEach(ReceiverPhotogrammetryInputMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(store.isReconstructing || !hasDepthObservations)

                Text(hasDepthObservations
                     ? inputMode.explanation
                     : "This capture has no saved depth frames, so only images-only reconstruction is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: hasDepthObservations) { _, hasDepth in
                if !hasDepth { inputMode = .imagesOnly }
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
                        store.startReconstruction(
                            detail: detail, outputMode: outputMode, inputMode: inputMode)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)

                    Text("Full is the recommended first pass. RAW is never modified; saved edits update individual files in one PROCESSED package.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.reconstructionLog.isEmpty {
                Section {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 7) {
                                ForEach(store.reconstructionLog) { entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: logIcon(entry.level))
                                            .foregroundStyle(logColor(entry.level))
                                            .frame(width: 14)
                                        Text(entry.timestamp, format: .dateTime
                                            .hour().minute().second())
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(entry.message)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                        Spacer(minLength: 0)
                                    }
                                    .id(entry.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(minHeight: 120, maxHeight: 260)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: store.reconstructionLog.count) { _, _ in
                            guard let id = store.reconstructionLog.last?.id else { return }
                            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Reconstruction Log")
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                reconstructionLogText, forType: .string)
                        }
                        .labelStyle(.titleAndIcon)
                        Button("Clear", systemImage: "trash") {
                            store.clearReconstructionLog()
                        }
                        .labelStyle(.titleAndIcon)
                    }
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

    private var reconstructionLogText: String {
        let formatter = ISO8601DateFormatter()
        return store.reconstructionLog.map {
            "[\(formatter.string(from: $0.timestamp))] [\($0.level.rawValue.uppercased())] \($0.message)"
        }.joined(separator: "\n")
    }

    private func logIcon(_ level: ReceiverReconstructionLogLevel) -> String {
        switch level {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private func logColor(_ level: ReceiverReconstructionLogLevel) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
}

/// Reconstruction controls, folded into the sidebar. Collapsed by default once a
/// reconstruction already exists in the package (or a session preview is loaded).
private struct ReconstructionSidebarSection: View {
    @ObservedObject var store: ReceiverStore
    let bundle: MANTAValidatedBundle
    @State private var isExpanded: Bool?

    private var hasReconstruction: Bool {
        bundle.capture.reconstruction?.objectCaptureModelPath != nil
            || store.ephemeralReconstruction != nil
    }

    var body: some View {
        Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { isExpanded ?? !hasReconstruction },
                    set: { isExpanded = $0 })
            ) {
                ReceiverReconstructionView(store: store, bundle: bundle)
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 4) {
                    Label("Reconstruct", systemImage: "camera.metering.matrix")
                    ReceiverInfoButton(text: ReceiverGlossary.reconstruct)
                }
            }
        }
    }
}

/// Bundle metadata, folded into the sidebar as collapsible groups. Any group with
/// more than six rows (e.g. the file manifest) starts collapsed.
private struct MetadataSidebarSection: View {
    let bundle: MANTAValidatedBundle
    let archiveURL: URL?

    var body: some View {
        Section {
            metadataContent
        } header: {
            HStack(spacing: 4) {
                Text("Metadata")
                ReceiverInfoButton(text: ReceiverGlossary.metadata)
            }
        }
    }

    @ViewBuilder private var metadataContent: some View {
            group("Identity", count: bundle.manifest.parentBundleID == nil ? 5 : 6) {
                row("Package", bundle.manifest.parentBundleID == nil ? "RAW" : "PROCESSED")
                row("Bundle ID", bundle.manifest.bundleID.uuidString.lowercased())
                row("Session ID", bundle.manifest.sessionID.uuidString.lowercased())
                row("Schema", bundle.manifest.schemaVersion)
                row("Finalized", bundle.manifest.finalizedAt.formatted())
                if let parent = bundle.manifest.parentBundleID {
                    row("Parent", parent.uuidString.lowercased())
                }
            }
            group("Capture", count: 5) {
                row("Mode", bundle.capture.captureMode)
                row("Layout", bundle.capture.layoutID)
                row("Observations", "\(bundle.capture.observations.count)")
                row("Electrodes", "\(bundle.capture.electrodes?.count ?? 0)")
                row("Fiducials", "\(bundle.capture.fiducials?.count ?? 0)")
            }
            group("Producer", count: 5) {
                row("Application", bundle.manifest.producer.application)
                row("Version", "\(bundle.manifest.producer.version) (\(bundle.manifest.producer.build))")
                row("Platform", bundle.manifest.producer.platform)
                row("Device", bundle.manifest.producer.deviceModel)
                row("OS", bundle.manifest.producer.operatingSystemVersion)
            }
            group("Files", count: bundle.manifest.files.count) {
                ForEach(bundle.manifest.files, id: \.path) { file in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.path).font(.system(.caption, design: .monospaced))
                        HStack {
                            Text(file.role).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let archiveURL {
                group("Stored Copy", count: 1) {
                    Text(archiveURL.path)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
    }

    /// A collapsible metadata group; collapsed initially when it has >6 rows.
    private func group(
        _ title: String, count: Int, @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        CollapsibleGroup(title: title, initiallyExpanded: count <= 6, content: content)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
    }
}

/// DisclosureGroup with its own remembered expand state, seeded once.
private struct CollapsibleGroup<Content: View>: View {
    let title: String
    @State private var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(title: String, initiallyExpanded: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: $isExpanded) { content() }
    }
}

private extension UTType {
    static let mantaArchive = UTType(filenameExtension: "manta") ?? .zip
}
