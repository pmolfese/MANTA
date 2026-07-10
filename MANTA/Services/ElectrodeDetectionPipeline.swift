//
//  ElectrodeDetectionPipeline.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation

protocol ElectrodeDetectionPipeline {
    func detectElectrodes(for layout: ElectrodeLayout) async throws -> [ElectrodeAnnotation]
}

struct MockElectrodeDetectionPipeline: ElectrodeDetectionPipeline {
    func detectElectrodes(for layout: ElectrodeLayout) async throws -> [ElectrodeAnnotation] {
        layout.electrodes.enumerated().map { index, electrodeDefinition in
            let label = electrodeDefinition.label
            let ring = Double(index / 8)
            let angle = Double(index % 8) / 8.0 * .pi * 2.0
            let radius = 55.0 + ring * 2.0
            let isCardinal = electrodeDefinition.role == .cardinal

            return ElectrodeAnnotation(
                label: label,
                role: isCardinal ? .cardinal : .regular,
                coordinate: Coordinate3D(
                    x: cos(angle) * radius,
                    y: sin(angle) * radius,
                    z: 85.0 - ring * 5.0
                ),
                confidence: isCardinal ? 0.92 : 0.74,
                state: isCardinal ? .reviewed : .detected
            )
        }
    }
}
