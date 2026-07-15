import Foundation

public enum ElectrodeExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv = "CSV"
    case sfp = "SFP"
    case elp = "ELP"
    case bidsElectrodesTSV = "BIDS electrodes.tsv"
    case egiCoordinatesXML = "EGI coordinates.xml"

    public var id: String { rawValue }
}

public struct ElectrodeExporters {
    public static func export(_ session: ScanSession, as format: ElectrodeExportFormat) -> String {
        switch format {
        case .csv: csv(session)
        case .sfp: sfp(session)
        case .elp: elp(session)
        case .bidsElectrodesTSV: bidsElectrodesTSV(session)
        case .egiCoordinatesXML: egiCoordinatesXML(session)
        }
    }

    public static func csv(_ session: ScanSession) -> String {
        let unit = session.coordinateSpace.unit.rawValue
        let header = "label,x,y,z,unit,coordinate_frame,role,state,confidence"
        let rows = session.electrodes.map { electrode in
            [
                electrode.label,
                coordinateString(electrode.coordinate.x),
                coordinateString(electrode.coordinate.y),
                coordinateString(electrode.coordinate.z),
                unit,
                session.coordinateSpace.frame.rawValue,
                electrode.role.rawValue,
                electrode.state.rawValue,
                String(format: "%.3f", electrode.confidence)
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    /// MNE-oriented SFP. SFP cannot declare units, so MANTA always writes meters.
    public static func sfp(_ session: ScanSession) -> String {
        let fiducials = session.fiducials.compactMap { fiducial -> String? in
            guard fiducial.kind.isCardinal, let coordinate = fiducial.coordinate else { return nil }
            return sfpRow(
                label: sfpFiducialLabel(fiducial.kind), coordinate: coordinate,
                sourceUnit: session.coordinateSpace.unit)
        }
        let electrodes = session.electrodes.map {
            sfpRow(
                label: $0.label, coordinate: $0.coordinate,
                sourceUnit: session.coordinateSpace.unit)
        }
        return (fiducials + electrodes).joined(separator: "\n")
    }

    /// BESA channel spherical-coordinate ELP: `EEG <label> <theta> <phi>`.
    /// Theta is azimuth in the XY plane (0 at +Y, positive toward +X); phi is
    /// elevation from the XY plane. Both values are degrees and radius-free.
    public static func elp(_ session: ScanSession) -> String {
        session.electrodes.map { electrode in
            let x = electrode.coordinate.x
            let y = electrode.coordinate.y
            let z = electrode.coordinate.z
            let theta = atan2(x, y) * 180 / .pi
            let phi = atan2(z, hypot(x, y)) * 180 / .pi
            return ["EEG", electrode.label, angleString(theta), angleString(phi)]
                .joined(separator: "\t")
        }.joined(separator: "\n")
    }

    public static func bidsElectrodesTSV(_ session: ScanSession) -> String {
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

    /// Required BIDS sidecar for the values returned by `bidsElectrodesTSV`.
    public static func bidsCoordinateSystemJSON(_ session: ScanSession) throws -> String {
        let payload: [String: String] = [
            "EEGCoordinateSystem": "Other",
            "EEGCoordinateSystemDescription": session.coordinateSpace.frame.rawValue,
            "EEGCoordinateUnits": bidsUnit(session.coordinateSpace.unit)
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// EGI `coordinates_mff` XML. Cartesian coordinates are always centimeters.
    public static func egiCoordinatesXML(_ session: ScanSession) -> String {
        let electrodeSensors = session.electrodes.enumerated().map { index, electrode in
            if electrode.label.caseInsensitiveCompare("Cz") == .orderedSame {
                return egiSensor(
                    name: session.layout.referenceLabel ?? "VREF",
                    number: session.layout.referenceSensor ?? session.layout.channelCount + 1,
                    type: 1, coordinate: electrode.coordinate,
                    sourceUnit: session.coordinateSpace.unit)
            }
            let number = Int(electrode.label.drop(while: { !$0.isNumber })) ?? index + 1
            return egiSensor(
                name: "", number: number, type: 0, coordinate: electrode.coordinate,
                sourceUnit: session.coordinateSpace.unit)
        }
        let fiducialSensors = session.fiducials.compactMap { fiducial -> String? in
            guard let coordinate = fiducial.coordinate else { return nil }
            let metadata: (String, Int)
            switch fiducial.kind {
            case .nasion: metadata = ("Nasion", 2002)
            case .leftPreauricular: metadata = ("Left periauricular point", 2011)
            case .rightPreauricular: metadata = ("Right periauricular point", 2010)
            case .vertex: return nil  // Cz is a reference electrode, not an EEG fiducial.
            }
            return egiSensor(
                name: metadata.0, number: metadata.1, type: 2, coordinate: coordinate,
                sourceUnit: session.coordinateSpace.unit)
        }
        let sensors = (electrodeSensors + fiducialSensors).joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
            <coordinates xmlns="http://www.egi.com/coordinates_mff" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                <sensorLayout>
                    <name>\(xmlEscaped(session.layout.name))</name>
                    <sensors>
            \(sensors)
                    </sensors>
                </sensorLayout>
                <acqMethod>MANTA LiDAR and photogrammetry</acqMethod>
                <defaultSubject>false</defaultSubject>
            </coordinates>
            """
    }

    private static func sfpRow(
        label: String, coordinate: Coordinate3D, sourceUnit: DistanceUnit
    ) -> String {
        let meters = coordinate.converted(from: sourceUnit, to: .meters)
        return [
            label, sfpCoordinateString(meters.x), sfpCoordinateString(meters.y),
            sfpCoordinateString(meters.z)
        ].joined(separator: "\t")
    }

    private static func sfpFiducialLabel(_ kind: FiducialKind) -> String {
        switch kind {
        case .nasion: "FidNz"
        case .leftPreauricular: "FidT9"
        case .rightPreauricular: "FidT10"
        case .vertex: "Cz"
        }
    }

    private static func bidsUnit(_ unit: DistanceUnit) -> String {
        switch unit {
        case .meters: "m"
        case .centimeters: "cm"
        case .millimeters: "mm"
        }
    }

    private static func egiSensor(
        name: String, number: Int, type: Int, coordinate: Coordinate3D, sourceUnit: DistanceUnit
    ) -> String {
        let centimeters = coordinate.converted(from: sourceUnit, to: .centimeters)
        return """
                        <sensor>
                            <name>\(xmlEscaped(name))</name>
                            <number>\(number)</number>
                            <type>\(type)</type>
                            <x>\(egiCoordinateString(centimeters.x))</x>
                            <y>\(egiCoordinateString(centimeters.y))</y>
                            <z>\(egiCoordinateString(centimeters.z))</z>
                        </sensor>
            """
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func coordinateString(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func sfpCoordinateString(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func angleString(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func egiCoordinateString(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
