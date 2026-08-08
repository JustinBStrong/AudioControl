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

private final class TelemetryMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var finished = false
    private var sampleCount = 0
    private let duration: TimeInterval
    private let clearIndicators: Bool

    init(duration: TimeInterval, clearIndicators: Bool) {
        self.duration = duration
        self.clearIndicators = clearIndicators
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 15) { [weak self] in
            guard self?.sampleCount == 0 else { return }
            self?.finish("FAIL: no telemetry received", status: EXIT_FAILURE)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                finish("FAIL: Bluetooth unavailable (state \(central.state.rawValue))", status: EXIT_FAILURE)
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
        print("Connected; monitoring \(Int(duration)) seconds of live telemetry")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        finish("FAIL: connection failed: \(error?.localizedDescription ?? "unknown error")", status: EXIT_FAILURE)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first else {
            finish("FAIL: service discovery failed", status: EXIT_FAILURE)
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
        guard
            error == nil,
            let telemetry = service.characteristics?.first(where: { $0.uuid == telemetryUUID })
        else {
            finish("FAIL: telemetry characteristic missing", status: EXIT_FAILURE)
            return
        }

        if let configuration = service.characteristics?.first(where: { $0.uuid == configurationUUID }) {
            peripheral.readValue(for: configuration)
        }
        if clearIndicators,
           let command = service.characteristics?.first(where: { $0.uuid == commandUUID }) {
            // Protocol v2, ClearClip opcode, 8-byte packet, request ID "TEST".
            peripheral.writeValue(
                Data([2, 4, 8, 0, 0x54, 0x45, 0x53, 0x54]),
                for: command,
                type: .withResponse
            )
            print("Clearing latched clip and underrun indicators…")
        }
        peripheral.setNotifyValue(true, for: telemetry)
        peripheral.readValue(for: telemetry)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            self.finish(
                self.sampleCount > 0 ? "PASS: received \(self.sampleCount) telemetry samples" : "FAIL: no telemetry received",
                status: self.sampleCount > 0 ? EXIT_SUCCESS : EXIT_FAILURE
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        if characteristic.uuid == configurationUUID {
            printConfiguration(bytes)
            return
        }
        guard bytes.count == 20, bytes[0] == 2, readUInt16(bytes, at: 2) == 20 else { return }

        sampleCount += 1
        let flags = bytes[1]
        let revision = readUInt32(bytes, at: 4)
        let inputLeft = Double(readInt16(bytes, at: 8)) / 100
        let inputRight = Double(readInt16(bytes, at: 10)) / 100
        let outputLeft = Double(readInt16(bytes, at: 12)) / 100
        let outputRight = Double(readInt16(bytes, at: 14)) / 100
        let underruns = readUInt32(bytes, at: 16)

        print(
            String(
                format: "rev=%u in=[%7.2f, %7.2f] dBFS  out=[%7.2f, %7.2f] dBFS  clip(in/out)=%d/%d underruns=%u",
                revision,
                inputLeft,
                inputRight,
                outputLeft,
                outputRight,
                flags & 0x04 != 0 ? 1 : 0,
                flags & 0x08 != 0 ? 1 : 0,
                underruns
            )
        )
    }

    private func printConfiguration(_ bytes: [UInt8]) {
        guard bytes.count == 22, bytes[0] == 2, readUInt16(bytes, at: 2) == 22 else { return }
        let flags = bytes[1]
        let delayMicroseconds = readUInt32(bytes, at: 8)
        let cutoffHz = Double(readUInt16(bytes, at: 12)) / 10
        let trimDB = Double(readInt16(bytes, at: 14)) / 100
        let shelfHz = Double(readUInt16(bytes, at: 16)) / 10
        let shelfDB = Double(readInt16(bytes, at: 18)) / 100
        print(
            String(
                format: "config rev=%u bypass=%d delay=%d/%0.2fms lowpass=%d/%0.1fHz shelf=%d/%0.1fHz/%+.2fdB trim=%+.2fdB",
                readUInt32(bytes, at: 4),
                flags & 0x04 != 0 ? 1 : 0,
                flags & 0x01 != 0 ? 1 : 0,
                Double(delayMicroseconds) / 1_000,
                flags & 0x02 != 0 ? 1 : 0,
                cutoffHz,
                flags & 0x08 != 0 ? 1 : 0,
                shelfHz,
                shelfDB,
                trimDB
            )
        )
    }

    private func finish(_ message: String, status: Int32) {
        guard !finished else { return }
        finished = true
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        print(message)
        exit(status)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let duration = max(1, arguments.compactMap(TimeInterval.init).first ?? 15)
private let monitor = TelemetryMonitor(
    duration: duration,
    clearIndicators: arguments.contains("--clear")
)
RunLoop.main.run()
