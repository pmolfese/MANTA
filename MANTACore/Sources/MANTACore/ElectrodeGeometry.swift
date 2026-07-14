import Foundation
import simd

public enum ElectrodeNeighborValidator {
    public struct Result: Equatable, Sendable {
        public var suspectLabels: Set<String>
        public var scale: Float
        public init(suspectLabels: Set<String>, scale: Float) {
            self.suspectLabels = suspectLabels
            self.scale = scale
        }
    }

    public static func validate(
        positions: [String: SIMD3<Float>], layout: ElectrodeLayout,
        toleranceMeters: Float = 0.01, minNeighbors: Int = 2,
        minConsistentFraction: Float = 0.5
    ) -> Result {
        let byLabel = Dictionary(uniqueKeysWithValues: layout.electrodes.map { ($0.label, $0) })
        let byNumber = Dictionary(uniqueKeysWithValues: layout.electrodes.map { ($0.number, $0) })
        var ratios = [Float]()
        var edges = [(String, Float, Float)]()
        for (label, definition) in byLabel {
            guard let position = positions[label] else { continue }
            let prior = vector(definition.coordinatePrior)
            for number in definition.neighbors {
                guard let neighbor = byNumber[number], let neighborPosition = positions[neighbor.label]
                else { continue }
                let detected = simd_distance(position, neighborPosition)
                let template = simd_distance(prior, vector(neighbor.coordinatePrior))
                guard template > 1e-6 else { continue }
                edges.append((label, detected, template))
                if definition.number < neighbor.number { ratios.append(detected / template) }
            }
        }
        let scale = median(ratios)
        guard scale > 0 else { return Result(suspectLabels: [], scale: 0) }
        var counts = [String: (consistent: Int, total: Int)]()
        for (label, detected, template) in edges {
            var count = counts[label, default: (0, 0)]
            count.total += 1
            if abs(detected - scale * template) <= toleranceMeters { count.consistent += 1 }
            counts[label] = count
        }
        let suspects: Set<String> = Set(counts.compactMap { label, count -> String? in
            guard count.total >= minNeighbors else { return nil }
            return Float(count.consistent) / Float(count.total) < minConsistentFraction ? label : nil
        })
        return Result(suspectLabels: suspects, scale: scale)
    }

    private static func vector(_ value: Coordinate3D) -> SIMD3<Float> {
        SIMD3(Float(value.x), Float(value.y), Float(value.z))
    }
}

public enum ElectrodeCapOrientation {
    public struct Result: Sendable {
        public var transform: simd_float4x4
        public var rotation: simd_quatf
        public var scale: Float
        public var rmsError: Float
        public var anchorCount: Int
        public var anchorSpreadRatio: Float
        public var cardinalConsistency: Float?
        public var isReliable: Bool
    }

    public static func estimate(
        detected: [String: SIMD3<Float>], layout: ElectrodeLayout,
        minAnchors: Int = 4, minSpreadRatio: Float = 0.4, maxRMSMeters: Float = 0.02
    ) -> Result? {
        let template = layout.electrodes.reduce(into: [String: SIMD3<Float>]()) {
            $0[$1.label] = vector($1.coordinatePrior)
        }
        var labels = [String](), source = [SIMD3<Float>](), target = [SIMD3<Float>]()
        for (label, position) in detected {
            guard let prior = template[label] else { continue }
            labels.append(label); source.append(prior); target.append(position)
        }
        guard source.count >= minAnchors,
              let fit = AbsoluteOrientation.fit(source: source, target: target, scale: .estimate)
        else { return nil }
        let scale = simd_length(fit.transform.columns.0.xyz)
        guard scale.isFinite, scale > 0 else { return nil }
        let rotation = simd_quatf(simd_float3x3(
            fit.transform.columns.0.xyz / scale, fit.transform.columns.1.xyz / scale,
            fit.transform.columns.2.xyz / scale))
        let headExtent = extent(Array(template.values))
        let spread = headExtent > 0 ? extent(source) / headExtent : 0
        let residuals = labels.enumerated().compactMap { index, label -> Float? in
            guard layout.cardinalLabels.contains(label) else { return nil }
            let predicted = fit.transform * SIMD4(source[index], 1)
            return simd_distance(predicted.xyz, target[index])
        }
        let cardinal = residuals.isEmpty ? nil : median(residuals)
        let reliable = spread >= minSpreadRatio && fit.rmsError.isFinite
            && fit.rmsError <= maxRMSMeters && (cardinal ?? 0) <= maxRMSMeters
        return Result(
            transform: fit.transform, rotation: rotation, scale: scale, rmsError: fit.rmsError,
            anchorCount: source.count, anchorSpreadRatio: spread,
            cardinalConsistency: cardinal, isReliable: reliable)
    }

    /// Fits the cap while tolerating a minority of mislabeled detections.
    /// Candidate subsets are deterministic so repeated processing is reproducible.
    public static func estimateRobust(
        detected: [String: SIMD3<Float>], layout: ElectrodeLayout,
        minAnchors: Int = 4, minSpreadRatio: Float = 0.4,
        maxRMSMeters: Float = 0.02, inlierThresholdMeters: Float = 0.018,
        iterations: Int = 512
    ) -> Result? {
        if let direct = estimate(
            detected: detected, layout: layout, minAnchors: minAnchors,
            minSpreadRatio: minSpreadRatio, maxRMSMeters: maxRMSMeters),
           direct.isReliable {
            return direct
        }

        let priors = layout.electrodes.reduce(into: [String: SIMD3<Float>]()) {
            $0[$1.label] = vector($1.coordinatePrior)
        }
        let labels = detected.keys.filter { priors[$0] != nil }.sorted()
        guard labels.count > minAnchors, minAnchors >= 3 else { return nil }

        var state: UInt64 = 0x4D41_4E54_41
        var best: (result: Result, inliers: Int)?
        for _ in 0..<max(1, iterations) {
            var indices = Set<Int>()
            while indices.count < minAnchors {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                indices.insert(Int(state % UInt64(labels.count)))
            }
            let sample = Dictionary(uniqueKeysWithValues: indices.map {
                (labels[$0], detected[labels[$0]]!)
            })
            guard let candidate = estimate(
                detected: sample, layout: layout, minAnchors: minAnchors,
                minSpreadRatio: minSpreadRatio * 0.5,
                maxRMSMeters: maxRMSMeters) else { continue }

            let inlierLabels = labels.filter { label in
                guard let prior = priors[label], let target = detected[label] else { return false }
                let predicted = (candidate.transform * SIMD4(prior, 1)).xyz
                return simd_distance(predicted, target) <= inlierThresholdMeters
            }
            guard inlierLabels.count >= minAnchors else { continue }
            let inliers = Dictionary(uniqueKeysWithValues: inlierLabels.map {
                ($0, detected[$0]!)
            })
            guard let refined = estimate(
                detected: inliers, layout: layout, minAnchors: minAnchors,
                minSpreadRatio: minSpreadRatio, maxRMSMeters: maxRMSMeters),
                  refined.isReliable else { continue }
            if best == nil || inlierLabels.count > best!.inliers
                || (inlierLabels.count == best!.inliers
                    && refined.rmsError < best!.result.rmsError) {
                best = (refined, inlierLabels.count)
            }
        }
        return best?.result
    }

    private static func vector(_ value: Coordinate3D) -> SIMD3<Float> {
        SIMD3(Float(value.x), Float(value.y), Float(value.z))
    }
    private static func extent(_ points: [SIMD3<Float>]) -> Float {
        guard !points.isEmpty else { return 0 }
        let center = points.reduce(.zero, +) / Float(points.count)
        return points.map { simd_distance($0, center) }.max() ?? 0
    }
}

public enum ElectrodeTemplateFitter {
    public struct Result: Sendable {
        public var transform: simd_float4x4
        public var rmsError: Float
        public var filled: [String: SIMD3<Float>]
        public var anchorCount: Int
    }

    public static func fit(
        detected: [String: SIMD3<Float>], layout: ElectrodeLayout, minAnchors: Int = 4
    ) -> Result? {
        let template = layout.electrodes.reduce(into: [String: SIMD3<Float>]()) {
            $0[$1.label] = vector($1.coordinatePrior)
        }
        var source = [SIMD3<Float>](), target = [SIMD3<Float>]()
        for (label, position) in detected where template[label] != nil {
            source.append(template[label]!); target.append(position)
        }
        guard source.count >= minAnchors,
              let fit = AbsoluteOrientation.fit(source: source, target: target, scale: .estimate)
        else { return nil }
        let filled = template.reduce(into: [String: SIMD3<Float>]()) { output, item in
            guard detected[item.key] == nil else { return }
            output[item.key] = (fit.transform * SIMD4(item.value, 1)).xyz
        }
        return Result(
            transform: fit.transform, rmsError: fit.rmsError, filled: filled,
            anchorCount: source.count)
    }

    public static func fillMissing(
        annotations: [ElectrodeAnnotation], layout: ElectrodeLayout, minAnchors: Int = 4
    ) -> [ElectrodeAnnotation] {
        let anchors = annotations.filter { $0.state == .detected }.reduce(
            into: [String: SIMD3<Float>]()) {
                $0[$1.label] = vector($1.coordinate)
            }
        guard let orientation = ElectrodeCapOrientation.estimate(
            detected: anchors, layout: layout, minAnchors: minAnchors),
              orientation.isReliable else { return annotations }
        let existing = Set(annotations.map(\.label))
        var output = annotations
        for electrode in layout.electrodes where !existing.contains(electrode.label) {
            let predicted = (orientation.transform * SIMD4(vector(electrode.coordinatePrior), 1)).xyz
            output.append(ElectrodeAnnotation(
                label: electrode.label, role: electrode.role,
                coordinate: Coordinate3D(
                    x: Double(predicted.x), y: Double(predicted.y), z: Double(predicted.z)),
                confidence: 0, state: .needsReview))
        }
        return output
    }

    private static func vector(_ value: Coordinate3D) -> SIMD3<Float> {
        SIMD3(Float(value.x), Float(value.y), Float(value.z))
    }
}

public enum HeadCoordinateFrame {
    public static func solve(
        nasion: SIMD3<Float>, leftPreauricular: SIMD3<Float>,
        rightPreauricular: SIMD3<Float>
    ) -> simd_float4x4? {
        let origin = (leftPreauricular + rightPreauricular) / 2
        let across = rightPreauricular - leftPreauricular
        guard simd_length(across) > 1e-6 else { return nil }
        let x = simd_normalize(across)
        let forward = nasion - origin
        let perpendicular = forward - simd_dot(forward, x) * x
        guard simd_length(perpendicular) > 1e-6 else { return nil }
        let y = simd_normalize(perpendicular), z = simd_cross(x, y)
        let worldToHead = simd_float3x3(x, y, z).transpose
        return simd_float4x4(
            SIMD4(worldToHead.columns.0, 0), SIMD4(worldToHead.columns.1, 0),
            SIMD4(worldToHead.columns.2, 0), SIMD4(-(worldToHead * origin), 1))
    }

    public static func apply(to session: ScanSession) -> ScanSession? {
        let pairs: [(FiducialKind, SIMD3<Float>)] = session.fiducials.compactMap {
            guard let coordinate = $0.coordinate else { return nil }
            return ($0.kind, vector(coordinate))
        }
        let positions = Dictionary(uniqueKeysWithValues: pairs)
        guard let nasion = positions[.nasion], let left = positions[.leftPreauricular],
              let right = positions[.rightPreauricular],
              let transform = solve(
                nasion: nasion, leftPreauricular: left, rightPreauricular: right)
        else { return nil }
        func converted(_ value: Coordinate3D) -> Coordinate3D {
            let point = (transform * SIMD4(vector(value), 1)).xyz * 1000
            return Coordinate3D(x: Double(point.x), y: Double(point.y), z: Double(point.z))
        }
        var result = session
        result.electrodes = session.electrodes.map {
            var value = $0; value.coordinate = converted(value.coordinate); return value
        }
        result.fiducials = session.fiducials.map {
            var value = $0
            if let coordinate = value.coordinate { value.coordinate = converted(coordinate) }
            return value
        }
        result.coordinateSpace = .headRASMillimeters
        return result
    }

    private static func vector(_ value: Coordinate3D) -> SIMD3<Float> {
        SIMD3(Float(value.x), Float(value.y), Float(value.z))
    }
}

private func median(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let values = values.sorted(), middle = values.count / 2
    return values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2 : values[middle]
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
