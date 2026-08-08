import XCTest
@testable import AudioControl

final class ConfigurationPacketTests: XCTestCase {
    func testConfigurationRoundTrip() throws {
        let expected = DSPConfiguration(
            revision: 42,
            delayMilliseconds: 137.5,
            lowPassHz: 92.4,
            outputGainDB: -6.25,
            delayEnabled: true,
            lowPassEnabled: false,
            dspBypassed: false,
            bassShelf: BassShelfConfiguration(
                enabled: true,
                transitionHz: 45,
                gainDB: 2.5
            )
        )

        let data = ConfigurationPacket.encode(expected)
        XCTAssertEqual(data.count, ConfigurationPacket.byteCount)
        XCTAssertEqual(try ConfigurationPacket.decode(data), expected)
    }

    func testConfigurationValuesAreClampedBeforeEncoding() throws {
        let source = DSPConfiguration(
            delayMilliseconds: 900,
            lowPassHz: 10,
            outputGainDB: 6,
            bassShelf: BassShelfConfiguration(
                transitionHz: 900,
                gainDB: -20
            )
        )

        let decoded = try ConfigurationPacket.decode(ConfigurationPacket.encode(source))
        XCTAssertEqual(decoded.delayMilliseconds, 250)
        XCTAssertEqual(decoded.lowPassHz, 40)
        XCTAssertEqual(decoded.outputGainDB, 0)
        XCTAssertEqual(decoded.bassShelf.transitionHz, 100)
        XCTAssertEqual(decoded.bassShelf.gainDB, -6)
    }

    func testAutomaticHeadroomAttenuationFitsWireRange() throws {
        let source = DSPConfiguration(outputGainDB: -30.5)
        let decoded = try ConfigurationPacket.decode(ConfigurationPacket.encode(source))
        XCTAssertEqual(decoded.outputGainDB, -30.5)
    }

    func testUnsupportedPacketVersionIsRejectedBeforeCRC() {
        var data = ConfigurationPacket.encode(DSPConfiguration())
        data[0] = 99
        XCTAssertThrowsError(try ConfigurationPacket.decode(data)) { error in
            XCTAssertEqual(error as? BLEPacketError, .unsupportedVersion(99))
        }
    }

    func testCorruptPacketIsRejected() {
        var data = ConfigurationPacket.encode(DSPConfiguration())
        data[12] ^= 1
        XCTAssertThrowsError(try ConfigurationPacket.decode(data)) { error in
            XCTAssertEqual(error as? BLEPacketError, .invalidChecksum)
        }
    }

    func testCanonicalFirmwareVector() {
        let configuration = DSPConfiguration(
            revision: 1,
            delayMilliseconds: 0,
            lowPassHz: 80,
            outputGainDB: 0,
            delayEnabled: false,
            lowPassEnabled: true,
            dspBypassed: false,
            bassShelf: BassShelfConfiguration(transitionHz: 40)
        )
        let expectedHex = """
        02 02 16 00 01 00 00 00 00 00 00 00 20 03 00 00
        90 01 00 00 bb 39
        """
        let expected = Data(expectedHex.split(whereSeparator: { $0.isWhitespace }).compactMap {
            UInt8($0, radix: 16)
        })
        XCTAssertEqual(ConfigurationPacket.encode(configuration), expected)
    }
}
