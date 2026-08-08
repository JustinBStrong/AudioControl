import CoreBluetooth
import Foundation

private let serviceUUID = CBUUID(string: "7C1C0001-7A4D-4E6B-9D2A-5E4143554449")

private final class ConnectionHold: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private let holdSeconds: TimeInterval

    init(holdSeconds: TimeInterval) {
        self.holdSeconds = holdSeconds
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard self?.peripheral == nil else { return }
            fputs("ERROR: timed out finding AudioControl\n", stderr)
            exit(1)
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
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "AudioControl"
        print("CONNECTED \(name); holding for \(Int(holdSeconds)) seconds")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
            central.cancelPeripheralConnection(peripheral)
            exit(0)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        fputs("ERROR: \(error?.localizedDescription ?? "connection failed")\n", stderr)
        exit(1)
    }
}

let holdSeconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 30
private let hold = ConnectionHold(holdSeconds: holdSeconds)
RunLoop.main.run()
