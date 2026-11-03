import AppKit
import Foundation
import MANTACore
import SwiftUI
import UniformTypeIdentifiers

struct ReceiverComparisonView: View {
    let bundle: MANTAValidatedBundle?
    @State private var referenceData: Data?
    @State private var candidateData: Data?
    @State private var referenceName = "No reference selected"
    @State private var candidateName = "No candidate selected"
    @State private var referenceUnit = ""
    @State private var candidateUnit = ""
    @State private var run: GeoScanComparisonRun?
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Compare a MANTA coordinate export with the original GeoScan TXT. Select source units explicitly; do not use an empirically transformed SFP as the reference.")
                GroupBox("Inputs") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("Choose GeoScan TXT…") { choose(reference: true) }
                            Text(referenceName).lineLimit(1).help(referenceName)
                            Spacer()
                            unitPicker("Reference units", selection: $referenceUnit)
                        }
                        HStack {
                            Button("Choose Candidate TXT…") { choose(reference: false) }
                            Text(candidateName).lineLimit(1).help(candidateName)
                            Spacer()
                            unitPicker("Candidate units", selection: $candidateUnit)
                        }
                        if let bundle {
                            Button("Use Current Capture Coordinates") { useCapture(bundle) }
                            Text("Uses the current capture's world coordinates in centimeters. Observed image/depth or image/mesh points retain measured provenance. Inferred, manual, and older unverified points remain estimated.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }.disabled(busy)
                Text("FidNz/FidT9/FidT10 must be nasion/LPA/RPA landmarks. Alignment uses these three points only, with no scale fitting. Errors are in millimeters.")
                    .font(.callout)
                HStack {
                    Button("Compare", systemImage: "chart.xyaxis.line") { compare() }
                        .disabled(busy || referenceData == nil || candidateData == nil || referenceUnit.isEmpty || candidateUnit.isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Export JSON Report…", systemImage: "square.and.arrow.up") { save() }
                        .disabled(run == nil || busy)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
                if let run {
                    results(run.comparison)
                }
            }.padding()
        }
        .onChange(of: referenceUnit) { _, _ in invalidate() }
        .onChange(of: candidateUnit) { _, _ in invalidate() }
        .alert("Comparison Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "Unknown error") }
    }

    private func unitPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Select units…").tag("")
            Text("Meters").tag("m")
            Text("Centimeters").tag("cm")
            Text("Millimeters").tag("mm")
        }.frame(width: 240)
    }

    private func invalidate() { run = nil; message = nil }

    private func choose(reference: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            invalidate()
            if reference { referenceData = data; referenceName = url.lastPathComponent; referenceUnit = "" }
            else { candidateData = data; candidateName = url.lastPathComponent; candidateUnit = "" }
        } catch { self.error = error.localizedDescription }
    }

    private func useCapture(_ bundle: MANTAValidatedBundle) {
        do {
            let payload = try ReceiverCoordinateExporter.export(bundle, frame: .arkitWorld, format: .geoScanTXT)
            invalidate()
            candidateData = payload.data
            candidateName = "Current capture snapshot: \(bundle.manifest.bundleID.uuidString)"
            candidateUnit = "cm"
        } catch { self.error = error.localizedDescription }
    }

    private func compare() {
        let units: [String: DistanceUnit] = ["m": .meters, "cm": .centimeters, "mm": .millimeters]
        guard let referenceData, let candidateData, let ru = units[referenceUnit], let cu = units[candidateUnit] else { return }
        invalidate()
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GeoScanComparisonRun.make(reference: referenceData, referenceUnit: ru,
                                                   candidate: candidateData, candidateUnit: cu)
                }.value
                run = result
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func save() {
        guard let run else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "manta_geoscan_comparison.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try run.jsonData().write(to: url, options: .withoutOverwriting)
            message = "Saved \(url.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }

    private func results(_ report: GeoScanComparisonReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            summary("Mutually measured electrodes", report.measuredOnlyErrors)
            summary("All matched electrodes · exploratory", report.allMatchedErrors)
            summary("Fiducial residuals", report.fiducialErrors)
            ForEach(report.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
            Text("Missing from candidate: \(report.missingFromCandidate.isEmpty ? "None" : report.missingFromCandidate.joined(separator: ", "))")
            Text("Missing from reference: \(report.missingFromReference.isEmpty ? "None" : report.missingFromReference.joined(separator: ", "))")
            GroupBox("Per-point errors (mm)") {
                LazyVStack(spacing: 6) {
                    HStack { Text("Label"); Spacer(); Text("Reference / Candidate provenance"); Spacer(); Text("Error (mm)") }.bold()
                    ForEach(report.fiducials + report.electrodes, id: \.label) { row in
                        HStack {
                            Text(row.label).frame(width: 90, alignment: .leading)
                            Spacer()
                            Text("\(row.referenceEstimated ? "Estimated" : "Measured") / \(row.candidateEstimated ? "Estimated" : "Measured")")
                            Spacer()
                            Text(number(row.errorMM)).monospacedDigit().frame(width: 100, alignment: .trailing)
                        }
                    }
                }.padding(8)
            }
        }.textSelection(.enabled)
    }

    private func summary(_ title: String, _ value: CoordinateErrorSummary?) -> some View {
        GroupBox(title) {
            if let value {
                Text("n=\(value.count)   Mean \(number(value.meanMM))   Median \(number(value.medianMM))   RMS \(number(value.rmsMM))   P95 \(number(value.percentile95MM))   Max \(number(value.maximumMM)) mm")
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .leading).padding(6)
            } else {
                Text("Unavailable: no mutually measured points.").frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }

    private func number(_ value: Double) -> String { String(format: "%.3f", value) }
}
