import XCTest
@testable import AudioControl

final class DSPResponseTests: XCTestCase {
    func testFlatConfigurationNeedsNoAutomaticHeadroom() {
        var configuration = DSPConfiguration()
        configuration.lowPassEnabled = false
        XCTAssertEqual(DSPResponseAnalyzer.peakBoostDB(for: configuration), 0, accuracy: 0.001)
        XCTAssertEqual(DSPResponseAnalyzer.automaticHeadroomDB(for: configuration), 0)
    }

    func testSixDecibelShelfGetsHeadroomAndSafetyMargin() {
        var configuration = DSPConfiguration()
        configuration.lowPassEnabled = false
        configuration.bassShelf = BassShelfConfiguration(
            enabled: true,
            transitionHz: 40,
            gainDB: 6
        )

        let peak = DSPResponseAnalyzer.peakBoostDB(for: configuration)
        let headroom = DSPResponseAnalyzer.automaticHeadroomDB(for: configuration)
        XCTAssertEqual(peak, 6, accuracy: 0.02)
        XCTAssertEqual(headroom, -6.5, accuracy: 0.02)
        XCTAssertLessThanOrEqual(peak + headroom, -0.49)
    }

    func testLowShelfUsesGainBelowTransitionAndHalfGainAtTransition() {
        var configuration = DSPConfiguration()
        configuration.lowPassEnabled = false
        configuration.bassShelf = BassShelfConfiguration(
            enabled: true,
            transitionHz: 50,
            gainDB: 6
        )

        XCTAssertEqual(
            DSPResponseAnalyzer.responseDB(for: configuration, at: 5),
            6,
            accuracy: 0.03
        )
        XCTAssertEqual(
            DSPResponseAnalyzer.responseDB(for: configuration, at: 50),
            3,
            accuracy: 0.03
        )
        XCTAssertEqual(DSPResponseAnalyzer.peakBoostDB(for: configuration), 6, accuracy: 0.03)
        XCTAssertEqual(DSPResponseAnalyzer.automaticHeadroomDB(for: configuration), -6.5)
    }

    func testLowPassCurveMatchesLinkwitzRileyCutoff() {
        var configuration = DSPConfiguration()
        configuration.lowPassEnabled = true
        configuration.lowPassHz = 80
        XCTAssertEqual(
            DSPResponseAnalyzer.responseDB(for: configuration, at: 80),
            -6.02,
            accuracy: 0.05
        )
    }
}
