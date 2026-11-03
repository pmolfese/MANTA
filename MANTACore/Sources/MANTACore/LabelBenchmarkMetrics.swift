import Foundation

public struct LabelBenchmarkMetrics: Codable, Equatable, Sendable {
    public let truePositives: [String]
    public let falsePositives: [String]
    public let falseNegatives: [String]
    public var precision: Double? {
        let total = truePositives.count + falsePositives.count
        return total == 0 ? nil : Double(truePositives.count) / Double(total)
    }
    public var recall: Double? {
        let total = truePositives.count + falseNegatives.count
        return total == 0 ? nil : Double(truePositives.count) / Double(total)
    }
    /// Exact numeric/E-prefixed tokens only; no layout or digit-confusion correction.
    public static func predictedLabels(from strings: [String], channelCount: Int) -> Set<String> {
        Set(strings.flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }.compactMap { raw in
            var token = String(raw).trimmingCharacters(in: .alphanumerics.inverted).uppercased()
            if token.hasPrefix("E") { token.removeFirst() }
            guard !token.isEmpty, token.allSatisfy(\.isNumber), let number = Int(token),
                  number >= 1, number <= channelCount else { return nil }
            return "E\(number)"
        })
    }

    public init(expected: Set<String>, predicted: Set<String>) {
        truePositives = expected.intersection(predicted).sorted()
        falsePositives = predicted.subtracting(expected).sorted()
        falseNegatives = expected.subtracting(predicted).sorted()
    }
}
