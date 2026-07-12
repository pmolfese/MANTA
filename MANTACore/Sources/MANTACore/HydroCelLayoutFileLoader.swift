import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum HydroCelLayoutLoaderError: LocalizedError, Sendable {
    case missingResource(String)
    case invalidMetadata
    case invalidXML(URL)
    case missingCoordinate(Int)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): "Missing layout resource: \(name)"
        case .invalidMetadata: "HydroCel layout metadata could not be decoded."
        case .invalidXML(let url): "Could not parse XML layout at \(url.lastPathComponent)."
        case .missingCoordinate(let number): "Missing 3D coordinate prior for electrode E\(number)."
        }
    }
}

/// Portable loader for a directory containing HydroCel metadata and EGI XML.
public struct HydroCelLayoutFileLoader {
    public var resourceDirectory: URL

    public init(resourceDirectory: URL) {
        self.resourceDirectory = resourceDirectory
    }

    public func loadLayouts() throws -> [ElectrodeLayout] {
        let metadataURL = resourceDirectory.appendingPathComponent("HydroCelLayoutMetadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw HydroCelLayoutLoaderError.missingResource("HydroCelLayoutMetadata.json")
        }
        let metadata: MetadataFile
        do {
            metadata = try JSONDecoder().decode(MetadataFile.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw HydroCelLayoutLoaderError.invalidMetadata
        }
        return try metadata.layouts.map { definition in
            let coordinatesURL = try resource(definition.coordinatesFile, extension: "xml")
            let layoutURL = try resource(definition.sensorLayoutFile, extension: "xml")
            let coordinates = try CoordinateParser(url: coordinatesURL).parse()
            let sensorLayout = try SensorLayoutParser(url: layoutURL).parse()
            let cardinals = Set(definition.cardinalSensors)
            let electrodes = try (1...definition.channelCount).map { number in
                guard let coordinate = coordinates.electrodes[number] else {
                    throw HydroCelLayoutLoaderError.missingCoordinate(number)
                }
                return ElectrodeDefinition(
                    number: number, label: "E\(number)",
                    role: cardinals.contains(number) ? .cardinal : .regular,
                    coordinatePrior: coordinate,
                    displayPosition: sensorLayout.positions[number],
                    neighbors: sensorLayout.neighbors[number, default: []]
                        .filter { $0 <= definition.channelCount }.sorted())
            }
            return ElectrodeLayout(
                id: definition.id, name: definition.name,
                channelCount: definition.channelCount, labels: electrodes.map(\.label),
                cardinalLabels: Set(definition.cardinalSensors.filter {
                    $0 <= definition.channelCount
                }.map { "E\($0)" }),
                electrodes: electrodes,
                fiducialCoordinatePriors: coordinates.fiducials,
                fiducialSensorHints: definition.fiducialSensorHints.reduce(into: [:]) {
                    if let kind = FiducialKind(metadataKey: $1.key) { $0[kind] = $1.value }
                },
                referenceSensor: definition.referenceSensor,
                referenceLabel: definition.referenceLabel)
        }
    }

    private func resource(_ name: String, extension suffix: String) throws -> URL {
        let url = resourceDirectory.appendingPathComponent("\(name).\(suffix)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HydroCelLayoutLoaderError.missingResource(url.lastPathComponent)
        }
        return url
    }
}

private struct MetadataFile: Decodable { var layouts: [MetadataDefinition] }
private struct MetadataDefinition: Decodable {
    var id: String
    var name: String
    var channelCount: Int
    var coordinatesFile: String
    var sensorLayoutFile: String
    var referenceSensor: Int?
    var referenceLabel: String?
    var cardinalSensors: [Int]
    var fiducialSensorHints: [String: Int]
}
private struct Coordinates {
    var electrodes = [Int: Coordinate3D]()
    var fiducials = [FiducialKind: Coordinate3D]()
}
private struct SensorLayout {
    var positions = [Int: Coordinate2D]()
    var neighbors = [Int: [Int]]()
}
private struct SensorText {
    var name = "", number = "", type = "", x = "", y = "", z = ""
}

private final class CoordinateParser: NSObject, XMLParserDelegate {
    let url: URL
    var element = "", sensor: SensorText?, result = Coordinates(), failed = false
    init(url: URL) { self.url = url }
    func parse() throws -> Coordinates {
        guard let parser = XMLParser(contentsOf: url) else {
            throw HydroCelLayoutLoaderError.invalidXML(url)
        }
        parser.delegate = self
        guard parser.parse(), !failed else { throw HydroCelLayoutLoaderError.invalidXML(url) }
        return result
    }
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        element = elementName
        if elementName == "sensor" { sensor = SensorText() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var sensor else { return }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch element {
        case "name": sensor.name += text
        case "number": sensor.number += text
        case "type": sensor.type += text
        case "x": sensor.x += text
        case "y": sensor.y += text
        case "z": sensor.z += text
        default: break
        }
        self.sensor = sensor
    }
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { element = "" }
        guard elementName == "sensor", let sensor,
              let number = Int(sensor.number), let type = Int(sensor.type),
              let x = Double(sensor.x), let y = Double(sensor.y), let z = Double(sensor.z)
        else {
            if elementName == "sensor" { failed = true }
            return
        }
        let coordinate = Coordinate3D(x: x, y: y, z: z)
        if type == 0 { result.electrodes[number] = coordinate }
        if type == 2, let kind = FiducialKind(coordinateName: sensor.name) {
            result.fiducials[kind] = coordinate
        }
        self.sensor = nil
    }
}

private final class SensorLayoutParser: NSObject, XMLParserDelegate {
    let url: URL
    var element = "", sensor: SensorText?, neighbor: Int?, result = SensorLayout(), failed = false
    init(url: URL) { self.url = url }
    func parse() throws -> SensorLayout {
        guard let parser = XMLParser(contentsOf: url) else {
            throw HydroCelLayoutLoaderError.invalidXML(url)
        }
        parser.delegate = self
        guard parser.parse(), !failed else { throw HydroCelLayoutLoaderError.invalidXML(url) }
        return result
    }
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        element = elementName
        if elementName == "sensor" { sensor = SensorText() }
        if elementName == "ch", let text = attributeDict["n"], let number = Int(text) {
            neighbor = number; result.neighbors[number] = []
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if element == "ch", let neighbor {
            result.neighbors[neighbor, default: []].append(
                contentsOf: text.split(separator: " ").compactMap { Int($0) })
            return
        }
        guard var sensor else { return }
        switch element {
        case "number": sensor.number += text
        case "type": sensor.type += text
        case "x": sensor.x += text
        case "y": sensor.y += text
        default: break
        }
        self.sensor = sensor
    }
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { element = "" }
        if elementName == "ch" { neighbor = nil }
        guard elementName == "sensor", let sensor, let number = Int(sensor.number),
              let type = Int(sensor.type), let x = Double(sensor.x), let y = Double(sensor.y)
        else {
            if elementName == "sensor" { failed = true }
            return
        }
        if type == 0 { result.positions[number] = Coordinate2D(x: x, y: y) }
        self.sensor = nil
    }
}

private extension FiducialKind {
    init?(coordinateName: String) {
        let value = coordinateName.lowercased()
        if value.contains("nasion") { self = .nasion }
        else if value.contains("left") && value.contains("periauricular") {
            self = .leftPreauricular
        } else if value.contains("right") && value.contains("periauricular") {
            self = .rightPreauricular
        } else { return nil }
    }
    init?(metadataKey: String) {
        switch metadataKey {
        case "nasion": self = .nasion
        case "leftPreauricular": self = .leftPreauricular
        case "rightPreauricular": self = .rightPreauricular
        default: return nil
        }
    }
}
