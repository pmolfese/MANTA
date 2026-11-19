import Foundation

/// Reads a working acquisition without modifying its original metadata or artifacts.
/// Both iPad reopening and Mac RAW recovery must use the same checkpoint rules.
public enum MANTAWorkingSessionLoader {
    public static func load(from directory: URL, fileManager: FileManager = .default) throws -> ScanSession {
        var session = try JSONDecoder().decode(
            ScanSession.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        let metadataObservationCount = session.captureObservations.count
        let checkpoints = directory.appendingPathComponent("acquisition/observations", isDirectory: true)
        if fileManager.fileExists(atPath: checkpoints.path) {
            // A missing directory is valid for legacy captures. An unreadable directory
            // or corrupt checkpoint is an error, not evidence of a complete acquisition.
            let files = try fileManager.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var known = Set(session.captureObservations.map(\.id))
            for file in files {
                let observation = try JSONDecoder().decode(CaptureObservation.self, from: Data(contentsOf: file))
                // Full metadata wins for observations already saved there.
                if known.insert(observation.id).inserted {
                    session.captureObservations.append(observation)
                }
            }
        }
        if metadataObservationCount != session.captureObservations.count {
            session.lastRawExportedBundleID = nil
            session.lastExportedBundleID = nil
        }
        let motionStop = directory.appendingPathComponent("acquisition/motion-stop.json")
        if session.acquisitionContext?.captureReview?.observationCount != session.captureObservations.count {
            session.acquisitionContext?.captureReview = nil
        }
        if fileManager.fileExists(atPath: motionStop.path) {
            if session.acquisitionContext?.captureReview?.motionFlagged == false {
                session.acquisitionContext?.captureReview = nil
            }
            let stoppedAt = try JSONDecoder().decode(Date.self, from: Data(contentsOf: motionStop))
            for index in session.captureObservations.indices where session.captureObservations[index].capturedAt <= stoppedAt {
                session.captureObservations[index].quality?.motionAssessment?.state = .suspected
            }
        }
        let stops = directory.appendingPathComponent("acquisition/motion-stops")
        if fileManager.fileExists(atPath: stops.path) {
            let files = try fileManager.contentsOfDirectory(at: stops, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                _ = try JSONDecoder().decode(Date.self, from: Data(contentsOf: file))
                for index in session.captureObservations.indices where session.captureObservations[index].quality?.motionAssessment?.segmentID == id {
                    session.captureObservations[index].quality?.motionAssessment?.state = .suspected
                }
                session.acquisitionContext?.captureReview = nil
            }
        }
        session.captureObservations.sort {
            if $0.capturedAt == $1.capturedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.capturedAt < $1.capturedAt
        }
        return session
    }
}
