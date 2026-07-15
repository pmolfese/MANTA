import MANTACore
import simd
import SwiftUI

/// Shared, sidebar-driven display state for the 3D scene. Lifting these out of
/// `CombinedModelViewer` lets one "Display" section in the sidebar drive whichever
/// workspace (Viewer or Align) is on screen, instead of a per-view control bar.
@MainActor
final class ReceiverDisplaySettings: ObservableObject {
    @Published var showLiDAR = false
    @Published var showPhotogrammetry = false
    @Published var showFusedDepth = false
    @Published var showAnnotations = true
    @Published var lidarChoice: ReceiverLiDARChoice = .fullEnvironment
    @Published var lidarStyle: ReceiverLiDARStyle = .wireframe

    /// Capability snapshot published by the active scene so the sidebar controls
    /// can enable/disable the right toggles.
    @Published private(set) var defaultLiDARChoice: ReceiverLiDARChoice?
    @Published private(set) var lidarChoices: [ReceiverLiDARChoice] = []
    @Published private(set) var photogrammetryAvailable = false
    @Published private(set) var fusedDepthAvailable = false
    @Published private(set) var hasAnnotations = false
    @Published private(set) var annotationsSpatiallyValid = true
    @Published private(set) var canOverlay = false

    /// Bumped to ask the active viewer to reframe the camera.
    @Published var frameRequestToken = 0

    /// The head bounding box that gates what counts as "the head" when building
    /// Fused Depth and the LiDAR-crop alignment fallback. Editable here so a box
    /// that clips real surface (e.g. an ear) can be caught by eye and widened,
    /// rather than trusted blindly. Editing this only changes what future
    /// Fused Depth/alignment runs include - it never touches electrode search,
    /// which depends only on camera poses and the photogrammetry mesh.
    @Published var showHeadBoundingBox = false
    @Published var headBoundingBoxCenter = SIMD3<Float>(0, 0, 0)
    @Published var headBoundingBoxHalfExtent = SIMD3<Float>(0.15, 0.19, 0.15)
    @Published private(set) var headBoundingBoxSource: HeadBoundingBox?
    /// Set whenever a slider changes the box; cleared on load/reset/save. Exact
    /// equality against `headBoundingBoxSource` isn't used here since seeding
    /// from JSON doubles through Float sliders and back is lossy round-trip.
    @Published private(set) var headBoundingBoxIsModified = false

    private var configuredKey: String?
    private var configuredBoundsKey: String?

    /// Establishes the initial toggle state once per scene context (bundle + model
    /// + placement mode). Later capability refreshes must not clobber user choices.
    func configureDefaults(
        key: String,
        defaultLiDARChoice: ReceiverLiDARChoice?,
        photogrammetryAvailable: Bool,
        hasModelToWorld: Bool,
        isPlacement: Bool,
        annotationOnly: Bool
    ) {
        guard configuredKey != key else { return }
        configuredKey = key
        lidarChoice = defaultLiDARChoice ?? .fullEnvironment
        showLiDAR = !annotationOnly && !isPlacement && defaultLiDARChoice != nil
        showPhotogrammetry = !annotationOnly && photogrammetryAvailable
            && (isPlacement || defaultLiDARChoice == nil || hasModelToWorld)
        showFusedDepth = false
        showAnnotations = true
    }

    /// Seeds the editable box from the bundle's declared box once per bundle
    /// context, so switching captures resets the sliders instead of carrying
    /// over a previous bundle's edits. Falls back to a generic adult-head-sized
    /// box when nothing is declared yet.
    func configureBoundsDefaults(key: String, declared: HeadBoundingBox?) {
        guard configuredBoundsKey != key else { return }
        configuredBoundsKey = key
        headBoundingBoxSource = declared
        headBoundingBoxIsModified = false
        if let declared {
            headBoundingBoxCenter = SIMD3(
                Float(declared.center.x), Float(declared.center.y), Float(declared.center.z))
            headBoundingBoxHalfExtent = SIMD3(
                Float(declared.widthMeters / 2), Float(declared.heightMeters / 2),
                Float(declared.depthMeters / 2))
        } else {
            headBoundingBoxHalfExtent = SIMD3(0.15, 0.19, 0.15)
        }
    }

    func resetHeadBoundingBoxToDeclared() {
        guard let declared = headBoundingBoxSource else { return }
        headBoundingBoxCenter = SIMD3(
            Float(declared.center.x), Float(declared.center.y), Float(declared.center.z))
        headBoundingBoxHalfExtent = SIMD3(
            Float(declared.widthMeters / 2), Float(declared.heightMeters / 2),
            Float(declared.depthMeters / 2))
        headBoundingBoxIsModified = false
    }

    /// The box as currently edited, in the shape saved to `capture.json`.
    var editedHeadBoundingBox: HeadBoundingBox {
        HeadBoundingBox(
            center: Coordinate3D(
                x: Double(headBoundingBoxCenter.x), y: Double(headBoundingBoxCenter.y),
                z: Double(headBoundingBoxCenter.z)),
            widthMeters: Double(headBoundingBoxHalfExtent.x * 2),
            heightMeters: Double(headBoundingBoxHalfExtent.y * 2),
            depthMeters: Double(headBoundingBoxHalfExtent.z * 2))
    }

    func markHeadBoundingBoxSaved() {
        headBoundingBoxSource = editedHeadBoundingBox
        headBoundingBoxIsModified = false
    }

    /// Binding for one half-extent axis (in meters), marking the box modified.
    func headBoundingBoxHalfExtentBinding(_ axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { self.headBoundingBoxHalfExtent[keyPath: axis] },
            set: { newValue in
                self.headBoundingBoxHalfExtent[keyPath: axis] = max(0.02, newValue)
                self.headBoundingBoxIsModified = true
            })
    }

    func updateCapabilities(
        defaultLiDARChoice: ReceiverLiDARChoice?,
        lidarChoices: [ReceiverLiDARChoice],
        photogrammetryAvailable: Bool,
        fusedDepthAvailable: Bool,
        hasAnnotations: Bool,
        annotationsSpatiallyValid: Bool,
        canOverlay: Bool
    ) {
        self.defaultLiDARChoice = defaultLiDARChoice
        self.lidarChoices = lidarChoices
        self.photogrammetryAvailable = photogrammetryAvailable
        self.fusedDepthAvailable = fusedDepthAvailable
        self.hasAnnotations = hasAnnotations
        self.annotationsSpatiallyValid = annotationsSpatiallyValid
        self.canOverlay = canOverlay
    }

    /// LiDAR and photogrammetry are mutually exclusive until a model-to-world
    /// transform lets them share the metric frame (`canOverlay`).
    var lidarBinding: Binding<Bool> {
        Binding(get: { self.showLiDAR }, set: { on in
            self.showLiDAR = on
            if on, self.showPhotogrammetry, !self.canOverlay { self.showPhotogrammetry = false }
        })
    }

    var photogrammetryBinding: Binding<Bool> {
        Binding(get: { self.showPhotogrammetry }, set: { on in
            self.showPhotogrammetry = on
            if on, self.showLiDAR, !self.canOverlay { self.showLiDAR = false }
        })
    }

    func requestFrame() { frameRequestToken &+= 1 }

    func showSensorsOnly() {
        showLiDAR = false
        showPhotogrammetry = false
        showFusedDepth = false
        showAnnotations = true
        requestFrame()
    }
}

/// The display toggles, rendered in the sidebar. Controls whichever scene is
/// currently on screen through the shared `ReceiverDisplaySettings`.
struct ReceiverDisplayControls: View {
    @ObservedObject var display: ReceiverDisplaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReceiverInfoRow(help: ReceiverGlossary.lidar) {
                Toggle("LiDAR", isOn: display.lidarBinding)
                    .disabled(display.defaultLiDARChoice == nil)
            }

            if display.lidarChoices.count > 1 {
                Picker("LiDAR mesh", selection: $display.lidarChoice) {
                    ForEach(display.lidarChoices) { Text($0.rawValue).tag($0) }
                }
                .disabled(!display.showLiDAR)
            }
            Picker("LiDAR style", selection: $display.lidarStyle) {
                ForEach(ReceiverLiDARStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(!display.showLiDAR)

            ReceiverInfoRow(help: ReceiverGlossary.photogrammetry) {
                Toggle("Photogrammetry", isOn: display.photogrammetryBinding)
                    .disabled(!display.photogrammetryAvailable)
            }

            ReceiverInfoRow(help: ReceiverGlossary.fusedDepth) {
                Toggle("Fused Depth", isOn: $display.showFusedDepth)
                    .disabled(!display.fusedDepthAvailable)
            }

            ReceiverInfoRow(help: ReceiverGlossary.annotations) {
                Toggle("Annotations", isOn: $display.showAnnotations)
                    .disabled(!display.hasAnnotations || !display.annotationsSpatiallyValid)
            }

            HStack {
                if display.hasAnnotations {
                    Button("Sensors Only", systemImage: "dot.circle.and.hand.point.up.left.fill") {
                        display.showSensorsOnly()
                    }
                    .help("Hide reconstructed surfaces and frame only sensor annotations")
                }
                Spacer()
                Button("Frame All", systemImage: "viewfinder") { display.requestFrame() }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
    }
}

/// Sliders to expand/shrink the head bounding box shown in the 3D view as an
/// orange wireframe cube. This box only decides what counts as "the head" for
/// Fused Depth and the LiDAR-crop alignment fallback - it has no effect on
/// electrode search, which depends solely on camera poses and the
/// photogrammetry mesh. Widening it here fixes a box that's clipping real
/// surface (e.g. an ear) out of the alignment target.
struct ReceiverHeadBoundingBoxControls: View {
    @ObservedObject var store: ReceiverStore
    @ObservedObject var display: ReceiverDisplaySettings
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show cube", isOn: $display.showHeadBoundingBox)
                .toggleStyle(.switch)

            axisSlider("Width", axis: \.x)
            axisSlider("Height", axis: \.y)
            axisSlider("Depth", axis: \.z)

            HStack {
                Button("Reset", systemImage: "arrow.counterclockwise") {
                    display.resetHeadBoundingBoxToDeclared()
                }
                .disabled(!display.headBoundingBoxIsModified || display.headBoundingBoxSource == nil)
                Spacer()
                Button("Save to Capture", systemImage: "checkmark.circle") {
                    save()
                }
                .disabled(!display.headBoundingBoxIsModified || isSaving)
                if isSaving { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)

            if display.headBoundingBoxSource == nil {
                Text("No head bounding box is declared yet; showing a generic default. Save to record one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func axisSlider(_ label: String, axis: WritableKeyPath<SIMD3<Float>, Float>) -> some View {
        let binding = display.headBoundingBoxHalfExtentBinding(axis)
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\((binding.wrappedValue * 200).formatted(.number.precision(.fractionLength(0)))) cm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: 0.05...0.40)
        }
        .disabled(!display.showHeadBoundingBox)
    }

    private func save() {
        isSaving = true
        let box = display.editedHeadBoundingBox
        Task {
            let succeeded = await store.updateHeadBoundingBox(box)
            isSaving = false
            if succeeded { display.markHeadBoundingBoxSaved() }
        }
    }
}
