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

struct CaptureObservation: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var capturedAt: Date
    var cameraTransform: [Float]
    var cameraIntrinsics: [Float]
    var imageResolution: ImageResolution
    var hasSceneDepth: Bool
    var meshAnchorCount: Int
    var trackingSummary: String
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
