//
//  ElectrodeObservationAggregatorTests.swift
//  MANTATests
//
//  Validates the multi-frame fusion: outlier rejection, robust centering, and
//  the confidence ordering (more/tighter observations -> higher confidence).
//

import Foundation
import Testing
import simd
@testable import MANTA

struct ElectrodeObservationAggregatorTests {
    private func jitter(_ base: SIMD3<Float>, _ offset: SIMD3<Float>) -> SIMD3<Float> {
        base + offset
    }

    @Test func singleObservationIsKept() {
        let detections = [LabeledDetection(label: "E31", world: SIMD3(0.1, 0.2, 0.3), quality: 0.8)]
        let result = ElectrodeObservationAggregator.aggregate(detections)

        #expect(result.count == 1)
        #expect(result[0].label == "E31")
        #expect(result[0].observationCount == 1)
        #expect(simd_distance(result[0].position, SIMD3(0.1, 0.2, 0.3)) < 1e-5)
    }

    @Test func tightClusterCentersAndKeepsAll() {
        let base = SIMD3<Float>(0.5, 0.5, 0.5)
        let detections = [
            LabeledDetection(label: "E5", world: jitter(base, SIMD3(0.001, 0, 0))),
            LabeledDetection(label: "E5", world: jitter(base, SIMD3(-0.001, 0, 0))),
            LabeledDetection(label: "E5", world: jitter(base, SIMD3(0, 0.001, 0))),
            LabeledDetection(label: "E5", world: jitter(base, SIMD3(0, -0.001, 0)))
        ]
        let result = ElectrodeObservationAggregator.aggregate(detections)

        #expect(result.count == 1)
        #expect(result[0].observationCount == 4)
        #expect(simd_distance(result[0].position, base) < 1e-3)
        #expect(result[0].spread < 0.002)
    }

    @Test func farOutlierIsRejected() {
        let base = SIMD3<Float>(0, 0, 0)
        let detections = [
            LabeledDetection(label: "E10", world: jitter(base, SIMD3(0.001, 0, 0))),
            LabeledDetection(label: "E10", world: jitter(base, SIMD3(-0.001, 0, 0))),
            LabeledDetection(label: "E10", world: jitter(base, SIMD3(0, 0.0015, 0))),
            // 10 cm away: a bad depth sample or OCR mislocalization.
            LabeledDetection(label: "E10", world: jitter(base, SIMD3(0.10, 0, 0)))
        ]
        let result = ElectrodeObservationAggregator.aggregate(detections)

        #expect(result.count == 1)
        #expect(result[0].observationCount == 3)
        #expect(simd_distance(result[0].position, base) < 0.003)
    }

    @Test func moreConsistentObservationsRaiseConfidence() {
        let base = SIMD3<Float>(1, 1, 1)
        let sparse = [
            LabeledDetection(label: "E1", world: jitter(base, SIMD3(0.002, 0, 0))),
            LabeledDetection(label: "E1", world: jitter(base, SIMD3(-0.002, 0, 0)))
        ]
        let dense = (0..<8).map { i in
            let s = Float(i) - 3.5
            return LabeledDetection(label: "E2", world: jitter(SIMD3(2, 2, 2), SIMD3(s * 0.0002, 0, 0)))
        }

        let sparseResult = ElectrodeObservationAggregator.aggregate(sparse)[0]
        let denseResult = ElectrodeObservationAggregator.aggregate(dense)[0]

        #expect(denseResult.confidence > sparseResult.confidence)
    }

    @Test func lowerQualityLowersConfidence() {
        let base = SIMD3<Float>(0, 0, 0)
        func detections(quality: Float) -> [LabeledDetection] {
            [
                LabeledDetection(label: "E1", world: jitter(base, SIMD3(0.001, 0, 0)), quality: quality),
                LabeledDetection(label: "E1", world: jitter(base, SIMD3(-0.001, 0, 0)), quality: quality),
                LabeledDetection(label: "E1", world: jitter(base, SIMD3(0, 0.001, 0)), quality: quality)
            ]
        }
        let high = ElectrodeObservationAggregator.aggregate(detections(quality: 0.9))[0]
        let low = ElectrodeObservationAggregator.aggregate(detections(quality: 0.3))[0]

        #expect(high.confidence > low.confidence)
    }

    @Test func distinctLabelsProduceDistinctEntriesSorted() {
        let detections = [
            LabeledDetection(label: "E9", world: SIMD3(0, 0, 0)),
            LabeledDetection(label: "E1", world: SIMD3(1, 0, 0)),
            LabeledDetection(label: "E5", world: SIMD3(2, 0, 0))
        ]
        let result = ElectrodeObservationAggregator.aggregate(detections)
        #expect(result.map(\.label) == ["E1", "E5", "E9"])
    }
}
