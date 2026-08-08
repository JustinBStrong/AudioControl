import XCTest
@testable import AudioControl

final class TelemetryPacketTests: XCTestCase {
    func testUnavailablePeakSentinelDecodesAsNil() throws {
        let bytes: [UInt8] = [
            2, 0b0010_0011, 20, 0,
            7, 0, 0, 0,
            0, 128, 0, 128, 0, 128, 0, 128,
            2, 0, 0, 0,
        ]
        let telemetry = try AudioTelemetry.decode(Data(bytes))
        XCTAssertTrue(telemetry.codecReady)
        XCTAssertTrue(telemetry.audioRunning)
        XCTAssertTrue(telemetry.settingsDirty)
        XCTAssertNil(telemetry.inputPeakLeftDBFS)
        XCTAssertNil(telemetry.outputPeakRightDBFS)
        XCTAssertEqual(telemetry.underrunCount, 2)
    }
}
