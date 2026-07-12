import Foundation
import MANTACore

typealias ImageResolution = MANTACore.ImageResolution
typealias DepthSnapshotSummary = MANTACore.DepthSnapshotSummary
typealias RawDepthFormat = MANTACore.RawDepthFormat
typealias ConfidenceMapSummary = MANTACore.ConfidenceMapSummary
typealias RawConfidenceFormat = MANTACore.RawConfidenceFormat
typealias CaptureObservation = MANTACore.CaptureObservation

/// Transient AR/UI state intentionally remains in the iOS application target.
struct LiveScanStatus: Equatable {
    var isSupported = false
    var isRunning = false
    var trackingSummary = "Not started"
    var frameCount = 0
    var sampledFrameCount = 0
    var meshAnchorCount = 0
    var hasSceneDepth = false
    var lastSampledAt: Date?
    var message = "Start an AR scan on a LiDAR-capable iPhone or iPad Pro."
}
