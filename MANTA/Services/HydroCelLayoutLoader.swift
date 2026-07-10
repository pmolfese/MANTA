//
//  HydroCelLayoutLoader.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation

enum HydroCelLayoutLoaderError: LocalizedError {
    case missingResource(String)
    case invalidMetadata
    case invalidXML(URL)
    case missingCoordinate(Int)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "Missing layout resource: \(name)"
        case .invalidMetadata:
            return "HydroCel layout metadata could not be decoded."
        case .invalidXML(let url):
            return "Could not parse XML layout at \(url.lastPathComponent)."
        case .missingCoordinate(let number):
            return "Missing 3D coordinate prior for electrode E\(number)."
        }
    }
}

struct HydroCelLayoutLoader {
    private let resourceDirectory: URL?
    private let bundle: Bundle

    init(resourceDirectory: URL? = nil, bundle: Bundle = .main) {
        self.resourceDirectory = resourceDirectory
        self.bundle = bundle
    }

    func loadLayouts() throws -> [ElectrodeLayout] {
        let metadata = try loadMetadata()

        return try metadata.layouts.map { definition in
            let coordinateURL = try resourceURL(named: definition.coordinatesFile, extension: "xml")
            let sensorLayoutURL = try resourceURL(named: definition.sensorLayoutFile, extension: "xml")
            let coordinates = try EGI3DCoordinateParser(url: coordinateURL).parse()
            let sensorLayout = try EGI2DSensorLayoutParser(url: sensorLayoutURL).parse()
            let cardinalNumbers = Set(definition.cardinalSensors)
            let cardinalLabels = Set(definition.cardinalSensors.filter { $0 <= definition.channelCount }.map { "E\($0)" })
            let fiducialHints = definition.fiducialSensorHints.compactMapKeys(FiducialKind.init(metadataKey:))

            let electrodes = try (1...definition.channelCount).map { number in
                guard let coordinate = coordinates.electrodeCoordinates[number] else {
                    throw HydroCelLayoutLoaderError.missingCoordinate(number)
                }

                return ElectrodeDefinition(
                    number: number,
                    label: "E\(number)",
                    role: cardinalNumbers.contains(number) ? .cardinal : .regular,
                    coordinatePrior: coordinate,
                    displayPosition: sensorLayout.displayPositions[number],
                    neighbors: sensorLayout.neighbors[number, default: []].filter { $0 <= definition.channelCount }.sorted()
                )
            }

            return ElectrodeLayout(
                name: definition.name,
                channelCount: definition.channelCount,
                labels: electrodes.map(\.label),
                cardinalLabels: cardinalLabels,
                electrodes: electrodes,
                fiducialCoordinatePriors: coordinates.fiducials,
                fiducialSensorHints: fiducialHints,
                referenceSensor: definition.referenceSensor,
                referenceLabel: definition.referenceLabel
            )
        }
    }

    private func loadMetadata() throws -> HydroCelMetadataFile {
        let url = try resourceURL(named: "HydroCelLayoutMetadata", extension: "json")
        let data = try Data(contentsOf: url)

        do {
            return try JSONDecoder().decode(HydroCelMetadataFile.self, from: data)
        } catch {
            throw HydroCelLayoutLoaderError.invalidMetadata
        }
    }

    private func resourceURL(named name: String, extension fileExtension: String) throws -> URL {
        if let resourceDirectory {
            let url = resourceDirectory.appendingPathComponent("\(name).\(fileExtension)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Layouts") {
            return url
        }

        if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources/Layouts") {
            return url
        }

        if let url = bundle.url(forResource: name, withExtension: fileExtension) {
            return url
        }

        throw HydroCelLayoutLoaderError.missingResource("\(name).\(fileExtension)")
    }
}

private struct HydroCelMetadataFile: Decodable {
    var layouts: [HydroCelMetadataDefinition]
}

private struct HydroCelMetadataDefinition: Decodable {
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

private struct Parsed3DCoordinates {
    var electrodeCoordinates: [Int: Coordinate3D]
    var fiducials: [FiducialKind: Coordinate3D]
}

private struct Parsed2DSensorLayout {
    var displayPositions: [Int: Coordinate2D]
    var neighbors: [Int: [Int]]
}

private final class EGI3DCoordinateParser: NSObject, XMLParserDelegate {
    private let url: URL
    private var currentElement = ""
    private var currentSensor: SensorAccumulator?
    private var coordinates: [Int: Coordinate3D] = [:]
    private var fiducials: [FiducialKind: Coordinate3D] = [:]
    private var didFail = false

    init(url: URL) {
        self.url = url
    }

    func parse() throws -> Parsed3DCoordinates {
        guard let parser = XMLParser(contentsOf: url) else {
            throw HydroCelLayoutLoaderError.invalidXML(url)
        }

        parser.delegate = self
        if parser.parse(), !didFail {
            return Parsed3DCoordinates(electrodeCoordinates: coordinates, fiducials: fiducials)
        }

        throw HydroCelLayoutLoaderError.invalidXML(url)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "sensor" {
            currentSensor = SensorAccumulator()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var sensor = currentSensor else {
            return
        }

        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }

        switch currentElement {
        case "name":
            sensor.name += value
        case "number":
            sensor.numberText += value
        case "type":
            sensor.typeText += value
        case "x":
            sensor.xText += value
        case "y":
            sensor.yText += value
        case "z":
            sensor.zText += value
        default:
            break
        }

        currentSensor = sensor
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "sensor" {
            commitCurrentSensor()
            currentSensor = nil
        }

        currentElement = ""
    }

    private func commitCurrentSensor() {
        guard
            let sensor = currentSensor,
            let number = Int(sensor.numberText),
            let type = Int(sensor.typeText),
            let x = Double(sensor.xText),
            let y = Double(sensor.yText),
            let z = Double(sensor.zText)
        else {
            didFail = true
            return
        }

        let coordinate = Coordinate3D(x: x, y: y, z: z)
        if type == 0 {
            coordinates[number] = coordinate
        } else if type == 2, let kind = FiducialKind(coordinateName: sensor.name) {
            fiducials[kind] = coordinate
        }
    }
}

private final class EGI2DSensorLayoutParser: NSObject, XMLParserDelegate {
    private let url: URL
    private var currentElement = ""
    private var currentSensor: SensorAccumulator?
    private var currentNeighborNumber: Int?
    private var displayPositions: [Int: Coordinate2D] = [:]
    private var neighbors: [Int: [Int]] = [:]
    private var didFail = false

    init(url: URL) {
        self.url = url
    }

    func parse() throws -> Parsed2DSensorLayout {
        guard let parser = XMLParser(contentsOf: url) else {
            throw HydroCelLayoutLoaderError.invalidXML(url)
        }

        parser.delegate = self
        if parser.parse(), !didFail {
            return Parsed2DSensorLayout(displayPositions: displayPositions, neighbors: neighbors)
        }

        throw HydroCelLayoutLoaderError.invalidXML(url)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "sensor" {
            currentSensor = SensorAccumulator()
        } else if elementName == "ch", let n = attributeDict["n"], let number = Int(n) {
            neighbors[number] = []
            currentNeighborNumber = number
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }

        if currentElement == "ch", let currentNeighborNumber {
            neighbors[currentNeighborNumber, default: []].append(contentsOf: value.split(separator: " ").compactMap { Int($0) })
            return
        }

        guard var sensor = currentSensor else {
            return
        }

        switch currentElement {
        case "number":
            sensor.numberText += value
        case "type":
            sensor.typeText += value
        case "x":
            sensor.xText += value
        case "y":
            sensor.yText += value
        default:
            break
        }

        currentSensor = sensor
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "sensor" {
            commitCurrentSensor()
            currentSensor = nil
        } else if elementName == "ch" {
            currentNeighborNumber = nil
        }

        currentElement = ""
    }

    private func commitCurrentSensor() {
        guard
            let sensor = currentSensor,
            let number = Int(sensor.numberText),
            let type = Int(sensor.typeText),
            let x = Double(sensor.xText),
            let y = Double(sensor.yText)
        else {
            didFail = true
            return
        }

        if type == 0 {
            displayPositions[number] = Coordinate2D(x: x, y: y)
        }
    }
}

private struct SensorAccumulator {
    var name = ""
    var numberText = ""
    var typeText = ""
    var xText = ""
    var yText = ""
    var zText = ""
}

private extension FiducialKind {
    nonisolated init?(coordinateName: String) {
        let normalized = coordinateName.lowercased()
        if normalized.contains("nasion") {
            self = .nasion
        } else if normalized.contains("left") && normalized.contains("periauricular") {
            self = .leftPreauricular
        } else if normalized.contains("right") && normalized.contains("periauricular") {
            self = .rightPreauricular
        } else {
            return nil
        }
    }

    nonisolated init?(metadataKey: String) {
        switch metadataKey {
        case "nasion":
            self = .nasion
        case "leftPreauricular":
            self = .leftPreauricular
        case "rightPreauricular":
            self = .rightPreauricular
        default:
            return nil
        }
    }
}

private extension Dictionary {
    func compactMapKeys<NewKey: Hashable>(_ transform: (Key) -> NewKey?) -> [NewKey: Value] {
        reduce(into: [NewKey: Value]()) { result, item in
            guard let key = transform(item.key) else {
                return
            }

            result[key] = item.value
        }
    }
}
