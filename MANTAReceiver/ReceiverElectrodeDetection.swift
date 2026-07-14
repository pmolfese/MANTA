import Compression
import CoreGraphics
import Foundation
import ImageIO
import MANTACore
import Vision
import simd

nonisolated struct ReceiverElectrodeEvidenceDocument: Codable, Sendable {
    var format = "org.nih.manta.electrode-evidence"
    var version = 2
    var sessionID: UUID
    var sourceBundleID: UUID
    var generatedAt: Date
    var modelPath: String?
    var modelToWorld: [Double]?
    var observations: [ReceiverElectrodeObservationEvidence]
    var summaries: [ReceiverElectrodeSummary]
    var manualEdits: [ReceiverElectrodeManualEdit]?
}

nonisolated struct ReceiverElectrodeManualEdit: Codable, Identifiable, Sendable {
    var id: UUID
    var editedAt: Date
    var label: String
    var source: String
    var coordinate: [Double]
    var observationID: UUID?
    var rawImagePoint: [Double]?
}

nonisolated struct ReceiverElectrodeObservationEvidence: Codable, Identifiable, Sendable {
    var id: UUID
    var observationID: UUID
    var label: String
    var recognizedText: String
    var rawImagePoint: [Double]
    var ocrRawImagePoint: [Double]
    var imagePointSource: String
    var labelSource: String
    var rawBoundingBox: [Double]
    var ocrConfidence: Double
    var depthConfidence: Int
    var depthMeters: Double
    var depthPoint: [Double]
    var rayOrigin: [Double]
    var rayDirection: [Double]
}

nonisolated struct ReceiverElectrodeSummary: Codable, Identifiable, Sendable {
    var label: String
    var coordinate: [Double]
    var supportCount: Int
    var spreadMeters: Double
    var confidence: Double
    var state: String
    var rayResidualMeters: Double?
    var surfaceDistanceMeters: Double?
    var geometryWarning: String? = nil
    var id: String { label }
}

nonisolated struct ReceiverElectrodeDetectionResult: Sendable {
    var electrodes: [MANTAElectrodeSolution]
    var evidence: ReceiverElectrodeEvidenceDocument
}

nonisolated enum ReceiverElectrodeDetectionError: LocalizedError {
    case noCalibratedFrames
    case noRecognizedElectrodes

    var errorDescription: String? {
        switch self {
        case .noCalibratedFrames:
            "No saved images have both valid camera calibration and metric depth."
        case .noRecognizedElectrodes:
            "OCR did not find any valid electrode numbers with reliable metric depth."
        }
    }
}

nonisolated enum ReceiverElectrodeDetector {
    typealias Progress = @Sendable (Double, String) -> Void

    static func detect(
        bundle: MANTAValidatedBundle,
        modelMesh: ReceiverTriangleMesh?,
        progress: Progress? = nil
    ) throws -> ReceiverElectrodeDetectionResult {
        let frames = bundle.capture.observations.filter {
            imagePath(for: $0) != nil && $0.depth != nil
                && $0.intrinsics.count == 9 && $0.cameraToWorld.count == 16
        }
        guard !frames.isEmpty else { throw ReceiverElectrodeDetectionError.noCalibratedFrames }

        let validNumbers = validElectrodeNumbers(layoutID: bundle.capture.layoutID)
        let layout = loadLayout(bundle: bundle, validNumbers: validNumbers)
        let worldGuide = layout.flatMap {
            ReceiverLayoutWorldGuide.make(layout: $0, bundle: bundle)
        }
        let surface = modelMesh.map(ReceiverSurfaceVertexIndex.init)
        var evidence = [ReceiverElectrodeObservationEvidence]()

        for (index, observation) in frames.enumerated() {
            try Task.checkCancellation()
            progress?(
                Double(index) / Double(frames.count),
                "Reading frame \(index + 1) of \(frames.count)")
            guard let path = imagePath(for: observation),
                  let image = loadImage(bundle.rootDirectory.appendingPathComponent(path)),
                  let camera = PinholeCamera(
                    intrinsics: observation.intrinsics.map(Float.init),
                    transform: observation.cameraToWorld.map(Float.init)),
                  let depth = ReceiverElectrodeDepthFrame(
                    observation: observation, rootDirectory: bundle.rootDirectory)
            else { continue }

            let recognized = try recognize(
                image: image, observation: observation, validNumbers: validNumbers)
            let origin = camera.cameraToWorld.columns.3.xyz
            var bestByLabel = [String: ReceiverResolvedOCRHit]()
            for hit in recognized {
                guard let sample = depth.sample(rawImagePoint: hit.rawPoint) else { continue }
                let world = camera.unproject(pixel: hit.rawPoint, depth: sample.depth)
                let direction = simd_normalize(camera.unproject(pixel: hit.rawPoint, depth: 1) - origin)
                guard world.allFinite, direction.allFinite else { continue }
                let choice = worldGuide?.resolve(candidates: hit.candidates, at: world)
                    ?? ReceiverResolvedLabel(candidate: hit.candidates[0], source: "vision-ocr")
                let resolved = ReceiverResolvedOCRHit(
                    hit: hit, choice: choice, sample: sample,
                    world: world, origin: origin, direction: direction)
                if resolved.choice.candidate.confidence
                    > (bestByLabel[choice.candidate.label]?.choice.candidate.confidence ?? -1) {
                    bestByLabel[choice.candidate.label] = resolved
                }
            }
            for resolved in bestByLabel.values {
                let hit = resolved.hit
                evidence.append(ReceiverElectrodeObservationEvidence(
                    id: UUID(), observationID: observation.id,
                    label: resolved.choice.candidate.label,
                    recognizedText: hit.text,
                    rawImagePoint: hit.rawPoint.doubles,
                    ocrRawImagePoint: hit.rawTextPoint.doubles,
                    imagePointSource: hit.didLocateDisc
                        ? "nearest-silver-disc" : "ocr-text-center-fallback",
                    labelSource: resolved.choice.source,
                    rawBoundingBox: hit.rawBoundingBox,
                    ocrConfidence: Double(resolved.choice.candidate.confidence),
                    depthConfidence: Int(resolved.sample.confidence),
                    depthMeters: Double(resolved.sample.depth),
                    depthPoint: resolved.world.doubles, rayOrigin: resolved.origin.doubles,
                    rayDirection: resolved.direction.doubles))
            }
        }

        guard !evidence.isEmpty else {
            throw ReceiverElectrodeDetectionError.noRecognizedElectrodes
        }
        progress?(0.93, "Fusing repeated sensor sightings")
        let summaries = solve(
            evidence: evidence, surface: surface, layout: layout, worldGuide: worldGuide)
        let roles = cardinalLabels(layoutID: bundle.capture.layoutID)
        let electrodes = summaries.map { summary in
            MANTAElectrodeSolution(
                label: summary.label,
                role: roles.contains(summary.label) ? "Cardinal" : "Regular",
                coordinateSystem: "arkit-world", coordinate: summary.coordinate,
                confidence: summary.confidence, state: summary.state)
        }
        let reconstruction = bundle.capture.reconstruction
        let document = ReceiverElectrodeEvidenceDocument(
            sessionID: bundle.manifest.sessionID,
            sourceBundleID: bundle.manifest.bundleID,
            generatedAt: Date(),
            modelPath: reconstruction?.objectCaptureModelPath,
            modelToWorld: reconstruction?.modelToWorld,
            observations: evidence.sorted(by: evidenceOrder),
            summaries: summaries,
            manualEdits: nil)
        progress?(0.97, "Estimating unobserved sensors")
        let initial = ReceiverElectrodeDetectionResult(
            electrodes: electrodes, evidence: document)
        let result = ReceiverElectrodeGuessSolver.recalculate(
            bundle: bundle, electrodes: initial.electrodes,
            evidence: initial.evidence, modelMesh: modelMesh)
        progress?(1, "Electrode candidates and guesses ready for review")
        return result
    }

    private static func solve(
        evidence: [ReceiverElectrodeObservationEvidence],
        surface: ReceiverSurfaceVertexIndex?,
        layout: ElectrodeLayout?,
        worldGuide: ReceiverLayoutWorldGuide?
    ) -> [ReceiverElectrodeSummary] {
        let detections = evidence.compactMap { item -> LabeledDetection? in
            guard let point = SIMD3<Float>(doubles: item.depthPoint) else { return nil }
            let depthQuality = item.depthConfidence >= 2 ? 1.0 : 0.82
            return LabeledDetection(
                label: item.label, world: point,
                quality: Float(item.ocrConfidence * depthQuality))
        }
        let aggregated = ElectrodeObservationAggregator.aggregate(
            detections, outlierThreshold: 0.012, saturationCount: 4)

        var summaries = aggregated.compactMap { aggregate in
            let candidates = evidence.filter {
                $0.label == aggregate.label
                    && SIMD3<Float>(doubles: $0.depthPoint).map {
                        simd_distance($0, aggregate.position) <= 0.012
                    } == true
            }
            let rays = candidates.compactMap(ReceiverRayEvidence.init)
            let rayFit = ReceiverRayTriangulator.fit(rays)
            let rayResidual = rayFit.map { simd_distance($0.point, aggregate.position) }

            var coordinate = aggregate.position
            var surfaceDistance: Float?
            if let nearest = surface?.nearest(to: aggregate.position, maximumDistance: 0.03) {
                surfaceDistance = nearest.distance
                // A close photogrammetry surface removes depth noise. Larger gaps
                // remain diagnostic rather than silently moving an electrode.
                if nearest.distance <= 0.012 { coordinate = nearest.point }
            }

            let supportFactor = min(1, Float(aggregate.observationCount) / 3)
            let spreadFactor = max(0, 1 - aggregate.spread / 0.012)
            let rayFactor = rayResidual.map { max(0.25, 1 - $0 / 0.02) } ?? 0.72
            let surfaceFactor = surfaceDistance.map { max(0.35, 1 - $0 / 0.03) } ?? 0.8
            let confidence = min(
                1, aggregate.confidence * (0.45 + 0.55 * supportFactor)
                    * (0.55 + 0.45 * spreadFactor) * rayFactor * surfaceFactor)
            let reviewedAutomatically = aggregate.observationCount >= 2
                && aggregate.spread <= 0.008
                && (rayResidual ?? 0) <= 0.012
                && (surfaceDistance ?? 0) <= 0.015
                && confidence >= 0.60
            return ReceiverElectrodeSummary(
                label: aggregate.label, coordinate: coordinate.doubles,
                supportCount: aggregate.observationCount,
                spreadMeters: Double(aggregate.spread), confidence: Double(confidence),
                state: reviewedAutomatically ? "Detected" : "Needs Review",
                rayResidualMeters: rayResidual.map(Double.init),
                surfaceDistanceMeters: surfaceDistance.map(Double.init))
        }.sorted { electrodeNumber($0.label) < electrodeNumber($1.label) }
        for first in summaries.indices {
            guard let firstPoint = SIMD3<Float>(doubles: summaries[first].coordinate) else { continue }
            for second in summaries.indices where second > first {
                guard let secondPoint = SIMD3<Float>(doubles: summaries[second].coordinate),
                      simd_distance(firstPoint, secondPoint) < 0.009 else { continue }
                let warning = "Conflicts with \(summaries[second].label) within 9 mm"
                let reverseWarning = "Conflicts with \(summaries[first].label) within 9 mm"
                summaries[first].state = "Needs Review"
                summaries[second].state = "Needs Review"
                summaries[first].confidence *= 0.5
                summaries[second].confidence *= 0.5
                summaries[first].geometryWarning = warning
                summaries[second].geometryWarning = reverseWarning
            }
        }
        if let layout {
            let positions = Dictionary(uniqueKeysWithValues: summaries.compactMap { summary in
                SIMD3<Float>(doubles: summary.coordinate).map { (summary.label, $0) }
            })
            let suspects = ElectrodeNeighborValidator.validate(
                positions: positions, layout: layout,
                toleranceMeters: 0.012, minNeighbors: 2).suspectLabels
            for index in summaries.indices where suspects.contains(summaries[index].label) {
                summaries[index].state = "Needs Review"
                summaries[index].confidence *= 0.7
                if summaries[index].geometryWarning == nil {
                    summaries[index].geometryWarning = "Inconsistent with expected HydroCel neighbors"
                }
            }
            summaries = appendLayoutInferences(
                to: summaries, layout: layout, surface: surface, worldGuide: worldGuide)
        }
        return summaries.sorted { electrodeNumber($0.label) < electrodeNumber($1.label) }
    }

    private static func appendLayoutInferences(
        to summaries: [ReceiverElectrodeSummary],
        layout: ElectrodeLayout,
        surface: ReceiverSurfaceVertexIndex?,
        worldGuide: ReceiverLayoutWorldGuide?
    ) -> [ReceiverElectrodeSummary] {
        let definitions = Dictionary(uniqueKeysWithValues: layout.electrodes.map { ($0.label, $0) })
        let anchors = summaries.reduce(into: [String: SIMD3<Float>]()) { result, summary in
            guard summary.supportCount > 0, summary.geometryWarning == nil,
                  summary.confidence >= 0.18,
                  let point = SIMD3<Float>(doubles: summary.coordinate) else { return }
            result[summary.label] = point
        }
        let fitted = ElectrodeCapOrientation.estimateRobust(detected: anchors, layout: layout)
        guard let transform = fitted?.isReliable == true
            ? fitted?.transform : worldGuide?.transform else { return summaries }
        let usedFiducialSeed = fitted?.isReliable != true

        let existing = Set(summaries.map(\.label))
        let priorByLabel = definitions.mapValues {
            SIMD3(Float($0.coordinatePrior.x), Float($0.coordinatePrior.y),
                  Float($0.coordinatePrior.z))
        }
        let residuals = anchors.reduce(into: [String: SIMD3<Float>]()) { result, item in
            guard let prior = priorByLabel[item.key] else { return }
            let predicted = (transform * SIMD4(prior, 1)).xyz
            result[item.key] = item.value - predicted
        }

        var output = summaries
        for definition in layout.electrodes where !existing.contains(definition.label) {
            guard let prior = priorByLabel[definition.label] else { continue }
            var predicted = (transform * SIMD4(prior, 1)).xyz
            let neighborResiduals = definition.neighbors.compactMap { number -> SIMD3<Float>? in
                residuals["E\(number)"]
            }
            if !neighborResiduals.isEmpty {
                predicted += neighborResiduals.reduce(.zero, +) / Float(neighborResiduals.count)
            }
            guard let nearest = surface?.nearest(to: predicted, maximumDistance: 0.035) else {
                continue
            }
            let neighborText = neighborResiduals.isEmpty
                ? (usedFiducialSeed ? "Nasion/LPA/RPA seed" : "global cap fit")
                : "\(neighborResiduals.count) observed neighbor\(neighborResiduals.count == 1 ? "" : "s")"
            output.append(ReceiverElectrodeSummary(
                label: definition.label, coordinate: nearest.point.doubles,
                supportCount: 0, spreadMeters: 0,
                confidence: neighborResiduals.count >= 2 ? 0.28 : 0.20,
                state: "Needs Review", rayResidualMeters: nil,
                surfaceDistanceMeters: Double(nearest.distance),
                geometryWarning: "Inferred from \(layout.channelCount)-sensor layout (\(neighborText))"))
        }
        return output
    }

    private static func recognize(
        image: CGImage,
        observation: MANTACaptureObservation,
        validNumbers: Set<Int>
    ) throws -> [ReceiverOCRHit] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        request.customWords = validNumbers.flatMap { [String($0), "E\($0)"] }
        let orientation = ReceiverStoredImageOrientation(observation.imageOrientation)
        let handler = VNImageRequestHandler(
            cgImage: image, orientation: orientation.coreImageOrientation, options: [:])
        try handler.perform([request])

        let rawSize = CGSize(
            width: observation.imageDimensions.width,
            height: observation.imageDimensions.height)
        let displaySize = orientation.displaySize(for: rawSize)
        let discLocator = ReceiverElectrodeDiscLocator(image: image)
        return (request.results ?? []).compactMap { item in
            var byNumber = [Int: ReceiverOCRCandidate]()
            for candidate in item.topCandidates(5) {
                guard let number = parseLabel(candidate.string, validNumbers: validNumbers) else {
                    continue
                }
                let parsed = ReceiverOCRCandidate(
                    label: "E\(number)", text: candidate.string,
                    confidence: candidate.confidence)
                if parsed.confidence > (byNumber[number]?.confidence ?? -1) {
                    byNumber[number] = parsed
                }
            }
            let candidates = byNumber.values.sorted { $0.confidence > $1.confidence }
            guard let first = candidates.first else { return nil }
            let box = item.boundingBox
            let textDisplayPoint = CGPoint(
                x: box.midX * displaySize.width,
                y: (1 - box.midY) * displaySize.height)
            let displayBox = CGRect(
                x: box.minX * displaySize.width,
                y: (1 - box.maxY) * displaySize.height,
                width: box.width * displaySize.width,
                height: box.height * displaySize.height)
            let discDisplayPoint = discLocator?.locateDisc(
                nearest: textDisplayPoint, textBox: displayBox,
                orientation: orientation, rawSize: rawSize)
            let rawTextPoint = orientation.rawPoint(textDisplayPoint, rawSize: rawSize)
            let rawPoint = orientation.rawPoint(
                discDisplayPoint ?? textDisplayPoint, rawSize: rawSize)
            guard rawPoint.x >= 0, rawPoint.y >= 0,
                  rawPoint.x < rawSize.width, rawPoint.y < rawSize.height else { return nil }
            let displayCorners = [
                CGPoint(x: box.minX * displaySize.width, y: (1 - box.maxY) * displaySize.height),
                CGPoint(x: box.maxX * displaySize.width, y: (1 - box.minY) * displaySize.height)
            ]
            let rawCorners = displayCorners.map { orientation.rawPoint($0, rawSize: rawSize) }
            return ReceiverOCRHit(
                text: first.text, candidates: candidates,
                rawPoint: SIMD2(Float(rawPoint.x), Float(rawPoint.y)),
                rawTextPoint: SIMD2(Float(rawTextPoint.x), Float(rawTextPoint.y)),
                didLocateDisc: discDisplayPoint != nil,
                rawBoundingBox: [
                    Double(min(rawCorners[0].x, rawCorners[1].x)),
                    Double(min(rawCorners[0].y, rawCorners[1].y)),
                    Double(abs(rawCorners[1].x - rawCorners[0].x)),
                    Double(abs(rawCorners[1].y - rawCorners[0].y))
                ])
        }
    }

    private static func parseLabel(_ text: String, validNumbers: Set<Int>) -> Int? {
        if let exact = ElectrodeLabelParser.parse(text, validNumbers: validNumbers) {
            return exact
        }
        let compact = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard compact.first == "E", let number = Int(compact.dropFirst()),
              validNumbers.contains(number) else { return nil }
        return number
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // OCR only needs normalized image coordinates. Bounding the decode keeps
        // Vision from allocating a full-resolution 4K working pixel buffer for
        // every frame; points are still mapped through the manifest's raw size.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static func imagePath(for observation: MANTACaptureObservation) -> String? {
        observation.losslessImagePath ?? observation.imagePath ?? observation.compressedImagePath
    }

    fileprivate static func validElectrodeNumbers(layoutID: String) -> Set<Int> {
        let count = layoutID.localizedCaseInsensitiveContains("256") ? 256 : 128
        return Set(1...count)
    }

    private static func cardinalLabels(layoutID: String) -> Set<String> {
        let numbers = layoutID.localizedCaseInsensitiveContains("256")
            ? [31, 67, 36, 224, 219, 72, 173, 114, 119, 168, 234, 237, 216, 199, 165, 145, 111, 91, 247, 244]
            : [17, 43, 24, 124, 120, 47, 98, 72, 68, 94]
        return Set(numbers.map { "E\($0)" })
    }

    fileprivate static func loadLayout(
        bundle: MANTAValidatedBundle, validNumbers: Set<Int>
    ) -> ElectrodeLayout? {
        guard let path = bundle.manifest.content.layout,
              let data = try? Data(contentsOf: bundle.rootDirectory.appendingPathComponent(path))
        else { return nil }
        if path.lowercased().hasSuffix(".json"),
           let layout = try? JSONDecoder().decode(ElectrodeLayout.self, from: data) {
            return layout
        }
        let delegate = ReceiverElectrodeCoordinateParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.failed == false else { return nil }
        let coordinates = delegate.coordinates.filter { validNumbers.contains($0.key) }
        guard coordinates.count >= validNumbers.count / 2 else { return nil }
        let roles = cardinalLabels(layoutID: bundle.capture.layoutID)
        let definitions = validNumbers.sorted().compactMap { number -> ElectrodeDefinition? in
            guard let coordinate = coordinates[number] else { return nil }
            let nearest = coordinates.filter { $0.key != number }.sorted {
                distanceSquared($0.value, coordinate) < distanceSquared($1.value, coordinate)
            }.prefix(6).map(\.key)
            let label = "E\(number)"
            return ElectrodeDefinition(
                number: number, label: label,
                role: roles.contains(label) ? .cardinal : .regular,
                coordinatePrior: coordinate, displayPosition: nil,
                neighbors: nearest)
        }
        return ElectrodeLayout(
            id: bundle.capture.layoutID, name: bundle.capture.layoutID,
            channelCount: validNumbers.count,
            labels: definitions.map(\.label), cardinalLabels: roles,
            electrodes: definitions, fiducialCoordinatePriors: [:],
            fiducialSensorHints: [:], referenceSensor: nil, referenceLabel: nil)
    }

    private static func distanceSquared(_ lhs: Coordinate3D, _ rhs: Coordinate3D) -> Double {
        let x = lhs.x - rhs.x, y = lhs.y - rhs.y, z = lhs.z - rhs.z
        return x * x + y * y + z * z
    }

    private static func evidenceOrder(
        _ lhs: ReceiverElectrodeObservationEvidence,
        _ rhs: ReceiverElectrodeObservationEvidence
    ) -> Bool {
        if electrodeNumber(lhs.label) != electrodeNumber(rhs.label) {
            return electrodeNumber(lhs.label) < electrodeNumber(rhs.label)
        }
        return lhs.observationID.uuidString < rhs.observationID.uuidString
    }

    private static func electrodeNumber(_ label: String) -> Int {
        Int(label.drop(while: { !$0.isNumber })) ?? .max
    }
}

nonisolated private final class ReceiverElectrodeCoordinateParser: NSObject, XMLParserDelegate {
    struct Sensor {
        var number = ""
        var type = ""
        var x = ""
        var y = ""
        var z = ""
    }

    var coordinates = [Int: Coordinate3D]()
    var failed = false
    private var element = ""
    private var sensor: Sensor?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        element = elementName
        if elementName == "sensor" { sensor = Sensor() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var sensor else { return }
        switch element {
        case "number": sensor.number += string
        case "type": sensor.type += string
        case "x": sensor.x += string
        case "y": sensor.y += string
        case "z": sensor.z += string
        default: break
        }
        self.sensor = sensor
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { element = "" }
        guard elementName == "sensor", let sensor else { return }
        defer { self.sensor = nil }
        guard let number = Int(sensor.number.trimmingCharacters(in: .whitespacesAndNewlines)),
              let type = Int(sensor.type.trimmingCharacters(in: .whitespacesAndNewlines)),
              let x = Double(sensor.x.trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Double(sensor.y.trimmingCharacters(in: .whitespacesAndNewlines)),
              let z = Double(sensor.z.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            failed = true
            return
        }
        if type == 0 { coordinates[number] = Coordinate3D(x: x, y: y, z: z) }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}

nonisolated private struct ReceiverOCRHit {
    var text: String
    var candidates: [ReceiverOCRCandidate]
    var rawPoint: SIMD2<Float>
    var rawTextPoint: SIMD2<Float>
    var didLocateDisc: Bool
    var rawBoundingBox: [Double]
}

nonisolated private struct ReceiverOCRCandidate {
    var label: String
    var text: String
    var confidence: Float
}

nonisolated private struct ReceiverResolvedLabel {
    var candidate: ReceiverOCRCandidate
    var source: String
}

nonisolated private struct ReceiverResolvedOCRHit {
    var hit: ReceiverOCRHit
    var choice: ReceiverResolvedLabel
    var sample: ReceiverDepthSample
    var world: SIMD3<Float>
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
}

nonisolated private struct ReceiverElectrodeDiscLocator {
    private struct Pixel {
        var luminance: Float
        var saturation: Float
    }

    private var pixels: [UInt8]
    private var width: Int
    private var height: Int

    init?(image: CGImage) {
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { return nil }
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func locateDisc(
        nearest textPoint: CGPoint,
        textBox: CGRect,
        orientation: ReceiverStoredImageOrientation,
        rawSize: CGSize
    ) -> CGPoint? {
        let textHeight = max(8, textBox.height)
        let searchRadius = max(textBox.width * 1.35, textHeight * 2.8)
        let step = max(4, min(12, textHeight * 0.28))
        let excludedText = textBox.insetBy(dx: -textHeight * 0.2, dy: -textHeight * 0.2)
        let radii = [textHeight * 0.55, textHeight * 0.85, textHeight * 1.15]
        var best: (point: CGPoint, score: Float)?

        var y = textPoint.y - searchRadius
        while y <= textPoint.y + searchRadius {
            var x = textPoint.x - searchRadius
            while x <= textPoint.x + searchRadius {
                let point = CGPoint(x: x, y: y)
                let distance = hypot(x - textPoint.x, y - textPoint.y)
                guard distance <= searchRadius, !excludedText.contains(point) else {
                    x += step
                    continue
                }
                for radius in radii {
                    guard let appearance = discAppearance(
                        center: point, radius: radius, orientation: orientation,
                        rawSize: rawSize) else { continue }
                    let proximityPenalty = Float(distance / searchRadius) * 0.08
                    let score = appearance - proximityPenalty
                    if score > 0.13, score > (best?.score ?? -.greatestFiniteMagnitude) {
                        best = (point, score)
                    }
                }
                x += step
            }
            y += step
        }
        return best?.point
    }

    private func discAppearance(
        center: CGPoint,
        radius: CGFloat,
        orientation: ReceiverStoredImageOrientation,
        rawSize: CGSize
    ) -> Float? {
        var inner = [Float](), ring = [Float](), innerSaturation = [Float]()
        for sampleY in -4...4 {
            for sampleX in -4...4 {
                let normalized = CGPoint(
                    x: CGFloat(sampleX) / 3,
                    y: CGFloat(sampleY) / 3)
                let radial = hypot(normalized.x, normalized.y)
                guard radial <= 1.75 else { continue }
                let point = CGPoint(
                    x: center.x + normalized.x * radius,
                    y: center.y + normalized.y * radius)
                guard let pixel = pixel(
                    atDisplayPoint: point, orientation: orientation, rawSize: rawSize) else {
                    continue
                }
                if radial <= 1 {
                    inner.append(pixel.luminance)
                    innerSaturation.append(pixel.saturation)
                } else if radial >= 1.25 {
                    ring.append(pixel.luminance)
                }
            }
        }
        guard inner.count >= 12, ring.count >= 12 else { return nil }
        let innerMean = inner.reduce(0, +) / Float(inner.count)
        let ringMean = ring.reduce(0, +) / Float(ring.count)
        let saturation = innerSaturation.reduce(0, +) / Float(innerSaturation.count)
        let variance = inner.reduce(Float.zero) { partial, value in
            partial + (value - innerMean) * (value - innerMean)
        } / Float(inner.count)
        let deviation = sqrt(variance)
        let contrast = ringMean - innerMean
        guard (0.18...0.88).contains(innerMean), contrast >= 0.045,
              saturation <= 0.32, deviation <= 0.30 else { return nil }
        return contrast * 2.2 + (1 - saturation) * 0.12 - deviation * 0.45
    }

    private func pixel(
        atDisplayPoint point: CGPoint,
        orientation: ReceiverStoredImageOrientation,
        rawSize: CGSize
    ) -> Pixel? {
        let raw = orientation.rawPoint(point, rawSize: rawSize)
        let x = Int(raw.x / rawSize.width * CGFloat(width))
        let topY = Int(raw.y / rawSize.height * CGFloat(height))
        let y = height - 1 - topY
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let index = (y * width + x) * 4
        let red = Float(pixels[index]) / 255
        let green = Float(pixels[index + 1]) / 255
        let blue = Float(pixels[index + 2]) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        return Pixel(
            luminance: 0.2126 * red + 0.7152 * green + 0.0722 * blue,
            saturation: maximum > 0 ? (maximum - minimum) / maximum : 0)
    }
}

nonisolated private struct ReceiverLayoutWorldGuide {
    var transform: simd_float4x4
    var predicted: [String: SIMD3<Float>]

    static func make(
        layout: ElectrodeLayout,
        bundle: MANTAValidatedBundle
    ) -> ReceiverLayoutWorldGuide? {
        let world = worldFiducials(bundle: bundle)
        var source = [SIMD3<Float>](), target = [SIMD3<Float>]()
        for kind in FiducialKind.allCases {
            guard let prior = layout.fiducialCoordinatePriors[kind],
                  let point = world[kind] else { continue }
            source.append(SIMD3(Float(prior.x), Float(prior.y), Float(prior.z)))
            target.append(point)
        }
        guard source.count == 3,
              let fit = AbsoluteOrientation.fit(
                source: source, target: target, scale: .estimate) else { return nil }
        var predicted = layout.electrodes.reduce(into: [String: SIMD3<Float>]()) {
            let prior = SIMD3(
                Float($1.coordinatePrior.x), Float($1.coordinatePrior.y),
                Float($1.coordinatePrior.z))
            $0[$1.label] = (fit.transform * SIMD4(prior, 1)).xyz
        }
        for (kind, number) in layout.fiducialSensorHints {
            if let point = world[kind] { predicted["E\(number)"] = point }
        }
        return ReceiverLayoutWorldGuide(transform: fit.transform, predicted: predicted)
    }

    func resolve(
        candidates: [ReceiverOCRCandidate],
        at point: SIMD3<Float>
    ) -> ReceiverResolvedLabel {
        let scored = candidates.compactMap { candidate -> (
            candidate: ReceiverOCRCandidate, distance: Float, score: Float
        )? in
            guard let expected = predicted[candidate.label] else { return nil }
            let distance = simd_distance(expected, point)
            let score = log(max(candidate.confidence, 0.01)) - distance / 0.045
            return (candidate, distance, score)
        }
        guard let selected = scored.max(by: { $0.score < $1.score }) else {
            return ReceiverResolvedLabel(candidate: candidates[0], source: "vision-ocr")
        }
        let nearest = predicted.min { lhs, rhs in
            simd_distance(lhs.value, point) < simd_distance(rhs.value, point)
        }.map { (label: $0.key, distance: simd_distance($0.value, point)) }
        if let nearest, selected.distance > 0.065, nearest.distance < 0.030,
           selected.distance - nearest.distance > 0.040 {
            return ReceiverResolvedLabel(
                candidate: ReceiverOCRCandidate(
                    label: nearest.label, text: selected.candidate.text,
                    confidence: selected.candidate.confidence * 0.55),
                source: "fiducial-layout-correction")
        }
        var candidate = selected.candidate
        if selected.distance > 0.060 { candidate.confidence *= 0.6 }
        return ReceiverResolvedLabel(
            candidate: candidate, source: "vision-ocr+fiducial-layout")
    }

    private static func worldFiducials(
        bundle: MANTAValidatedBundle
    ) -> [FiducialKind: SIMD3<Float>] {
        let declared = bundle.capture.fiducials ?? []
        var output = declared.reduce(into: [FiducialKind: SIMD3<Float>]()) { result, item in
            guard let kind = FiducialKind.allCases.first(where: {
                $0.rawValue.caseInsensitiveCompare(item.kind) == .orderedSame
            }), let coordinate = item.coordinate, coordinate.count == 3 else { return }
            result[kind] = SIMD3(coordinate.map(Float.init))
        }
        if output.count == 3 { return output }

        let url = bundle.rootDirectory.appendingPathComponent(
            "acquisition/fiducial-placements.json")
        guard let data = try? Data(contentsOf: url),
              let evidence = try? MANTAJSON.makeDecoder().decode(
                [FiducialPlacementEvidence].self, from: data) else { return output }
        for item in evidence.sorted(by: { $0.placedAt < $1.placedAt }) {
            output[item.kind] = SIMD3(
                Float(item.coordinate.x), Float(item.coordinate.y), Float(item.coordinate.z))
        }
        return output
    }
}

nonisolated enum ReceiverElectrodeGuessSolver {
    private struct Fit {
        var transform: simd_float4x4
        var rms: Float
        var anchorCount: Int
        var usesFiducialSeed: Bool
    }

    static func recalculate(
        bundle: MANTAValidatedBundle,
        electrodes: [MANTAElectrodeSolution],
        evidence: ReceiverElectrodeEvidenceDocument,
        modelMesh: ReceiverTriangleMesh?
    ) -> ReceiverElectrodeDetectionResult {
        let validNumbers = ReceiverElectrodeDetector.validElectrodeNumbers(
            layoutID: bundle.capture.layoutID)
        guard let layout = ReceiverElectrodeDetector.loadLayout(
            bundle: bundle, validNumbers: validNumbers) else {
            return ReceiverElectrodeDetectionResult(
                electrodes: electrodes, evidence: evidence)
        }
        let guide = ReceiverLayoutWorldGuide.make(layout: layout, bundle: bundle)
        let surface = modelMesh.map(ReceiverSurfaceVertexIndex.init)
        let summariesByLabel = Dictionary(
            uniqueKeysWithValues: evidence.summaries.map { ($0.label, $0) })
        let manualLabels = Set((evidence.manualEdits ?? []).map(\.label))

        let anchors = electrodes.reduce(into: [String: SIMD3<Float>]()) { result, item in
            guard item.coordinate.count == 3,
                  let summary = summariesByLabel[item.label],
                  summary.supportCount > 0 || item.state == "Reviewed" else { return }
            result[item.label] = SIMD3(item.coordinate.map(Float.init))
        }
        guard let fit = fit(
            anchors: anchors, manualLabels: manualLabels,
            layout: layout, guide: guide) else {
            return ReceiverElectrodeDetectionResult(
                electrodes: electrodes, evidence: evidence)
        }

        let definitions = Dictionary(
            uniqueKeysWithValues: layout.electrodes.map { ($0.label, $0) })
        let priors = definitions.mapValues {
            SIMD3(
                Float($0.coordinatePrior.x), Float($0.coordinatePrior.y),
                Float($0.coordinatePrior.z))
        }
        let residuals = anchors.reduce(into: [String: SIMD3<Float>]()) { result, item in
            guard let prior = priors[item.key] else { return }
            result[item.key] = item.value - (fit.transform * SIMD4(prior, 1)).xyz
        }

        let preserved = electrodes.filter { item in
            guard let summary = summariesByLabel[item.label] else {
                return item.state == "Reviewed"
            }
            return summary.supportCount > 0 || item.state == "Reviewed"
        }
        let preservedLabels = Set(preserved.map(\.label))
        var output = preserved
        var outputSummaries = preserved.map { item in
            var summary = summariesByLabel[item.label] ?? ReceiverElectrodeSummary(
                label: item.label, coordinate: item.coordinate, supportCount: 0,
                spreadMeters: 0, confidence: item.confidence, state: item.state,
                rayResidualMeters: nil, surfaceDistanceMeters: nil)
            summary.coordinate = item.coordinate
            summary.confidence = item.confidence
            summary.state = item.state
            return summary
        }

        for definition in layout.electrodes where !preservedLabels.contains(definition.label) {
            guard let prior = priors[definition.label] else { continue }
            var predicted = (fit.transform * SIMD4(prior, 1)).xyz
            let directResiduals = definition.neighbors.compactMap { residuals["E\($0)"] }
            if !directResiduals.isEmpty {
                predicted += directResiduals.reduce(.zero, +) / Float(directResiduals.count)
            }

            var coordinate = predicted
            var surfaceDistance: Float?
            if let nearest = surface?.nearest(to: predicted, maximumDistance: 0.04) {
                coordinate = nearest.point
                surfaceDistance = nearest.distance
            }
            let confidence = guessConfidence(
                fit: fit, directNeighborCount: directResiduals.count,
                manualNeighborCount: definition.neighbors.filter {
                    manualLabels.contains("E\($0)")
                }.count,
                surfaceDistance: surfaceDistance)
            let warning = String(
                format: "Dynamic layout guess · %d anchor neighbors · fit %.1f mm%@",
                directResiduals.count, fit.rms * 1_000,
                fit.usesFiducialSeed ? " · fiducial seed" : "")
            output.append(MANTAElectrodeSolution(
                label: definition.label, role: definition.role.rawValue,
                coordinateSystem: "arkit-world", coordinate: coordinate.doubles,
                confidence: confidence, state: "Guessed"))
            outputSummaries.append(ReceiverElectrodeSummary(
                label: definition.label, coordinate: coordinate.doubles,
                supportCount: 0, spreadMeters: 0, confidence: confidence,
                state: "Guessed", rayResidualMeters: nil,
                surfaceDistanceMeters: surfaceDistance.map(Double.init),
                geometryWarning: warning))
        }

        penalizeCollisions(electrodes: &output, summaries: &outputSummaries)
        output.sort { electrodeNumber($0.label) < electrodeNumber($1.label) }
        outputSummaries.sort { electrodeNumber($0.label) < electrodeNumber($1.label) }
        var updatedEvidence = evidence
        updatedEvidence.generatedAt = Date()
        updatedEvidence.summaries = outputSummaries
        return ReceiverElectrodeDetectionResult(
            electrodes: output, evidence: updatedEvidence)
    }

    private static func fit(
        anchors: [String: SIMD3<Float>],
        manualLabels: Set<String>,
        layout: ElectrodeLayout,
        guide: ReceiverLayoutWorldGuide?
    ) -> Fit? {
        let robust = ElectrodeCapOrientation.estimateRobust(
            detected: anchors, layout: layout)
        let seed: simd_float4x4
        let usesFiducialSeed: Bool
        if let robust, robust.isReliable {
            seed = robust.transform
            usesFiducialSeed = false
        } else if let guide {
            seed = guide.transform
            usesFiducialSeed = true
        } else {
            return nil
        }

        let priors = Dictionary(uniqueKeysWithValues: layout.electrodes.map {
            ($0.label, SIMD3(
                Float($0.coordinatePrior.x), Float($0.coordinatePrior.y),
                Float($0.coordinatePrior.z)))
        })
        let inliers = anchors.compactMap { label, target -> (
            label: String, source: SIMD3<Float>, target: SIMD3<Float>
        )? in
            guard let source = priors[label] else { return nil }
            let residual = simd_distance((seed * SIMD4(source, 1)).xyz, target)
            return manualLabels.contains(label) || residual <= 0.024
                ? (label, source, target) : nil
        }

        var transform = seed
        if Set(inliers.map(\.label)).count >= 3 {
            var source = [SIMD3<Float>](), target = [SIMD3<Float>]()
            for item in inliers {
                let repeats = manualLabels.contains(item.label) ? 4 : 1
                for _ in 0..<repeats {
                    source.append(item.source)
                    target.append(item.target)
                }
            }
            transform = AbsoluteOrientation.fit(
                source: source, target: target, scale: .estimate)?.transform ?? seed
        }

        let residuals = inliers.map {
            simd_distance((transform * SIMD4($0.source, 1)).xyz, $0.target)
        }
        let rms = residuals.isEmpty
            ? (robust?.rmsError ?? 0.022)
            : sqrt(residuals.reduce(0) { $0 + $1 * $1 } / Float(residuals.count))
        return Fit(
            transform: transform, rms: rms,
            anchorCount: Set(inliers.map(\.label)).count,
            usesFiducialSeed: usesFiducialSeed)
    }

    private static func guessConfidence(
        fit: Fit,
        directNeighborCount: Int,
        manualNeighborCount: Int,
        surfaceDistance: Float?
    ) -> Double {
        let fitComponent = 0.45 + 0.55 * exp(-Double(fit.rms) / 0.020)
        let anchorComponent = 0.50 + 0.50 * min(1, Double(fit.anchorCount) / 12)
        let neighborComponent = 0.65 + 0.35 * min(1, Double(directNeighborCount) / 3)
        let surfaceComponent = surfaceDistance.map {
            0.65 + 0.35 * exp(-Double($0) / 0.015)
        } ?? 0.58
        let manualBoost = min(0.12, Double(manualNeighborCount) * 0.06)
        return min(0.98, max(0.05,
            fitComponent * anchorComponent * neighborComponent * surfaceComponent
                + manualBoost))
    }

    private static func penalizeCollisions(
        electrodes: inout [MANTAElectrodeSolution],
        summaries: inout [ReceiverElectrodeSummary]
    ) {
        for first in electrodes.indices where electrodes[first].state == "Guessed" {
            guard let firstPoint = SIMD3<Float>(doubles: electrodes[first].coordinate) else { continue }
            for second in electrodes.indices where second > first {
                guard let secondPoint = SIMD3<Float>(doubles: electrodes[second].coordinate),
                      simd_distance(firstPoint, secondPoint) < 0.008 else { continue }
                electrodes[first].confidence *= 0.55
                if electrodes[second].state == "Guessed" {
                    electrodes[second].confidence *= 0.55
                }
                if let index = summaries.firstIndex(where: {
                    $0.label == electrodes[first].label
                }) {
                    summaries[index].confidence = electrodes[first].confidence
                    summaries[index].geometryWarning =
                        (summaries[index].geometryWarning ?? "Guess")
                        + " · spatial collision"
                }
                if let index = summaries.firstIndex(where: {
                    $0.label == electrodes[second].label
                }), electrodes[second].state == "Guessed" {
                    summaries[index].confidence = electrodes[second].confidence
                    summaries[index].geometryWarning =
                        (summaries[index].geometryWarning ?? "Guess")
                        + " · spatial collision"
                }
            }
        }
    }

    private static func electrodeNumber(_ label: String) -> Int {
        Int(label.drop(while: { !$0.isNumber })) ?? .max
    }
}

nonisolated private struct ReceiverDepthSample {
    var depth: Float
    var confidence: UInt8
}

nonisolated private struct ReceiverElectrodeDepthFrame {
    var values: [Float]
    var confidence: [UInt8]?
    var width: Int
    var height: Int
    var imageWidth: Int
    var imageHeight: Int

    init?(observation: MANTACaptureObservation, rootDirectory: URL) {
        guard let artifact = observation.depth,
              artifact.scalarType.lowercased() == "float32",
              artifact.units == .meters,
              artifact.byteOrder.lowercased() == "little-endian",
              artifact.imageMapping.lowercased() == "resolution-scale" else { return nil }
        width = artifact.dimensions.width
        height = artifact.dimensions.height
        imageWidth = observation.imageDimensions.width
        imageHeight = observation.imageDimensions.height
        let count = width * height
        guard count > 0,
              let data = Self.decode(
                rootDirectory.appendingPathComponent(artifact.path),
                compression: artifact.compression,
                expectedSize: count * MemoryLayout<Float>.size) else { return nil }
        values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        confidence = artifact.confidencePath.flatMap {
            Self.decode(
                rootDirectory.appendingPathComponent($0),
                compression: artifact.compression, expectedSize: count)
        }.map(Array.init)
    }

    func sample(rawImagePoint: SIMD2<Float>) -> ReceiverDepthSample? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let x = Int(rawImagePoint.x / Float(imageWidth) * Float(width))
        let y = Int(rawImagePoint.y / Float(imageHeight) * Float(height))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        var high = [(Float, UInt8)](), medium = [(Float, UInt8)]()
        for sampleY in max(0, y - 2)...min(height - 1, y + 2) {
            for sampleX in max(0, x - 2)...min(width - 1, x + 2) {
                let index = sampleY * width + sampleX
                let value = values[index]
                let quality = confidence?[index] ?? 2
                guard value.isFinite, value >= 0.2, value <= 2 else { continue }
                if quality >= 2 { high.append((value, quality)) }
                if quality >= 1 { medium.append((value, quality)) }
            }
        }
        let samples = high.isEmpty ? medium : high
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted { $0.0 < $1.0 }
        let selected = sorted[sorted.count / 2]
        return ReceiverDepthSample(depth: selected.0, confidence: selected.1)
    }

    private static func decode(
        _ url: URL, compression: String, expectedSize: Int
    ) -> Data? {
        guard let source = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard compression.lowercased() == "zlib" else {
            return source.count == expectedSize ? source : nil
        }
        var destination = Data(count: expectedSize)
        let decoded = destination.withUnsafeMutableBytes { output in
            source.withUnsafeBytes { input in
                guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outputBase, expectedSize, inputBase, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        return decoded == expectedSize ? destination : nil
    }
}

nonisolated private struct ReceiverRayEvidence {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
    var weight: Float

    init?(_ evidence: ReceiverElectrodeObservationEvidence) {
        guard let origin = SIMD3<Float>(doubles: evidence.rayOrigin),
              let direction = SIMD3<Float>(doubles: evidence.rayDirection) else { return nil }
        self.origin = origin
        self.direction = simd_normalize(direction)
        weight = max(0.05, Float(evidence.ocrConfidence))
    }
}

nonisolated private struct ReceiverRayFit {
    var point: SIMD3<Float>
    var rms: Float
}

nonisolated private enum ReceiverRayTriangulator {
    static func fit(_ rays: [ReceiverRayEvidence]) -> ReceiverRayFit? {
        guard rays.count >= 2 else { return nil }
        var matrix = simd_float3x3(columns: (.zero, .zero, .zero))
        var vector = SIMD3<Float>(repeating: 0)
        var totalWeight: Float = 0
        let identity = matrix_identity_float3x3
        for ray in rays {
            let projection = identity - simd_float3x3(
                ray.direction * ray.direction.x,
                ray.direction * ray.direction.y,
                ray.direction * ray.direction.z)
            matrix += projection * ray.weight
            vector += projection * ray.origin * ray.weight
            totalWeight += ray.weight
        }
        let determinant = simd_determinant(matrix)
        guard determinant.isFinite, abs(determinant) > 1e-7, totalWeight > 0 else { return nil }
        let point = simd_inverse(matrix) * vector
        guard point.allFinite else { return nil }
        let error = rays.reduce(Float.zero) { partial, ray in
            let delta = point - ray.origin
            let perpendicular = delta - simd_dot(delta, ray.direction) * ray.direction
            return partial + ray.weight * simd_length_squared(perpendicular)
        }
        return ReceiverRayFit(point: point, rms: sqrt(error / totalWeight))
    }
}

nonisolated private struct ReceiverSurfaceVertexIndex {
    private struct Key: Hashable {
        var x: Int
        var y: Int
        var z: Int
    }

    private let cellSize: Float = 0.01
    private var cells: [Key: [SIMD3<Float>]]

    init(mesh: ReceiverTriangleMesh) {
        let size = cellSize
        cells = Dictionary(grouping: mesh.vertices) { point in
            Self.key(point, cellSize: size)
        }
    }

    func nearest(
        to point: SIMD3<Float>, maximumDistance: Float
    ) -> (point: SIMD3<Float>, distance: Float)? {
        let center = key(point)
        let radius = Int(ceil(maximumDistance / cellSize))
        var bestPoint: SIMD3<Float>?
        var bestDistance = maximumDistance
        for z in (center.z - radius)...(center.z + radius) {
            for y in (center.y - radius)...(center.y + radius) {
                for x in (center.x - radius)...(center.x + radius) {
                    for candidate in cells[Key(x: x, y: y, z: z)] ?? [] {
                        let distance = simd_distance(candidate, point)
                        if distance < bestDistance {
                            bestDistance = distance
                            bestPoint = candidate
                        }
                    }
                }
            }
        }
        return bestPoint.map { ($0, bestDistance) }
    }

    private func key(_ point: SIMD3<Float>) -> Key {
        Self.key(point, cellSize: cellSize)
    }

    private static func key(_ point: SIMD3<Float>, cellSize: Float) -> Key {
        Key(
            x: Int(floor(point.x / cellSize)),
            y: Int(floor(point.y / cellSize)),
            z: Int(floor(point.z / cellSize)))
    }
}

nonisolated private extension SIMD2 where Scalar == Float {
    var doubles: [Double] { [Double(x), Double(y)] }
}

nonisolated private extension SIMD3 where Scalar == Float {
    init?(doubles: [Double]) {
        guard doubles.count == 3 else { return nil }
        self.init(Float(doubles[0]), Float(doubles[1]), Float(doubles[2]))
    }

    var doubles: [Double] { [Double(x), Double(y), Double(z)] }
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

nonisolated private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
