import XCTest
@testable import AudioControl

final class ToneControlModelTests: XCTestCase {
    func testDefaultsMatchSafeGainSetupTone() {
        let model = ToneControlModel()
        XCTAssertEqual(model.frequencyHz, 40)
        XCTAssertEqual(model.frequencyText, "40")
        XCTAssertEqual(model.levelDBFS, 0)
    }

    func testSliderAndTextStaySynchronized() {
        var model = ToneControlModel()
        model.setFrequencyFromSlider(73.5)
        XCTAssertEqual(model.frequencyHz, 73.5)
        XCTAssertEqual(model.frequencyText, "73.5")

        model.setFrequencyText("91.2")
        XCTAssertEqual(model.frequencyHz, 91.2, accuracy: 0.001)
        model.commitFrequencyText()
        XCTAssertEqual(model.frequencyText, "91.2")
    }

    func testFrequencyIsClampedToSubwooferRange() {
        var model = ToneControlModel()
        model.setFrequencyText("1000")
        XCTAssertEqual(model.frequencyHz, 200)
        model.commitFrequencyText()
        XCTAssertEqual(model.frequencyText, "200")
    }

    func testInvalidPartialTextDoesNotChangeFrequency() {
        var model = ToneControlModel()
        model.setFrequencyText(".")
        XCTAssertEqual(model.frequencyHz, 40)
        XCTAssertEqual(model.frequencyText, ".")
        model.commitFrequencyText()
        XCTAssertEqual(model.frequencyText, "40")
    }
}
