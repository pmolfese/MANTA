import SwiftUI
import MANTACore

struct CaptureCoverageReviewView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @ObservedObject var scan: ARScanViewModel
    @State private var confirmFinalCheck = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !viewModel.session.layout.hasElectrodeNet {
                    Section("1 · Set the head region") {
                        LabeledContent("Region", value: viewModel.session.headBoundingBox == nil ? "Not set" : "Set")
                        Text("Start scanning, then tap the visible head. Include the crown, ears, and rear; keep shoulders and background outside the box. Adjust its size in Capture settings.")
                        Button("Set head region in camera") { viewModel.selectHeadRegionFromReview() }
                            .disabled(!scan.status.isRunning || scan.motionStopped)
                    }
                    Section("2 · Freeze a stable reference") {
                        LabeledContent("Reference", value: scan.hasMotionReference(for: viewModel.session.headBoundingBox) ? "Frozen for this region" : "Not armed for this region")
                        Text("Keep the head still and scan enough surface to establish a reference. Freeze it before collecting the full pass. A reference does not prove the head stayed still.")
                        Button("Freeze stable head reference") {
                            scan.freezeMotionReference(bounds: viewModel.session.headBoundingBox)
                        }
                        .disabled(!scan.status.isRunning || scan.motionStopped || viewModel.session.headBoundingBox == nil)
                        Text(scan.motionMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Keep the capture running") {
                    Text(scan.status.isRunning ? "Tracking remains active. Return to the camera to collect missing views." : "Tracking is paused or unavailable. Resume only if this session remains valid; after movement, start a separate pass.")
                    Text("Move the iPad around the participant. Keep the participant’s head still. Five views are a starting checklist, not proof of complete coverage.")
                    if !viewModel.isAutoSampling && scan.status.isRunning {
                        Button("Start continuous sampling") { viewModel.startAutoSampling() }
                    }
                    if scan.motionStopped { Text(scan.motionMessage).foregroundStyle(.red) }
                    if !viewModel.session.layout.hasElectrodeNet {
                        Text("Collect overlapping views around the head, including the crown and behind both ears. Move in small steps; revisit gaps. Fiducials are optional for this head-only trial.")
                    }
                }
                CaptureGeometryReviewSection(viewModel: viewModel)
                Section("Optional photo view tags") {
                    ForEach(CaptureGuidedView.allCases, id: \.self) { view in
                        Button {
                            viewModel.targetGuidedView(view)
                        } label: {
                            HStack {
                                Image(systemName: viewModel.savedGuidedViews.contains(view) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(view.title)
                                    Text(viewModel.session.layout.hasElectrodeNet ? view.guidance : view.headGuidance).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(viewModel.savedGuidedViews.contains(view) ? "Revisit" : "Aim here").font(.caption)
                            }
                        }
                        .disabled(!scan.status.isRunning || scan.motionStopped)
                    }
                    Text("A check means a tagged sharp photo was saved. It does not establish a complete surface or complete label coverage. General and automatic photos remain useful evidence without tags.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !scan.highResolutionStills {
                        Text("High-resolution stills are off. Save regular frames in this session, or enable the experimental still format before starting a new session. Camera formats cannot change mid-pass.")
                            .foregroundStyle(.orange)
                    }
                }
                if viewModel.session.layout.hasElectrodeNet {
                    Section("Label evidence — unverified") {
                        LabeledContent("Read", value: "\(viewModel.liveLabelCoverage.seenLabels.count)")
                        LabeledContent("Distinct-view support", value: "\(viewModel.liveLabelCoverage.supportedLabels.count)")
                        LabeledContent("Localized from depth", value: "\(viewModel.liveDirectElectrodeCount)")
                        Text("Live OCR checked \(viewModel.liveOCRReviewedFrameCount) frames. Skipped or unread images may still be useful offline. These counts do not certify completeness.")
                            .font(.caption)
                        if !viewModel.liveDetectionEnabled {
                            Button("Enable live label feedback") { viewModel.setLiveDetectionEnabled(true) }
                            Text("Feedback begins with new samples; earlier images are processed on the Mac.").font(.caption)
                        }
                        if viewModel.isLiveDetecting { ProgressView("Reading saved images…") }
                    }
                    labelSection("Not yet read", labels: viewModel.unreadLiveLabels)
                    labelSection("Ambiguous — inspect and recapture", labels: viewModel.liveLabelCoverage.ambiguousLabels.sorted())
                    labelSection("One view — collect another angle", labels: viewModel.singleViewLiveLabels)
                }
                Section("Inspect the saved head") {
                    Text("Save and inspect pauses capture after accepted writes finish. Orbit and zoom the model; inspect the crown, both sides, ears, and rear for holes, missing regions, or doubled surfaces. Surface availability is not an accuracy check.")
                    Button("Save and inspect head surface") {
                        Task { await viewModel.inspectSavedHeadSurface() }
                    }
                    .disabled(!viewModel.canInspectHeadSurface)
                    Text("If the head has remained still and tracking is valid, resume to collect gaps. After movement, preserve this pass and start a new session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Finish after collecting missing evidence") {
                    Text("The final integrity check stops sampling, drains saved frames and live OCR, and pauses tracking. It records remaining gaps; it does not certify coordinate accuracy or verify a transferred copy.")
                        .font(.caption)
                    Button("Final integrity / release check") { confirmFinalCheck = true }
                        .disabled(viewModel.isCheckingRelease || viewModel.isEndingSession || viewModel.needsSessionName)
                    if viewModel.isCheckingRelease { ProgressView("Finishing evidence and checking files…") }
                    ForEach(Array(viewModel.releaseCheckMessages.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption)
                    }
                }
            }
            .navigationTitle(viewModel.captureReviewTitle)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Back to camera") { dismiss() } } }
            .confirmationDialog("Pause capture and run the final check?", isPresented: $confirmFinalCheck, titleVisibility: .visible) {
                Button("Pause and check saved evidence") { Task { await viewModel.checkBeforeParticipantRelease() } }
                Button("Keep collecting", role: .cancel) {}
            } message: { Text("Collect missing views while tracking is active, then inspect the saved head surface.") }
        }
    }

    @ViewBuilder
    private func labelSection(_ title: String, labels: [String]) -> some View {
        Section {
            DisclosureGroup("\(title) (\(labels.count))") {
                if labels.isEmpty { Text("None in current live feedback.").font(.caption) }
                ForEach(labels, id: \.self) { label in
                    Button("Recapture \(label)") { viewModel.targetRecapture(label: label) }
                        .disabled(!scan.status.isRunning || scan.motionStopped)
                }
            }
        }
    }
}

/// Counts describe recorded evidence; the final receipt verifies files separately.
struct CaptureGeometryReviewSection: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    var body: some View {
        let review = viewModel.geometryReview
        Section("Geometry evidence — advisory") {
            LabeledContent("View coverage", value: viewModel.viewCoverageText)
            Text("Camera-position sectors around the selected head region, in the capture world's axes. These are not anatomical regions or a percentage of the surface captured. Missing head bounds mean coverage is unknown.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Frames with depth", value: "\(review.depthFrameCount)/\(review.observationCount)")
            LabeledContent("Depth frames with confidence", value: "\(review.confidenceFrameCount)/\(review.depthFrameCount)")
            Text("Counts reflect recorded files, not high-confidence head-surface coverage. RGB-only photos remain useful; final integrity checks verify decoding.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Head crop", value: review.headMeshRecorded ? "Recorded" : "Not saved")
            LabeledContent("Full environment mesh", value: review.environmentMeshRecorded ? "Recorded" : "Not saved")
            Text("A recorded mesh may still have holes. Save and inspect the head crop; a full environment mesh alone does not establish a usable head.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Frames with blur warnings", value: "\(review.blurWarningCount)")
            LabeledContent("Sharpness unknown", value: "\(review.unknownSharpnessCount)")
            LabeledContent("Motion consistent (advisory)", value: "\(review.motionConsistentCount)")
            LabeledContent("Motion unknown / insufficient", value: "\(review.motionUnknownCount)")
            LabeledContent("Motion suspect", value: "\(review.motionSuspectCount)")
            Text("No warning does not prove stability. Smooth head rotation can escape the depth check; mark movement and start a new pass when needed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Shared by portrait, landscape, and phone headers so a target selected from
/// review always has an immediately accessible photo action.
struct CaptureRecapturePrompt: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @ObservedObject var scan: ARScanViewModel
    var body: some View {
        if viewModel.selectedGuidedView != nil || viewModel.recaptureTargetLabel != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.recaptureGuidance).font(.caption)
                HStack {
                    if scan.highResolutionStills {
                        Button(viewModel.labelPhotoTitle) { Task { await viewModel.captureHighResolutionStill() } }
                            .disabled(!scan.status.isRunning || scan.isCapturingStill)
                    } else {
                        Button("Save regular frame") { viewModel.sampleCurrentARFrame() }
                            .disabled(!scan.status.isRunning)
                    }
                    Button("Clear target") {
                        viewModel.selectedGuidedView = nil
                        viewModel.recaptureTargetLabel = nil
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
