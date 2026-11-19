import Foundation

/// Source calibration is immutable; estimated calibration is explicitly in the
/// reconstruction frame, never silently substituted into ARKit world rays.
public struct ReconstructionCameraRecord: Codable, Sendable {
    public var sampleID: Int
    public var imageFilename: String
    public var observationID: UUID
    public var cameraToWorld: [Double]
    public var intrinsics: [Double]
    public var imageOrientation: String
    public var estimated: EstimatedCalibration?
    public var status: String
    public var statusDetail: String?

    public init(sampleID: Int, imageFilename: String, observationID: UUID,
                cameraToWorld: [Double], intrinsics: [Double], imageOrientation: String) {
        self.sampleID = sampleID; self.imageFilename = imageFilename; self.observationID = observationID
        self.cameraToWorld = cameraToWorld; self.intrinsics = intrinsics; self.imageOrientation = imageOrientation
        self.status = "pending"
    }
}

public struct EstimatedCalibration: Codable, Sendable {
    public var modelFromCamera: [Double]
    public var intrinsics: [Double]?
    public var distortionCenter: [Double]?
    public var radialLookupTable: [Double]?
    public var coordinateFrame: String = "object-capture-reconstruction"
    public var matrixOrder: String = "column-major"
    public var translationUnits: String = "reconstruction-native"
    public init(modelFromCamera: [Double], intrinsics: [Double]?, distortionCenter: [Double]?, radialLookupTable: [Double]?) {
        self.modelFromCamera = modelFromCamera; self.intrinsics = intrinsics
        self.distortionCenter = distortionCenter; self.radialLookupTable = radialLookupTable
    }
}
