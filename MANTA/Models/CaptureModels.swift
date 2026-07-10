//
//  CaptureModels.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation

struct ImageResolution: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
}

struct DepthSnapshotSummary: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
    var validPixelCount: Int
    var minimumDepth: Float
    var maximumDepth: Float
    var meanDepth: Float
}

struct RawDepthFormat: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
    var scalarType: String
    var byteOrder: String
    var units: String
    var layout: String
    var compression: String
}

struct ConfidenceMapSummary: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
    var lowConfidenceCount: Int
    var mediumConfidenceCount: Int
    var highConfidenceCount: Int
    var unknownConfidenceCount: Int
}

struct RawConfidenceFormat: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
    var scalarType: String
    var valueMapping: [String: String]
    var layout: String
    var compression: String
}

struct CaptureObservation: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var capturedAt: Date
    var cameraTransform: [Float]
    var cameraIntrinsics: [Float]
    var imageResolution: ImageResolution
    var hasSceneDepth: Bool
    var meshAnchorCount: Int
    var trackingSummary: String
    var cameraSnapshotFilename: String?
    var depthSnapshotFilename: String?
    var rawDepthFilename: String?
    var rawDepthFormat: RawDepthFormat?
    var rawConfidenceFilename: String?
    var rawConfidenceFormat: RawConfidenceFormat?
    var confidenceSummary: ConfidenceMapSummary?
    var depthSummary: DepthSnapshotSummary?
}

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
