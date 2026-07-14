//
//  PhotogrammetryReconstructionService.swift
//  MANTA
//
//  Offline photogrammetry reconstruction of the captured RGB frame set.
//
//  Capture happens inside a single ARKit session, so every image is tagged with
//  its ARKit camera pose (see ReconstructionManifest). That lets a downstream
//  fusion step express the reconstructed model in the same ARKit world frame as
//  the LiDAR mesh, which is what makes "Both" mode line up.
//

import Foundation
import simd

enum ReconstructionError: LocalizedError {
    case unsupportedDevice
    case noInputImages
    case sessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return "This device does not support on-device photogrammetry (Object Capture)."
        case .noInputImages:
            return "No captured camera frames were available to reconstruct."
        case .sessionFailed(let message):
            return "Photogrammetry failed: \(message)"
        }
    }
}

/// Result of a reconstruction run. World alignment is computed separately by
/// `WorldAlignmentSolver` from the captured poses/geometry.
struct ReconstructionResult {
    /// Location of the produced model file (USDZ).
    var modelURL: URL
    var diagnostics: ReconstructionDiagnostics
}

struct ReconstructionDiagnostics: Codable, Equatable {
    var inputImageCount: Int
    var sampleOrdering: String
    var featureSensitivity: String
    var requestedDetail: String
    var skippedSampleIDs: [String]
    var automaticDownsampling: Bool
    var producer: [String: String]? = nil
    var parameters: [String: String]? = nil
}

/// One captured frame's pose in the ARKit world, persisted next to the input images.
struct ReconstructionPose: Codable, Equatable {
    var imageFilename: String
    /// Column-major 4x4 ARKit camera transform.
    var cameraTransform: [Float]
}

struct ReconstructionManifest: Codable, Equatable {
    var poses: [ReconstructionPose]
}

protocol PhotogrammetryReconstructing {
    var isSupported: Bool { get }

    /// Reconstruct a model from the images in `imagesDirectory`, writing to `outputModelURL`.
    /// `manifest` carries the ARKit camera poses used to align the result to the world frame.
    func reconstruct(
        imagesDirectory: URL,
        outputModelURL: URL,
        manifest: ReconstructionManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ReconstructionResult
}

#if canImport(RealityKit)
import RealityKit

/// Real on-device reconstruction backed by RealityKit's `PhotogrammetrySession`.
struct PhotogrammetryReconstructionService: PhotogrammetryReconstructing {
    var isSupported: Bool {
        if #available(iOS 17.0, macOS 12.0, *) {
            return PhotogrammetrySession.isSupported
        }
        return false
    }

    func reconstruct(
        imagesDirectory: URL,
        outputModelURL: URL,
        manifest: ReconstructionManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ReconstructionResult {
        guard #available(iOS 17.0, macOS 12.0, *), PhotogrammetrySession.isSupported else {
            throw ReconstructionError.unsupportedDevice
        }

        let images = try imageFiles(in: imagesDirectory)
        guard !images.isEmpty else { throw ReconstructionError.noInputImages }

        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .high

        let session = try PhotogrammetrySession(input: imagesDirectory, configuration: configuration)
        let request = PhotogrammetrySession.Request.modelFile(url: outputModelURL, detail: .reduced)
        var skippedSampleIDs = [String]()
        var automaticDownsampling = false

        try session.process(requests: [request])

        for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                progress(fraction)
            case .processingComplete:
                return ReconstructionResult(
                    modelURL: outputModelURL,
                    diagnostics: ReconstructionDiagnostics(
                        inputImageCount: images.count,
                        sampleOrdering: "sequential",
                        featureSensitivity: "high",
                        requestedDetail: "reduced",
                        skippedSampleIDs: skippedSampleIDs,
                        automaticDownsampling: automaticDownsampling))
            case .skippedSample(let id):
                skippedSampleIDs.append(String(describing: id))
            case .automaticDownsampling:
                automaticDownsampling = true
            case .requestError(_, let error):
                throw ReconstructionError.sessionFailed(error.localizedDescription)
            case .processingCancelled:
                throw ReconstructionError.sessionFailed("Processing was cancelled.")
            default:
                continue
            }
        }

        throw ReconstructionError.sessionFailed("Session ended without producing a model.")
    }

    private func imageFiles(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents.filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
    }
}
#else
/// Fallback for platforms/build configurations without RealityKit.
struct PhotogrammetryReconstructionService: PhotogrammetryReconstructing {
    var isSupported: Bool { false }

    func reconstruct(
        imagesDirectory: URL,
        outputModelURL: URL,
        manifest: ReconstructionManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ReconstructionResult {
        throw ReconstructionError.unsupportedDevice
    }
}
#endif
