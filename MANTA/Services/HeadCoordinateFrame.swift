//
//  HeadCoordinateFrame.swift
//  MANTA
//
//  Converts electrode positions from the arbitrary ARKit world frame into a
//  fiducial-anchored head coordinate system, which is what the export formats
//  (SFP/ELP/CSV/BIDS) are meant to carry. Without this, exported coordinates are
//  in whatever pose ARKit happened to start in — not comparable between scans.
//
//  Convention: right-handed RAS built from the three landmarks.
//    - origin: midpoint of the two preauricular points (LPA, RPA)
//    - +x: toward the right preauricular (RPA)
//    - +y: anterior, toward nasion (orthogonalized against x)
//    - +z: superior (x × y)
//  This matches the common EEG/MEG fiducial frame (CTF/MNE-style). The frame is
//  defined purely by the fiducials, so a given electrode's head-frame coordinate
//  is invariant to how the head was scanned.
//

import Foundation
import simd

enum HeadCoordinateFrame {
    /// Rigid transform mapping world points into the head frame, or nil when the
    /// fiducials are degenerate (coincident ears, or nasion collinear with them).
    static func solve(
        nasion: SIMD3<Float>,
        leftPreauricular: SIMD3<Float>,
        rightPreauricular: SIMD3<Float>
    ) -> simd_float4x4? {
        let origin = (leftPreauricular + rightPreauricular) / 2

        let across = rightPreauricular - leftPreauricular
        guard simd_length(across) > 1e-6 else { return nil }
        let xAxis = simd_normalize(across)

        let forward = nasion - origin
        let forwardPerp = forward - simd_dot(forward, xAxis) * xAxis
        guard simd_length(forwardPerp) > 1e-6 else { return nil }
        let yAxis = simd_normalize(forwardPerp)

        let zAxis = simd_cross(xAxis, yAxis)

        // Columns are the head basis in world coords (head -> world rotation);
        // its transpose maps world -> head.
        let headToWorld = simd_float3x3(xAxis, yAxis, zAxis)
        let worldToHead = headToWorld.transpose
        let translation = -(worldToHead * origin)

        return simd_float4x4(
            SIMD4<Float>(worldToHead.columns.0, 0),
            SIMD4<Float>(worldToHead.columns.1, 0),
            SIMD4<Float>(worldToHead.columns.2, 0),
            SIMD4<Float>(translation, 1)
        )
    }

    /// Returns a copy of `session` with electrode and fiducial coordinates
    /// expressed in the head frame and scaled (`scale`, default meters -> mm).
    /// Returns nil when the fiducials aren't all placed or are degenerate, so the
    /// caller can fall back to raw world coordinates.
    static func apply(to session: ScanSession, scale: Double = 1000) -> ScanSession? {
        let byKind = Dictionary(uniqueKeysWithValues: session.fiducials.compactMap { fiducial -> (FiducialKind, SIMD3<Float>)? in
            guard let c = fiducial.coordinate else { return nil }
            return (fiducial.kind, SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)))
        })

        guard let nasion = byKind[.nasion],
              let lpa = byKind[.leftPreauricular],
              let rpa = byKind[.rightPreauricular],
              let transform = solve(nasion: nasion, leftPreauricular: lpa, rightPreauricular: rpa) else {
            return nil
        }

        func convert(_ coordinate: Coordinate3D) -> Coordinate3D {
            let world = SIMD4<Float>(Float(coordinate.x), Float(coordinate.y), Float(coordinate.z), 1)
            let head = transform * world
            return Coordinate3D(x: Double(head.x) * scale, y: Double(head.y) * scale, z: Double(head.z) * scale)
        }

        var converted = session
        converted.electrodes = session.electrodes.map {
            var electrode = $0
            electrode.coordinate = convert(electrode.coordinate)
            return electrode
        }
        converted.fiducials = session.fiducials.map {
            var fiducial = $0
            if let coordinate = fiducial.coordinate {
                fiducial.coordinate = convert(coordinate)
            }
            return fiducial
        }
        return converted
    }
}
