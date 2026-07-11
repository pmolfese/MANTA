//
//  ElectrodeExporters.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation

enum ElectrodeExportFormat: String, CaseIterable, Identifiable {
    case csv = "CSV"
    case sfp = "SFP"
    case elp = "ELP"
    case bidsElectrodesTSV = "BIDS electrodes.tsv"

    var id: String { rawValue }
}

struct ElectrodeExporters {
    static func export(_ session: ScanSession, as format: ElectrodeExportFormat) -> String {
        switch format {
        case .csv:
            return csv(session)
        case .sfp:
            return sfp(session)
        case .elp:
            return elp(session)
        case .bidsElectrodesTSV:
            return bidsElectrodesTSV(session)
        }
    }

    static func csv(_ session: ScanSession) -> String {
        let header = "label,x,y,z,role,state,confidence"
        let rows = session.electrodes.map { electrode in
            [
                electrode.label,
                coordinateString(electrode.coordinate.x),
                coordinateString(electrode.coordinate.y),
                coordinateString(electrode.coordinate.z),
                electrode.role.rawValue,
                electrode.state.rawValue,
                String(format: "%.3f", electrode.confidence)
            ].joined(separator: ",")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    /// EGI-style .sfp, readable by `mne.channels.read_custom_montage`.
    /// Fiducials are emitted first using the labels MNE recognizes (FidNz/FidT9/FidT10)
    /// so it can construct the head coordinate frame; electrodes follow.
    static func sfp(_ session: ScanSession) -> String {
        let fiducialRows = session.fiducials.compactMap { fiducial -> String? in
            guard let coordinate = fiducial.coordinate else { return nil }
            return [
                sfpFiducialLabel(fiducial.kind),
                coordinateString(coordinate.x),
                coordinateString(coordinate.y),
                coordinateString(coordinate.z)
            ].joined(separator: "\t")
        }

        let electrodeRows = session.electrodes.map { electrode in
            [
                electrode.label,
                coordinateString(electrode.coordinate.x),
                coordinateString(electrode.coordinate.y),
                coordinateString(electrode.coordinate.z)
            ].joined(separator: "\t")
        }

        return (fiducialRows + electrodeRows).joined(separator: "\n")
    }

    /// Standard EGI/MNE fiducial labels.
    private static func sfpFiducialLabel(_ kind: FiducialKind) -> String {
        switch kind {
        case .nasion:
            return "FidNz"
        case .leftPreauricular:
            return "FidT9"
        case .rightPreauricular:
            return "FidT10"
        }
    }

    static func elp(_ session: ScanSession) -> String {
        let fiducials = session.fiducials.compactMap { fiducial -> String? in
            guard let coordinate = fiducial.coordinate else { return nil }

            return [
                fiducial.kind.rawValue,
                coordinateString(coordinate.x),
                coordinateString(coordinate.y),
                coordinateString(coordinate.z)
            ].joined(separator: "\t")
        }

        let electrodes = session.electrodes.map { electrode in
            [
                electrode.label,
                coordinateString(electrode.coordinate.x),
                coordinateString(electrode.coordinate.y),
                coordinateString(electrode.coordinate.z)
            ].joined(separator: "\t")
        }

        return (["// MANTA ELP export"] + fiducials + electrodes).joined(separator: "\n")
    }

    static func bidsElectrodesTSV(_ session: ScanSession) -> String {
        let header = "name\tx\ty\tz\ttype"
        let rows = session.electrodes.map { electrode in
            [
                electrode.label,
                coordinateString(electrode.coordinate.x),
                coordinateString(electrode.coordinate.y),
                coordinateString(electrode.coordinate.z),
                "EEG"
            ].joined(separator: "\t")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
