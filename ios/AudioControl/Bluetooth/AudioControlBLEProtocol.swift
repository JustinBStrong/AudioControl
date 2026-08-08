import CoreBluetooth
import Foundation

enum AudioControlBLEProtocol {
    static let serviceUUIDString = "7C1C0001-7A4D-4E6B-9D2A-5E4143554449"
    static let configurationUUIDString = "7C1C0002-7A4D-4E6B-9D2A-5E4143554449"
    static let telemetryUUIDString = "7C1C0003-7A4D-4E6B-9D2A-5E4143554449"
    static let commandUUIDString = "7C1C0004-7A4D-4E6B-9D2A-5E4143554449"

    static var serviceUUID: CBUUID { CBUUID(string: serviceUUIDString) }
    static var configurationUUID: CBUUID { CBUUID(string: configurationUUIDString) }
    static var telemetryUUID: CBUUID { CBUUID(string: telemetryUUIDString) }
    static var commandUUID: CBUUID { CBUUID(string: commandUUIDString) }
    static let packetVersion: UInt8 = 2
}

enum BLEPacketError: Error, Equatable {
    case incorrectLength(expected: Int, actual: Int)
    case unsupportedVersion(UInt8)
    case invalidDeclaredSize(UInt16)
    case invalidChecksum
    case valueOutOfRange(String)
}

struct ConfigurationPacket {
    static let byteCount = 22

    static func encode(_ rawConfiguration: DSPConfiguration) -> Data {
        let configuration = rawConfiguration.normalized()
        var flags: UInt8 = 0
        if configuration.delayEnabled { flags |= 1 << 0 }
        if configuration.lowPassEnabled { flags |= 1 << 1 }
        if configuration.dspBypassed { flags |= 1 << 2 }
        if configuration.bassShelf.enabled { flags |= 1 << 3 }

        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        bytes.append(AudioControlBLEProtocol.packetVersion)
        bytes.append(flags)
        bytes.append(contentsOf: UInt16(byteCount).littleEndianBytes)
        bytes.append(contentsOf: configuration.revision.littleEndianBytes)
        bytes.append(contentsOf: UInt32((configuration.delayMilliseconds * 1_000).rounded()).littleEndianBytes)
        bytes.append(contentsOf: UInt16((configuration.lowPassHz * 10).rounded()).littleEndianBytes)
        bytes.append(contentsOf: Int16((configuration.outputGainDB * 100).rounded()).littleEndianBytes)

        bytes.append(contentsOf: UInt16((configuration.bassShelf.transitionHz * 10).rounded()).littleEndianBytes)
        bytes.append(contentsOf: Int16((configuration.bassShelf.gainDB * 100).rounded()).littleEndianBytes)

        bytes.append(contentsOf: crc16CCITTFalse(bytes).littleEndianBytes)
        return Data(bytes)
    }

    static func decode(_ data: Data) throws -> DSPConfiguration {
        let bytes = [UInt8](data)
        try validateHeader(bytes, expectedSize: byteCount)
        let expectedCRC = UInt16(littleEndianBytes: bytes[20..<22])
        guard crc16CCITTFalse(Array(bytes[0..<20])) == expectedCRC else {
            throw BLEPacketError.invalidChecksum
        }

        let flags = bytes[1]
        guard flags & 0b1111_0000 == 0 else { throw BLEPacketError.valueOutOfRange("flags") }

        let delayUs = UInt32(littleEndianBytes: bytes[8..<12])
        let cutoffTenths = UInt16(littleEndianBytes: bytes[12..<14])
        let gainCentibels = Int16(littleEndianBytes: bytes[14..<16])
        guard delayUs <= 250_000 else { throw BLEPacketError.valueOutOfRange("delay_us") }
        guard (400...1_600).contains(cutoffTenths) else { throw BLEPacketError.valueOutOfRange("cutoff_deci_hz") }
        guard (-3_600...0).contains(gainCentibels) else { throw BLEPacketError.valueOutOfRange("output_trim_centi_db") }

        let shelfTransitionTenths = UInt16(littleEndianBytes: bytes[16..<18])
        let shelfGainHundredths = Int16(littleEndianBytes: bytes[18..<20])
        guard (200...1_000).contains(shelfTransitionTenths) else {
            throw BLEPacketError.valueOutOfRange("shelf_transition")
        }
        guard (-600...600).contains(shelfGainHundredths) else {
            throw BLEPacketError.valueOutOfRange("shelf_gain")
        }

        return DSPConfiguration(
            revision: UInt32(littleEndianBytes: bytes[4..<8]),
            delayMilliseconds: Double(delayUs) / 1_000,
            lowPassHz: Double(cutoffTenths) / 10,
            outputGainDB: Double(gainCentibels) / 100,
            delayEnabled: flags & (1 << 0) != 0,
            lowPassEnabled: flags & (1 << 1) != 0,
            dspBypassed: flags & (1 << 2) != 0,
            bassShelf: BassShelfConfiguration(
                enabled: flags & (1 << 3) != 0,
                transitionHz: Double(shelfTransitionTenths) / 10,
                gainDB: Double(shelfGainHundredths) / 100
            )
        )
    }
}

struct AudioTelemetry: Equatable, Sendable {
    static let byteCount = 20

    let codecReady: Bool
    let audioRunning: Bool
    let inputClipped: Bool
    let outputClipped: Bool
    let underrunDetected: Bool
    let settingsDirty: Bool
    let configurationRevision: UInt32
    let inputPeakLeftDBFS: Double?
    let inputPeakRightDBFS: Double?
    let outputPeakLeftDBFS: Double?
    let outputPeakRightDBFS: Double?
    let underrunCount: UInt32

    static func decode(_ data: Data) throws -> AudioTelemetry {
        let bytes = [UInt8](data)
        try validateHeader(bytes, expectedSize: byteCount)
        let flags = bytes[1]
        guard flags & 0b1100_0000 == 0 else { throw BLEPacketError.valueOutOfRange("telemetry_flags") }
        return AudioTelemetry(
            codecReady: flags & (1 << 0) != 0,
            audioRunning: flags & (1 << 1) != 0,
            inputClipped: flags & (1 << 2) != 0,
            outputClipped: flags & (1 << 3) != 0,
            underrunDetected: flags & (1 << 4) != 0,
            settingsDirty: flags & (1 << 5) != 0,
            configurationRevision: UInt32(littleEndianBytes: bytes[4..<8]),
            inputPeakLeftDBFS: decodePeak(bytes[8..<10]),
            inputPeakRightDBFS: decodePeak(bytes[10..<12]),
            outputPeakLeftDBFS: decodePeak(bytes[12..<14]),
            outputPeakRightDBFS: decodePeak(bytes[14..<16]),
            underrunCount: UInt32(littleEndianBytes: bytes[16..<20])
        )
    }
}

private func decodePeak<C: Collection>(_ bytes: C) -> Double? where C.Element == UInt8 {
    let value = Int16(littleEndianBytes: bytes)
    return value == .min ? nil : Double(value) / 100
}

enum DeviceCommand: UInt8, Sendable {
    case save = 1
    case restoreDefaults = 2
    case reboot = 3
    case clearClip = 4
}

struct CommandPacket {
    static let byteCount = 8

    static func encode(_ command: DeviceCommand, requestID: UInt32) -> Data {
        var bytes: [UInt8] = [AudioControlBLEProtocol.packetVersion, command.rawValue]
        bytes.append(contentsOf: UInt16(byteCount).littleEndianBytes)
        bytes.append(contentsOf: requestID.littleEndianBytes)
        return Data(bytes)
    }
}

struct CommandStatus: Equatable, Sendable {
    let status: UInt8
    let requestID: UInt32

    static func decode(_ data: Data) throws -> CommandStatus {
        let bytes = [UInt8](data)
        try validateHeader(bytes, expectedSize: CommandPacket.byteCount)
        return CommandStatus(
            status: bytes[1],
            requestID: UInt32(littleEndianBytes: bytes[4..<8])
        )
    }
}

private func validateHeader(_ bytes: [UInt8], expectedSize: Int) throws {
    guard bytes.count == expectedSize else {
        throw BLEPacketError.incorrectLength(expected: expectedSize, actual: bytes.count)
    }
    guard bytes[0] == AudioControlBLEProtocol.packetVersion else {
        throw BLEPacketError.unsupportedVersion(bytes[0])
    }
    let declared = UInt16(littleEndianBytes: bytes[2..<4])
    guard declared == expectedSize else { throw BLEPacketError.invalidDeclaredSize(declared) }
}

private func crc16CCITTFalse(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }

    init<C: Collection>(littleEndianBytes bytes: C) where C.Element == UInt8 {
        self = bytes.enumerated().reduce(0) { partial, element in
            partial | (Self(element.element) << (element.offset * 8))
        }
    }
}
