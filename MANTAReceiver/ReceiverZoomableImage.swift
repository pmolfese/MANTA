import AppKit
import SwiftUI

/// Wraps 2D photo content so the mouse scroll wheel (and trackpad two-finger
/// scroll) zooms it, matching the convention the 3D viewer already uses for its
/// scroll-to-dolly camera control. Zoom is centered, not panned: the content is
/// simply grown and clipped, so click coordinates inside `content` stay correct
/// without any transform math, exactly as if its own `GeometryReader` were
/// handed a bigger frame.
struct ReceiverZoomableImageArea<Content: View>: View {
    @Binding var zoom: CGFloat
    var minimumZoom: CGFloat = 1
    var maximumZoom: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        ReceiverScrollZoomHost(onScroll: { deltaY, precise in
            // Trackpads report small, continuous deltas; a physical mouse wheel
            // reports larger, discrete ones. Scale each so both feel similar.
            let sensitivity: CGFloat = precise ? 0.01 : 0.08
            let factor = exp(deltaY * sensitivity)
            zoom = min(maximumZoom, max(minimumZoom, zoom * factor))
        }) {
            GeometryReader { geo in
                content()
                    .frame(width: geo.size.width * zoom, height: geo.size.height * zoom)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .clipped()
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        zoom = min(maximumZoom, max(minimumZoom, zoom * scale))
                    })
        }
    }
}

/// Zoom in/out/reset buttons for a `ReceiverZoomableImageArea`'s bound zoom
/// value, sized for a panel header or toolbar.
struct ReceiverZoomControls: View {
    @Binding var zoom: CGFloat
    var minimumZoom: CGFloat = 1
    var maximumZoom: CGFloat = 8

    var body: some View {
        HStack(spacing: 4) {
            Button {
                zoom = max(minimumZoom, zoom - 0.5)
            } label: { Image(systemName: "minus.magnifyingglass") }
            Button {
                zoom = min(maximumZoom, zoom + 0.5)
            } label: { Image(systemName: "plus.magnifyingglass") }
            Button {
                zoom = minimumZoom
            } label: { Image(systemName: "1.magnifyingglass") }
            .disabled(zoom == minimumZoom)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

/// Bridges raw AppKit scroll-wheel events into SwiftUI. The interactive photo
/// content is hosted as a real subview, so normal SwiftUI gestures (tap, drag,
/// double-tap) inside `content` keep working completely unchanged - only
/// `scrollWheel` events the content itself doesn't consume bubble up the
/// responder chain to this wrapper, where they drive `onScroll`.
private struct ReceiverScrollZoomHost<Content: View>: NSViewRepresentable {
    let onScroll: (_ deltaY: CGFloat, _ precise: Bool) -> Void
    let content: Content

    init(
        onScroll: @escaping (CGFloat, Bool) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onScroll = onScroll
        self.content = content()
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.onScroll = onScroll
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.hostingView = hosting
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.onScroll = onScroll
        view.hostingView?.rootView = content
    }

    final class HostView: NSView {
        var onScroll: ((CGFloat, Bool) -> Void)?
        var hostingView: NSHostingView<Content>?

        override func scrollWheel(with event: NSEvent) {
            let delta = event.scrollingDeltaY
            guard delta != 0 else {
                super.scrollWheel(with: event)
                return
            }
            onScroll?(delta, event.hasPreciseScrollingDeltas)
        }
    }
}
