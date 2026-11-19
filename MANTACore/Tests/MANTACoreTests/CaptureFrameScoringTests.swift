import Testing
@testable import MANTACore

struct CaptureFrameScoringTests {
    @Test func prefersSharpStableNovelViews() {
        func score(_ sharp: Double, _ speed: Double = 0, _ translation: Double = 0.03) -> Double {
            CaptureFrameScoring.score(sharpness: sharp, angularSpeedDegrees: speed,
                                      translationMeters: translation, rotationDegrees: 0)
        }
        #expect(score(0.1) > score(0.01))
        #expect(score(0.1) > score(0.1, 90))
        #expect(score(0.1) > score(0.1, 0, 0))
        #expect(score(0.1, 0, 10) == score(0.1, 0, 0.03))
        #expect(score(.nan) == 0)
        #expect(score(-1) == 0)
    }
}
