import CryptoKit
import Foundation
import Testing

struct EGICoordinateFixtureTests {
    @Test func EGIXMLAndDerivedSFPContainTheSameCoordinates() throws {
        let directory = fixtureDirectory()
        let xml = try FixtureEGIXMLParser(url: directory.appendingPathComponent("coordinates.xml")).parse()
        let sfp = try parseSFP(directory.appendingPathComponent("coordinates.sfp"))

        #expect(xml.count == 132)
        #expect(sfp.count == 132)
        #expect(Set(xml.keys) == Set(sfp.keys))

        let maximumDifference = try xml.keys.map { label in
            let left = try #require(xml[label])
            let right = try #require(sfp[label])
            return max(abs(left.x - right.x), abs(left.y - right.y), abs(left.z - right.z))
        }.max() ?? 0

        #expect(maximumDifference <= 0.0000051)
        #expect(xml["FidNz"] == FixtureCoordinate(x: 0, y: 9.001824, z: -2.378398))
        #expect(xml["Cz"] == FixtureCoordinate(x: 0, y: 0, z: 8.154996))
    }

    @Test func conversionMetadataTracksIncludedFixturesAndExcludesGeoScanSource() throws {
        let directory = fixtureDirectory()
        let metadataURL = directory.appendingPathComponent("ConversionMetadata.json")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        let artifacts = try #require(object["artifacts"] as? [String: Any])
        let source = try #require(artifacts["sourceGeoScan"] as? [String: Any])
        let conversion = try #require(object["coordinateConversion"] as? [String: Any])
        let correction = try #require(conversion["markerToSensorCorrection"] as? [String: Any])

        #expect(source["includedAsFixture"] as? Bool == false)
        #expect(correction["defaultDistanceCentimeters"] as? Double == 0.95)
        #expect(correction["overrideDistanceCentimeters"] as? Double == 1.25)
        #expect((correction["overrideElectrodes"] as? [Int]) == [64, 68, 69, 73, 74, 81, 82, 88, 89, 94, 95])

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries.sorted() == ["ConversionMetadata.json", "coordinates.sfp", "coordinates.xml"])
        #expect(sha256(directory.appendingPathComponent("coordinates.xml")) == "1e0c76b0639254c7d5e45df8f9f04f014734bc821f01f168271b44243a36d081")
        #expect(sha256(directory.appendingPathComponent("coordinates.sfp")) == "76ddcee813c1ac7385b9d115eda0dd532d3bfa80c1039a102bb3d18595ebc614")
    }

    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EGI/GeoScanDerived128", isDirectory: true)
    }

    private func parseSFP(_ url: URL) throws -> [String: FixtureCoordinate] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try Dictionary(uniqueKeysWithValues: text.split(whereSeparator: \.isNewline).map { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 4,
                  let x = Double(fields[1]),
                  let y = Double(fields[2]),
                  let z = Double(fields[3]) else {
                throw FixtureParseError.invalidSFPLine(String(line))
            }
            return (String(fields[0]), FixtureCoordinate(x: x, y: y, z: z))
        })
    }

    private func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct FixtureCoordinate: Equatable {
    var x: Double
    var y: Double
    var z: Double
}

private enum FixtureParseError: Error {
    case invalidXML
    case invalidSFPLine(String)
}

private final class FixtureEGIXMLParser: NSObject, XMLParserDelegate {
    private let url: URL
    private var currentElement = ""
    private var sensor: Sensor?
    private var result: [String: FixtureCoordinate] = [:]
    private var failed = false

    init(url: URL) {
        self.url = url
    }

    func parse() throws -> [String: FixtureCoordinate] {
        guard let parser = XMLParser(contentsOf: url) else { throw FixtureParseError.invalidXML }
        parser.delegate = self
        guard parser.parse(), !failed else { throw FixtureParseError.invalidXML }
        return result
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "sensor" { sensor = Sensor() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard var sensor else { return }
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch currentElement {
        case "name": sensor.name += value
        case "number": sensor.number += value
        case "type": sensor.type += value
        case "x": sensor.x += value
        case "y": sensor.y += value
        case "z": sensor.z += value
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
        defer { currentElement = "" }
        guard elementName == "sensor", let sensor,
              let number = Int(sensor.number),
              let type = Int(sensor.type),
              let x = Double(sensor.x),
              let y = Double(sensor.y),
              let z = Double(sensor.z) else { return }

        let label: String
        switch (type, sensor.name) {
        case (0, _): label = "E\(number)"
        case (1, "Vertex Reference"): label = "Cz"
        case (2, "Nasion"): label = "FidNz"
        case (2, "Left periauricular point"): label = "FidT9"
        case (2, "Right periauricular point"): label = "FidT10"
        default:
            failed = true
            return
        }
        result[label] = FixtureCoordinate(x: x, y: y, z: z)
        self.sensor = nil
    }

    private struct Sensor {
        var name = ""
        var number = ""
        var type = ""
        var x = ""
        var y = ""
        var z = ""
    }
}
