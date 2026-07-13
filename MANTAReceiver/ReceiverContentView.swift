import MANTACore
import SwiftUI
import UniformTypeIdentifiers

struct ReceiverContentView: View {
    @StateObject private var store = ReceiverStore()
    @State private var showsImporter = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Transfer") {
                    Button("Import MANTA Capture…", systemImage: "square.and.arrow.down") {
                        showsImporter = true
                    }
                    .disabled(store.isImporting)
                }

                if let bundle = store.bundle {
                    Section("Imported Capture") {
                        Label("Validated", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        LabeledContent("Observations", value: "\(bundle.capture.observations.count)")
                        LabeledContent("Files", value: "\(bundle.manifest.files.count)")
                    }
                }
            }
            .navigationTitle("MANTA Receiver")
        } detail: {
            if store.isImporting {
                ProgressView("Copying and validating capture…")
            } else if let bundle = store.bundle {
                BundleInspector(bundle: bundle, archiveURL: store.importedArchiveURL)
            } else {
                ContentUnavailableView(
                    "Import a Capture",
                    systemImage: "wave.3.right.circle",
                    description: Text("Transfer a .manta file to this Mac, then import it for integrity validation and inspection.")
                )
            }
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.mantaArchive],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
                return
            }
            Task { await store.importArchive(from: url) }
        }
        .alert("Import Failed", isPresented: errorIsPresented) {
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
}

private struct BundleInspector: View {
    let bundle: MANTAValidatedBundle
    let archiveURL: URL?

    var body: some View {
        TabView {
            CaptureVisualizationView(bundle: bundle)
                .tabItem { Label("Capture", systemImage: "viewfinder") }
            metadata
                .tabItem { Label("Metadata", systemImage: "list.bullet.rectangle") }
        }
        .navigationTitle("Capture Inspector")
    }

    private var metadata: some View {
        Form {
            Section("Identity") {
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

private extension UTType {
    static let mantaArchive = UTType(filenameExtension: "manta") ?? .zip
}
