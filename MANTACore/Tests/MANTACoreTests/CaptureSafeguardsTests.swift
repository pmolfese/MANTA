import Testing
@testable import MANTACore

struct CaptureSafeguardsTests {
    @Test func storageBoundariesAndRecovery() {
        let readings: [Int64?] = [4_000_000_000, 3_000_000_000, 2_999_999_999,
                                 1_000_000_001, 1_000_000_000, 0, nil, -1, 4_000_000_000]
        let expected: [CaptureStoragePolicy.State] = [.ready, .ready, .warning,
            .warning, .stop, .stop, .unavailable, .unavailable, .ready]
        #expect(readings.map { CaptureStoragePolicy.evaluate(availableBytes: $0) } == expected)
        #expect(expected.map(\.allowsCapture) == [true, true, true, true, false, false, false, false, true])
    }

    @Test func presetsCannotMislabelCustomSettings() {
        for preset in CapturePreset.allCases {
            #expect(CapturePreset.name(usesDepth: true, bestFrames: preset.selectsBestFrames,
                comparisonFrames: preset.savesComparisonFrames,
                highResolutionStills: preset.capturesHighResolutionStills) == preset.rawValue)
        }
        #expect(CapturePreset.name(usesDepth: false, bestFrames: false,
            comparisonFrames: false, highResolutionStills: false) == "Custom")
        #expect(CapturePreset.name(usesDepth: true, bestFrames: true,
            comparisonFrames: false, highResolutionStills: false) == "Custom")
    }
}
