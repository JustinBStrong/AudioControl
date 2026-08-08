import CoreBluetooth
import Foundation

private let serviceUUID = CBUUID(string: "7C1C0001-7A4D-4E6B-9D2A-5E4143554449")
private let configurationUUID = CBUUID(string: "7C1C0002-7A4D-4E6B-9D2A-5E4143554449")
private let telemetryUUID = CBUUID(string: "7C1C0003-7A4D-4E6B-9D2A-5E4143554449")
private let commandUUID = CBUUID(string: "7C1C0004-7A4D-4E6B-9D2A-5E4143554449")

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

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private final class SmokeTest: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private enum Stage {
        case discovering
        case readingInitial
        case waitingForWrite
        case waitingForPersistence
        case readingFinal
        case finished
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var configurationCharacteristic: CBCharacteristic?
    private var telemetryCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var stage: Stage = .discovering
    private var expectedRevision: UInt32?
    private var gotFinalConfiguration = false
    private var gotFinalTelemetry = false
    private var finalTelemetryHealthy = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        // Production requests a quiet one-second BLE connection interval to
        // keep radio bursts out of the codec input. Allow enough time for the
        // intentionally low-duty-cycle GATT round trip and persistence check.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard self?.stage != .finished else { return }
            self?.fail("timed out")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                fail("Bluetooth unavailable (state \(central.state.rawValue))")
            }
            return
        }
        print("Scanning for AudioControl…")
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
        print("Found \(peripheral.name ?? "AudioControl") at \(RSSI) dBm")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected; discovering protocol v2 service")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        fail("connection failed: \(error?.localizedDescription ?? "unknown error")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first else {
            fail("service discovery failed: \(error?.localizedDescription ?? "service missing")")
            return
        }
        peripheral.discoverCharacteristics(
            [configurationUUID, telemetryUUID, commandUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else {
            fail("characteristic discovery failed: \(error?.localizedDescription ?? "missing")")
            return
        }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case configurationUUID:
                configurationCharacteristic = characteristic
            case telemetryUUID:
                telemetryCharacteristic = characteristic
            case commandUUID:
                commandCharacteristic = characteristic
            default:
                break
            }
        }
        guard
            let configurationCharacteristic,
            let telemetryCharacteristic,
            let commandCharacteristic
        else {
            fail("one or more protocol characteristics are missing")
            return
        }

        peripheral.setNotifyValue(true, for: configurationCharacteristic)
        peripheral.setNotifyValue(true, for: telemetryCharacteristic)
        peripheral.setNotifyValue(true, for: commandCharacteristic)
        stage = .readingInitial
        peripheral.readValue(for: configurationCharacteristic)
        peripheral.readValue(for: telemetryCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            fail("read/notification failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case configurationUUID:
            handleConfiguration(data, peripheral: peripheral, characteristic: characteristic)
        case telemetryUUID:
            handleTelemetry(data)
        case commandUUID:
            handleStatus(data)
        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == configurationUUID else { return }
        if let error {
            fail("configuration write failed: \(error.localizedDescription)")
            return
        }
        print("GATT write completed with response")
        stage = .waitingForPersistence
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self, weak peripheral] in
            guard
                let self,
                let peripheral,
                let configurationCharacteristic = self.configurationCharacteristic,
                let telemetryCharacteristic = self.telemetryCharacteristic
            else { return }
            self.stage = .readingFinal
            peripheral.readValue(for: configurationCharacteristic)
            peripheral.readValue(for: telemetryCharacteristic)
        }
    }

    private func handleConfiguration(
        _ data: Data,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        var bytes = [UInt8](data)
        guard bytes.count == 22, bytes[0] == 2, readUInt16(bytes, at: 2) == 22 else {
            fail("malformed configuration packet: \(hex(data))")
            return
        }
        let computedCRC = crc16CcittFalse(bytes[0..<20])
        guard computedCRC == readUInt16(bytes, at: 20) else {
            fail("configuration CRC mismatch")
            return
        }

        let revision = readUInt32(bytes, at: 4)
        switch stage {
        case .readingInitial:
            print("Initial configuration revision \(revision): \(hex(data))")
            let nextRevision = revision &+ 1
            expectedRevision = nextRevision
            writeUInt32(nextRevision, to: &bytes, at: 4)
            let crc = crc16CcittFalse(bytes[0..<20])
            bytes[20] = UInt8(truncatingIfNeeded: crc)
            bytes[21] = UInt8(truncatingIfNeeded: crc >> 8)
            stage = .waitingForWrite
            peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
            print("Writing identical DSP settings as revision \(nextRevision)")
        case .waitingForWrite, .waitingForPersistence:
            print("Firmware published authoritative revision \(revision)")
        case .readingFinal:
            guard revision == expectedRevision else {
                fail("expected saved revision \(expectedRevision ?? 0), got \(revision)")
                return
            }
            print("Final configuration revision \(revision) read back correctly")
            gotFinalConfiguration = true
            finishIfReady()
        case .discovering, .finished:
            break
        }
    }

    private func handleTelemetry(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == 20, bytes[0] == 2, readUInt16(bytes, at: 2) == 20 else {
            fail("malformed telemetry packet: \(hex(data))")
            return
        }
        let flags = bytes[1]
        let revision = readUInt32(bytes, at: 4)
        let inputLeft = Double(readInt16(bytes, at: 8)) / 100
        let inputRight = Double(readInt16(bytes, at: 10)) / 100
        let outputLeft = Double(readInt16(bytes, at: 12)) / 100
        let outputRight = Double(readInt16(bytes, at: 14)) / 100
        let underruns = readUInt32(bytes, at: 16)
        let ready = flags & 0x01 != 0
        let running = flags & 0x02 != 0
        let dirty = flags & 0x20 != 0
        print(
            "Telemetry revision=\(revision) codec=\(ready) audio=\(running) "
                + "dirty=\(dirty) underruns=\(underruns) "
                + String(format: "in=[%.2f, %.2f] dBFS out=[%.2f, %.2f] dBFS", inputLeft, inputRight, outputLeft, outputRight)
        )
        if stage == .readingFinal {
            finalTelemetryHealthy = ready && running && !dirty && underruns == 0
            gotFinalTelemetry = true
            finishIfReady()
        }
    }

    private func handleStatus(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == 8 else {
            fail("malformed command status: \(hex(data))")
            return
        }
        let status = bytes[1]
        let requestID = readUInt32(bytes, at: 4)
        print("Firmware status=\(status) request/revision=\(requestID)")
        if status != 0 {
            fail("firmware rejected request with status \(status)")
        }
    }

    private func finishIfReady() {
        guard gotFinalConfiguration, gotFinalTelemetry else { return }
        guard finalTelemetryHealthy else {
            fail("final telemetry was not healthy")
            return
        }
        stage = .finished
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        print("PASS: BLE read/write/acknowledgement, live audio status, and deferred persistence")
        exit(EXIT_SUCCESS)
    }

    private func fail(_ message: String) {
        guard stage != .finished else { return }
        stage = .finished
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private let smokeTest = SmokeTest()
RunLoop.main.run()
