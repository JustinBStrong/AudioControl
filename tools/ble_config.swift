import CoreBluetooth
import Foundation

private let serviceUUID = CBUUID(string: "7C1C0001-7A4D-4E6B-9D2A-5E4143554449")
private let configurationUUID = CBUUID(string: "7C1C0002-7A4D-4E6B-9D2A-5E4143554449")
private let commandUUID = CBUUID(string: "7C1C0004-7A4D-4E6B-9D2A-5E4143554449")

private struct RequestedChanges {
    var delayMilliseconds: Double?
    var trimDB: Double?
    var lowPassEnabled: Bool?
    var shelfEnabled: Bool?
    var bypassed: Bool?
}

private func parseArguments() -> RequestedChanges {
    var changes = RequestedChanges()
    var arguments = Array(CommandLine.arguments.dropFirst())
    func value(after option: String) -> String {
        guard !arguments.isEmpty else {
            fputs("Missing value after \(option)\n", stderr)
            exit(EXIT_FAILURE)
        }
        return arguments.removeFirst()
    }
    func onOff(_ value: String, option: String) -> Bool {
        if value == "on" { return true }
        if value == "off" { return false }
        fputs("\(option) requires on or off\n", stderr)
        exit(EXIT_FAILURE)
    }

    while !arguments.isEmpty {
        let option = arguments.removeFirst()
        switch option {
        case "--delay-ms":
            changes.delayMilliseconds = Double(value(after: option))
        case "--trim-db":
            changes.trimDB = Double(value(after: option))
        case "--low-pass":
            changes.lowPassEnabled = onOff(value(after: option), option: option)
        case "--shelf":
            changes.shelfEnabled = onOff(value(after: option), option: option)
        case "--bypass":
            changes.bypassed = onOff(value(after: option), option: option)
        default:
            fputs("Unknown option: \(option)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    return changes
}

private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readInt16(_ bytes: [UInt8], at offset: Int) -> Int16 {
    Int16(bitPattern: readUInt16(bytes, at: offset))
}

private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private func writeUInt16(_ value: UInt16, to bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
    for index in 0..<4 {
        bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
    }
}

private func crc16CcittFalse(_ bytes: ArraySlice<UInt8>) -> UInt16 {
    var crc: UInt16 = 0xffff
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

private final class ConfigurationWriter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let changes: RequestedChanges
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var configurationCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var expectedRevision: UInt32?
    private var wroteConfiguration = false
    private var receivedConfiguration = false
    private var receivedStatus = false
    private var finished = false

    init(changes: RequestedChanges) {
        self.changes = changes
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            self?.fail("timed out")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first else {
            fail("service discovery failed")
            return
        }
        peripheral.discoverCharacteristics([configurationUUID, commandUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            fail("characteristic discovery failed")
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == configurationUUID {
                configurationCharacteristic = characteristic
            } else if characteristic.uuid == commandUUID {
                commandCharacteristic = characteristic
            }
        }
        guard let configurationCharacteristic, let commandCharacteristic else {
            fail("protocol characteristics are missing")
            return
        }
        peripheral.setNotifyValue(true, for: configurationCharacteristic)
        peripheral.setNotifyValue(true, for: commandCharacteristic)
        peripheral.readValue(for: configurationCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else {
            fail("BLE read failed")
            return
        }
        if characteristic.uuid == commandUUID {
            let bytes = [UInt8](data)
            guard bytes.count == 8, bytes[1] == 0,
                  readUInt32(bytes, at: 4) == expectedRevision else {
                fail("firmware rejected the configuration")
                return
            }
            receivedStatus = true
            finishIfReady()
            return
        }
        guard characteristic.uuid == configurationUUID else { return }
        var bytes = [UInt8](data)
        guard bytes.count == 22, bytes[0] == 2,
              readUInt16(bytes, at: 2) == 22,
              readUInt16(bytes, at: 20) == crc16CcittFalse(bytes[0..<20]) else {
            fail("invalid configuration packet")
            return
        }

        if wroteConfiguration {
            guard readUInt32(bytes, at: 4) == expectedRevision else { return }
            receivedConfiguration = true
            finishIfReady()
            return
        }

        let oldRevision = readUInt32(bytes, at: 4)
        let oldDelay = Double(readUInt32(bytes, at: 8)) / 1000
        let oldTrim = Double(readInt16(bytes, at: 14)) / 100
        print(String(format: "Current revision=%u delay=%.3f ms trim=%.2f dB flags=0x%02x", oldRevision, oldDelay, oldTrim, bytes[1]))

        let revision = oldRevision &+ 1
        expectedRevision = revision
        writeUInt32(revision, to: &bytes, at: 4)
        if let delay = changes.delayMilliseconds {
            guard delay >= 0, delay <= 250 else { fail("delay must be 0...250 ms"); return }
            writeUInt32(UInt32((delay * 1000).rounded()), to: &bytes, at: 8)
            bytes[1] = delay > 0 ? bytes[1] | 0x01 : bytes[1] & ~0x01
        }
        if let trim = changes.trimDB {
            guard trim >= -36, trim <= 0 else { fail("trim must be -36...0 dB"); return }
            writeUInt16(UInt16(bitPattern: Int16((trim * 100).rounded())), to: &bytes, at: 14)
        }
        if let enabled = changes.lowPassEnabled {
            bytes[1] = enabled ? bytes[1] | 0x02 : bytes[1] & ~0x02
        }
        if let bypassed = changes.bypassed {
            bytes[1] = bypassed ? bytes[1] | 0x04 : bytes[1] & ~0x04
        }
        if let enabled = changes.shelfEnabled {
            bytes[1] = enabled ? bytes[1] | 0x08 : bytes[1] & ~0x08
        }
        let crc = crc16CcittFalse(bytes[0..<20])
        writeUInt16(crc, to: &bytes, at: 20)
        guard let configurationCharacteristic else {
            fail("configuration characteristic disappeared")
            return
        }
        wroteConfiguration = true
        peripheral.writeValue(Data(bytes), for: configurationCharacteristic, type: .withResponse)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { fail("BLE write failed: \(error.localizedDescription)") }
    }

    private func finishIfReady() {
        guard receivedConfiguration, receivedStatus, let revision = expectedRevision else { return }
        finished = true
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        print("Applied revision \(revision)")
        exit(EXIT_SUCCESS)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private let writer = ConfigurationWriter(changes: parseArguments())
RunLoop.main.run()
