import AppKit
import CoreImage
import ImageIO

struct ReceiverOrientedFrameImage {
    var image: NSImage
    var orientation: ReceiverStoredImageOrientation
    private static let renderingContext = CIContext(options: [.cacheIntermediates: false])

    static func load(
        from url: URL,
        orientation: ReceiverStoredImageOrientation
    ) -> ReceiverOrientedFrameImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let input = CIImage(cgImage: raw)
        let oriented = input.oriented(orientation.coreImageOrientation)
        guard let rendered = renderingContext.createCGImage(oriented, from: oriented.extent) else {
            return nil
        }
        return ReceiverOrientedFrameImage(
            image: NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)),
            orientation: orientation)
    }
}

enum ReceiverStoredImageOrientation: String, Sendable {
    case up
    case down
    case left
    case right

    init(_ manifestValue: String) {
        self = Self(rawValue: manifestValue.lowercased()) ?? .up
    }

    var coreImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }

    func displaySize(for rawSize: CGSize) -> CGSize {
        switch self {
        case .left, .right:
            CGSize(width: rawSize.height, height: rawSize.width)
        case .up, .down:
            rawSize
        }
    }

    func displayPoint(_ point: CGPoint, rawSize: CGSize) -> CGPoint {
        switch self {
        case .up:
            point
        case .down:
            CGPoint(x: rawSize.width - point.x, y: rawSize.height - point.y)
        case .left:
            CGPoint(x: point.y, y: rawSize.width - point.x)
        case .right:
            CGPoint(x: rawSize.height - point.y, y: point.x)
        }
    }

    func rawPoint(_ point: CGPoint, rawSize: CGSize) -> CGPoint {
        switch self {
        case .up:
            point
        case .down:
            CGPoint(x: rawSize.width - point.x, y: rawSize.height - point.y)
        case .left:
            CGPoint(x: rawSize.width - point.y, y: point.x)
        case .right:
            CGPoint(x: point.y, y: rawSize.height - point.x)
        }
    }
}
