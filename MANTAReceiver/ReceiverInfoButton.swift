import SwiftUI

/// A small "?" button that pops over a plain-language explanation of a
/// control. Used throughout the sidebar so someone new to the app can learn
/// what LiDAR/Fused Depth/photogrammetry/etc. actually mean without leaving
/// the screen.
struct ReceiverInfoButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            // A native tooltip (`.help`) was layered on top of this popover,
            // and macOS tooltips do not wrap long text the way this view does
            // - it was winning on hover, before the popover ever opened, and
            // that's what was showing as a clipped single line. The popover
            // itself needs the width fixed and wrapping forced explicitly:
            // .fixedSize(vertical: true) makes the view take whatever height
            // its content needs at that width instead of collapsing to one
            // line's worth of intrinsic size.
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

/// A row pairing a piece of content (a Toggle, a section title, ...) with an
/// info button, laid out consistently wherever it's used in the sidebar.
struct ReceiverInfoRow<Content: View>: View {
    let help: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            content()
            ReceiverInfoButton(text: help)
        }
    }
}

/// The explanations shown by the sidebar's info buttons, gathered in one place
/// so the wording stays consistent across every place a term is used.
enum ReceiverGlossary {
    static let lidar = """
        ARKit's own real-time scene mesh: a coarse triangle mesh of everything the LiDAR sensor saw \
        during capture (not just the head), built live on the iPad. Already in real-world meters, no \
        alignment needed. It is a fixed file from capture time - the head-crop version is regenerated \
        when you save an edited head bounding box, but the underlying full-environment mesh itself \
        cannot be changed here.
        """

    static let photogrammetry = """
        The detailed, textured 3D model built after capture from all the RGB photos (Apple Object \
        Capture). Much higher detail than LiDAR - you can see individual electrodes and the cap \
        pattern - but it starts out in its own arbitrary coordinate space and scale. Align computes and \
        saves the transform that places it into the same real-world frame as LiDAR/Fused Depth.
        """

    static let fusedDepth = """
        A dense point cloud this app builds itself, live, by combining the per-frame depth maps saved \
        alongside every photo (not a fixed file like LiDAR). Recomputes automatically whenever its \
        inputs change - including the head bounding box, once saved. This is the primary target the \
        Align solver matches the photogrammetry surface against.
        """

    static let annotations = """
        Placed or detected fiducials (Nasion/LPA/RPA/Cz) and EEG sensor positions, shown as colored \
        markers on the surface. Independent of which surfaces are visible - annotations are drawn in \
        real-world coordinates once a valid alignment exists.
        """

    static let reconstruct = """
        Runs Apple Object Capture on the saved photos to build (or rebuild) the photogrammetry model. \
        Independent of LiDAR and Fused Depth - reconstruction only touches the photogrammetry file, and \
        can be re-run to replace it in place.
        """

    static let headBoundingBox = """
        Defines what counts as "the head" when building Fused Depth and the LiDAR-crop fallback used \
        for alignment - not for electrode search, which depends only on camera poses and the \
        photogrammetry mesh. Widen it here if a real part of the head (e.g. an ear) is being clipped \
        out. Changes only take effect after "Save to Capture" - saving also regenerates the LiDAR head \
        crop from the full-environment mesh using the new box, so LiDAR will visibly grow along with it. \
        Fused Depth recomputes automatically on save since it's built live, not from a fixed file.
        """

    static let metadata = """
        Read-only details about this capture package: identity, capture settings, producer/device info, \
        and every file it contains. Informational only - nothing here is editable.
        """
}
