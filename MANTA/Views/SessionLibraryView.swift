//
//  SessionLibraryView.swift
//  MANTA
//
//  Subject library: browse persisted sessions (newest first), open one to review
//  or reprocess, start a new capture, and rename subjects. The capture date/time
//  is always shown and drives the sort, so it stays paired with the subject label
//  no matter how a session is renamed.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SessionLibraryView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newSubject = ""
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                Section("New session") {
                    HStack {
                        TextField("Subject / MRN (optional)", text: $newSubject)
                            .textInputAutocapitalization(.characters)
                        Button("Start") {
                            let label = newSubject.trimmingCharacters(in: .whitespacesAndNewlines)
                            viewModel.startNewSession(subjectLabel: label.isEmpty ? nil : label)
                            newSubject = ""
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Section("Subjects") {
                    if viewModel.sessionSummaries.isEmpty {
                        ContentUnavailableView(
                            "No saved sessions",
                            systemImage: "person.crop.rectangle.stack",
                            description: Text("Start a new session, then sample frames to save it here.")
                        )
                    } else {
                        ForEach(viewModel.sessionSummaries) { summary in
                            Button {
                                viewModel.openSession(id: summary.id)
                                dismiss()
                            } label: {
                                SessionRow(summary: summary, isCurrent: summary.id == viewModel.session.id)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    viewModel.deleteSession(id: summary.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    renameText = summary.subjectLabel ?? ""
                                    renameTarget = summary
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                                Button {
                                    viewModel.exportSession(id: summary.id)
                                } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }
                                .tint(.green)
                            }
                            .contextMenu {
                                Button {
                                    viewModel.exportSession(id: summary.id)
                                } label: {
                                    Label("Export bundle", systemImage: "square.and.arrow.up")
                                }
                                Button {
                                    renameText = summary.subjectLabel ?? ""
                                    renameTarget = summary
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    viewModel.deleteSession(id: summary.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Subjects")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { viewModel.refreshSessions() }
            .sheet(item: $viewModel.exportedBundle) { bundle in
                ShareSheet(items: [bundle.url])
            }
            .alert("Rename subject", isPresented: renameIsPresented) {
                TextField("Subject / MRN", text: $renameText)
                Button("Save") {
                    if let target = renameTarget {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.renameSession(id: target.id, label: trimmed.isEmpty ? nil : trimmed)
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                if let target = renameTarget {
                    Text("Captured \(Self.dateFormatter.string(from: target.createdAt)). The date/time stays with the session.")
                }
            }
        }
    }

    private var renameIsPresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }
}

private struct SessionRow: View {
    let summary: SessionSummary
    let isCurrent: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Date/time is always shown and leads the row.
                Text(Self.dateFormatter.string(from: summary.createdAt))
                    .font(.subheadline.weight(.semibold))
                Text(summary.subjectLabel ?? "Unlabeled subject")
                    .font(.callout)
                    .foregroundStyle(summary.subjectLabel == nil ? .secondary : .primary)
                HStack(spacing: 10) {
                    Label("\(summary.observationCount)", systemImage: "camera")
                    Label("\(summary.detectedElectrodeCount)", systemImage: "dot.circle")
                    if summary.hasReconstructedModel {
                        Label("Model", systemImage: "cube.transparent")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isCurrent {
                Text("Current")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

#if canImport(UIKit)
/// Wraps `UIActivityViewController` so exported bundles can be shared
/// (AirDrop, Files, Mail, …).
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
private struct ShareSheet: View {
    let items: [Any]
    var body: some View { EmptyView() }
}
#endif
