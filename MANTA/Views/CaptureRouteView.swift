import SwiftUI
import MANTACore

/// Persistent operator guidance. Route completion is distinct from coverage,
/// geometric accuracy, and the final file receipt.
struct CaptureRouteMap: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @ObservedObject var scan: ARScanViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CaptureRouteStep.allCases, id: \.self) { step in
                if step != .setup {
                    Rectangle().fill(Color.secondary.opacity(0.25))
                        .frame(maxWidth: 32).frame(height: 2).padding(.bottom, 25)
                }
                station(step)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func station(_ step: CaptureRouteStep) -> some View {
        let selected = viewModel.captureRouteStep == step
        let completed = viewModel.captureRouteCompleted(step)
        let skipped = viewModel.session.captureRoute?.skippedSteps.contains(step) == true && !completed
        let color: Color = selected ? .blue : skipped ? .orange : completed ? .green : .secondary
        return Button {
            viewModel.selectCaptureRouteStep(step)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle().fill(color.opacity(selected || completed ? 1 : 0.12)).frame(width: 26, height: 26)
                    if completed {
                        Image(systemName: "checkmark").foregroundStyle(.white)
                    } else if skipped {
                        Image(systemName: "minus").foregroundStyle(selected ? .white : color)
                    } else {
                        Text("\(step.index + 1)").foregroundStyle(selected ? .white : color)
                    }
                }
                Text(step.title).font(.caption.weight(selected ? .bold : .medium)).foregroundStyle(color)
                Text(skipped ? "Skipped" : selected ? "Current" : completed ? "Reviewed" : " ")
                    .font(.system(size: 9)).foregroundStyle(skipped ? .orange : .secondary)
            }
            .frame(minWidth: 60, maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canNavigateCaptureRoute)
        .accessibilityIdentifier("captureRoute-\(step.rawValue)")
        .accessibilityLabel("\(step.title), \(skipped ? "skipped" : completed ? "reviewed" : selected ? "current" : "not reviewed")")
        .accessibilityHint("Select this step. Advancing does not complete skipped checks.")
    }
}

struct CaptureRouteGuidance: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @ObservedObject var scan: ARScanViewModel
    var showExperiment: () -> Void
    var inspectSurface: () -> Void

    private var step: CaptureRouteStep { viewModel.captureRouteStep }
    private var review: CaptureGeometryReview { viewModel.geometryReview }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if scan.continuousNetTrackingEnabled {
                Text(scan.netTrackingMessage).font(.caption).foregroundStyle(.secondary)
            }
            if scan.motionFusionHeld && !scan.motionStopped {
                Label(scan.motionMessage, systemImage: "viewfinder")
                    .font(.callout).foregroundStyle(.orange)
            }
            if scan.motionStopped {
                movementRecovery
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(step.title) · \(headline)").font(.headline)
                        Text(instruction).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(evidence).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("captureRouteEvidence")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 8) {
                        stepAction
                        if let next = step.next {
                            Button("Continue to \(next.title)", systemImage: "arrow.right") {
                                viewModel.advanceCaptureRoute()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!viewModel.canNavigateCaptureRoute)
                            .accessibilityIdentifier("captureRouteContinue")
                        }
                    }.frame(maxWidth: 250)
                }
                if step == .photos {
                    HStack {
                        Text("View tag").font(.caption)
                        ForEach(CaptureGuidedView.allCases, id: \.self) { view in
                            Button {
                                viewModel.targetGuidedView(view)
                            } label: {
                                Label(view.title, systemImage: viewModel.savedGuidedViews.contains(view) ? "checkmark.circle" : "circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(viewModel.selectedGuidedView == view ? .blue : .secondary)
                            .disabled(!scan.status.isRunning || viewModel.isSessionEnded)
                        }
                    }.font(.caption)
                }
            }
            HStack(spacing: 16) {
                Label(scan.status.isRunning ? "Tracking: \(scan.status.trackingSummary)" : "Tracking paused", systemImage: "location.viewfinder")
                Label("Depth: \(review.depthFrameCount) saved", systemImage: "square.3.layers.3d")
                Label(scan.hasMotionReference(for: viewModel.session.headBoundingBox) ? "Motion check armed · advisory" : "Motion check not armed", systemImage: "person.crop.rectangle")
                    .foregroundStyle(scan.hasMotionReference(for: viewModel.session.headBoundingBox) ? Color.secondary : .orange)
                Spacer(minLength: 0)
            }.font(.caption2).foregroundStyle(.secondary)
            if let error = viewModel.captureSaveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
    }

    private var headline: String {
        switch step {
        case .setup: "check the capture settings"
        case .reference: scan.hasMotionReference(for: viewModel.session.headBoundingBox) ? "reference frozen" : "establish a stationary head"
        case .orbit: "move the iPad, keep the head still"
        case .photos: "collect sharp close views"
        case .review: "inspect before finishing"
        case .finish: viewModel.isSessionEnded ? "pass saved and ended" : "validate and save this pass"
        }
    }
    private var instruction: String {
        switch step {
        case .setup: "Check Subject and Experiment. Choose head-only or net capture, lighting, and camera settings before starting."
        case .reference: "Start tracking, tap the head to set its region, and scan enough stationary surface. Freeze a reference before the full orbit."
        case .orbit: "Use overlapping views around the head, including behind both ears and the crown. Camera sectors are guidance, not surface completeness."
        case .photos: viewModel.session.layout.hasElectrodeNet
            ? "Tag a view, hold still, then use Hi-Res Photo. Include readable labels from different angles; tags alone do not establish coverage."
            : "Tag a view, hold still, then use Hi-Res Photo. Include front, left, right, back, and crown; revisit blurred or missing views."
        case .review: "Save and inspect pauses capture. Rotate the surface to check crown, ears, rear, holes, and doubled geometry. Resume only while the same head position remains valid."
        case .finish: viewModel.isSessionEnded
            ? "Inspect the file-check findings, then export when ready. Ending a pass does not certify accuracy or complete coverage."
            : "The final action drains pending writes, saves the surface, checks files, and ends acquisition. Skipped steps and remaining findings stay recorded."
        }
    }
    private var evidence: String {
        switch step {
        case .setup: return scan.activeSettingsSummary ?? scan.settingsSummary(captureMode: viewModel.session.captureMode)
        case .reference: return scan.motionMessage
        case .orbit: return "\(review.observationCount) frames · \(viewModel.viewCoverageText) view sectors · \(review.blurWarningCount) blur warnings · \(review.motionUnknownCount) motion-unassessed frames"
        case .photos: return "\(viewModel.highResolutionPhotoCount) hi-res photos saved · \(viewModel.savedGuidedViews.count)/5 view tags\(viewModel.session.layout.hasElectrodeNet ? " · \(viewModel.unreadLiveLabels.count) labels not yet read live" : "")"
        case .review: return viewModel.captureRouteRequirementMet(.review) ? "Inspection acknowledged for these saved frames." : "Saved head crop: \(review.headMeshRecorded ? "available" : "not yet saved") · \(review.blurWarningCount) blur warnings"
        case .finish:
            let skipped = viewModel.session.captureRoute?.skippedSteps.map(\.title).sorted().joined(separator: ", ") ?? ""
            return viewModel.releaseCheckMessages.first ?? (skipped.isEmpty ? "Final file validation runs when you finish." : "Skipped or unreviewed: \(skipped)")
        }
    }

    @ViewBuilder private var stepAction: some View {
        switch step {
        case .setup:
            Button("Open Experiment", action: showExperiment).buttonStyle(.borderedProminent)
        case .reference:
            if !scan.status.isRunning {
                Button("Start / resume tracking") { viewModel.startLiveScan() }
                    .buttonStyle(.borderedProminent).disabled(viewModel.isSessionEnded || !scan.status.isSupported)
            } else if viewModel.session.headBoundingBox == nil {
                Button("Set head region") { viewModel.selectHeadRegionFromReview() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Freeze head reference") { viewModel.freezeCaptureRouteReference() }
                    .buttonStyle(.borderedProminent)
            }
        case .orbit:
            Button(viewModel.isAutoSampling ? "Pause continuous sampling" : "Start continuous sampling") {
                if viewModel.isAutoSampling { viewModel.stopAutoSampling() } else { viewModel.startAutoSampling() }
            }.buttonStyle(.borderedProminent).disabled(viewModel.isSessionEnded || !scan.status.isSupported)
        case .photos:
            Button(viewModel.labelPhotoTitle) { Task { await viewModel.captureHighResolutionStill() } }
                .buttonStyle(.borderedProminent)
                .disabled(!scan.status.isRunning || !scan.highResolutionStills || scan.isCapturingStill || viewModel.isSessionEnded)
        case .review:
            Button("Save and inspect surface", action: inspectSurface)
                .buttonStyle(.borderedProminent).disabled(!viewModel.canInspectHeadSurface)
            Button("I've inspected this surface") { viewModel.acknowledgeCaptureSurfaceReview() }
                .disabled(scan.status.isRunning || !review.headMeshRecorded || viewModel.isSessionEnded)
        case .finish:
            if !viewModel.isSessionEnded {
                Button("Validate, save & end") { Task { await viewModel.endSession() } }
                    .buttonStyle(.borderedProminent).disabled(!viewModel.canEndSession)
                    .accessibilityIdentifier("captureRouteFinish")
            } else {
                Button("Review file findings") { viewModel.reviewCaptureCoverage() }.buttonStyle(.bordered)
            }
        }
    }

    private var movementRecovery: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Movement flagged · this pass is paused", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("Ask the participant to settle. Continue with a new pass and freeze a new reference. All passes stay in one saved session. Receiver can reconstruct the images together with foreground masking; depth remains separated by pass.")
                    .font(.callout)
                Text(scan.motionMessage).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Continue in this session") { Task { await viewModel.startNewStationaryPass() } }
                .buttonStyle(.borderedProminent).disabled(!viewModel.canNavigateCaptureRoute)
                .accessibilityIdentifier("captureRouteNewPass")
        }
    }
}
