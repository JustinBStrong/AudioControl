import Combine
import CoreBluetooth
import Foundation

struct ConfigurationWriteResult: Equatable, Sendable {
    let revision: UInt32
    let errorMessage: String?
}

@MainActor
final class AudioControlBLEClient: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case bluetoothUnavailable
        case bluetoothOff
        case permissionDenied
        case idle
        case scanning
        case connecting(String)
        case synchronizing(String)
        case connected(String)

        var label: String {
            switch self {
            case .bluetoothUnavailable: "Bluetooth unavailable"
            case .bluetoothOff: "Bluetooth is off"
            case .permissionDenied: "Bluetooth permission denied"
            case .idle: "Find processor"
            case .scanning: "Searching…"
            case .connecting(let name): "Connecting to \(name)…"
            case .synchronizing(let name): "Reading \(name)…"
            case .connected(let name): name
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var detail: String {
            switch self {
            case .bluetoothUnavailable: "This device cannot use Bluetooth control"
            case .bluetoothOff: "Turn on Bluetooth to connect"
            case .permissionDenied: "Tap to allow access in Settings"
            case .idle: "Tap to find AudioControl"
            case .scanning: "Tap to stop searching"
            case .connecting: "Tap to cancel"
            case .synchronizing: "Connected · reading processor settings"
            case .connected: "Processor connected · tap to disconnect"
            }
        }

        var actionSymbol: String {
            switch self {
            case .bluetoothUnavailable: "exclamationmark.triangle"
            case .bluetoothOff: "antenna.radiowaves.left.and.right.slash"
            case .permissionDenied: "gearshape"
            case .idle: "antenna.radiowaves.left.and.right"
            case .scanning, .connecting, .synchronizing, .connected: "xmark"
            }
        }

        var opensSettings: Bool {
            self == .permissionDenied
        }

        var isActionable: Bool {
            switch self {
            case .bluetoothUnavailable, .bluetoothOff: false
            default: true
            }
        }
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var receivedConfiguration: DSPConfiguration?
    @Published private(set) var telemetry: AudioTelemetry?
    @Published private(set) var lastCommandStatus: CommandStatus?
    @Published private(set) var configurationWriteResult: ConfigurationWriteResult?
    @Published private(set) var lastError: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var configurationCharacteristic: CBCharacteristic?
    private var telemetryCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var pendingConfigurationRevision: UInt32?
    private var scanGeneration: UInt = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scanOrDisconnect() {
        switch state {
        case .scanning:
            scanGeneration &+= 1
            central.stopScan()
            state = .idle
        case .connecting, .synchronizing, .connected:
            guard let peripheral else {
                state = .idle
                return
            }
            central.cancelPeripheralConnection(peripheral)
        case .idle:
            scan()
        case .bluetoothUnavailable, .bluetoothOff, .permissionDenied:
            break
        }
    }

    func scan() {
        guard CBManager.authorization != .denied,
              CBManager.authorization != .restricted else {
            state = .permissionDenied
            return
        }
        guard central.state == .poweredOn else {
            state = central.state == .poweredOff ? .bluetoothOff : .bluetoothUnavailable
            return
        }
        lastError = nil
        clearDeviceData()
        scanGeneration &+= 1
        let generation = scanGeneration
        state = .scanning
        central.scanForPeripherals(
            withServices: [AudioControlBLEProtocol.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  self.scanGeneration == generation,
                  self.state == .scanning else { return }
            self.central.stopScan()
            self.state = .idle
            self.lastError = "No AudioControl processor was found. Check that the ESP32 is powered and nearby, then try again."
        }
    }

    func write(configuration: DSPConfiguration) {
        configurationWriteResult = nil
        lastCommandStatus = nil
        guard state.isConnected,
              let peripheral,
              let characteristic = configurationCharacteristic else {
            publishWriteFailure(
                revision: configuration.revision,
                message: "The processor is not connected and ready."
            )
            return
        }
        guard characteristic.properties.contains(.write) else {
            publishWriteFailure(
                revision: configuration.revision,
                message: "The processor does not support reliable configuration writes."
            )
            return
        }
        guard peripheral.maximumWriteValueLength(for: .withResponse) >= ConfigurationPacket.byteCount else {
            publishWriteFailure(
                revision: configuration.revision,
                message: "The Bluetooth connection cannot carry a complete configuration packet."
            )
            return
        }
        pendingConfigurationRevision = configuration.revision
        peripheral.writeValue(
            ConfigurationPacket.encode(configuration),
            for: characteristic,
            type: .withResponse
        )
    }

    func refreshConfiguration() {
        guard let peripheral,
              let configurationCharacteristic,
              let telemetryCharacteristic else {
            lastError = "The processor is not connected and ready to read."
            return
        }
        configurationWriteResult = nil
        lastCommandStatus = nil
        state = .synchronizing(peripheral.name ?? "AudioControl")
        peripheral.readValue(for: configurationCharacteristic)
        peripheral.readValue(for: telemetryCharacteristic)
    }

    func send(command: DeviceCommand, requestID: UInt32) {
        guard let peripheral, let characteristic = commandCharacteristic,
              characteristic.properties.contains(.write) else { return }
        peripheral.writeValue(
            CommandPacket.encode(command, requestID: requestID),
            for: characteristic,
            type: .withResponse
        )
    }

    func dismissError() {
        lastError = nil
    }

    private func clearDeviceData() {
        receivedConfiguration = nil
        telemetry = nil
        lastCommandStatus = nil
        configurationWriteResult = nil
        pendingConfigurationRevision = nil
    }

    private func publishWriteFailure(revision: UInt32, message: String) {
        pendingConfigurationRevision = nil
        configurationWriteResult = ConfigurationWriteResult(
            revision: revision,
            errorMessage: message
        )
        lastError = message
    }
}

extension AudioControlBLEClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if CBManager.authorization == .denied || CBManager.authorization == .restricted {
                state = .permissionDenied
            } else {
                switch central.state {
                case .poweredOn:
                    if peripheral == nil { state = .idle }
                case .poweredOff:
                    scanGeneration &+= 1
                    central.stopScan()
                    state = .bluetoothOff
                default:
                    state = .bluetoothUnavailable
                }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            scanGeneration &+= 1
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            let name = peripheral.name ?? "AudioControl"
            state = .connecting(name)
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            scanGeneration &+= 1
            // A BLE link is not usable until service and characteristic discovery
            // finishes. The board intentionally uses a low-duty-cycle connection to
            // keep radio-current bursts out of the analog input, so discovery can take
            // several seconds.
            state = .connecting(peripheral.name ?? "AudioControl")
            peripheral.discoverServices([AudioControlBLEProtocol.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            scanGeneration &+= 1
            state = .idle
            lastError = error?.localizedDescription ?? "Could not connect to the processor."
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            scanGeneration &+= 1
            state = .idle
            configurationCharacteristic = nil
            telemetryCharacteristic = nil
            commandCharacteristic = nil
            clearDeviceData()
            self.peripheral = nil
            if let error { lastError = error.localizedDescription }
        }
    }
}

extension AudioControlBLEClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                return
            }
            peripheral.services?.forEach {
                peripheral.discoverCharacteristics(
                    [
                        AudioControlBLEProtocol.configurationUUID,
                        AudioControlBLEProtocol.telemetryUUID,
                        AudioControlBLEProtocol.commandUUID,
                    ],
                    for: $0
                )
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                return
            }
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case AudioControlBLEProtocol.configurationUUID:
                    configurationCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                case AudioControlBLEProtocol.telemetryUUID:
                    telemetryCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                case AudioControlBLEProtocol.commandUUID:
                    commandCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                default:
                    break
                }
            }
            if configurationCharacteristic != nil,
               telemetryCharacteristic != nil,
               commandCharacteristic != nil {
                state = .synchronizing(peripheral.name ?? "AudioControl")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                lastError = error.localizedDescription
                return
            }
            guard let value = characteristic.value else { return }
            do {
                switch characteristic.uuid {
                case AudioControlBLEProtocol.configurationUUID:
                    receivedConfiguration = try ConfigurationPacket.decode(value)
                    state = .connected(peripheral.name ?? "AudioControl")
                case AudioControlBLEProtocol.telemetryUUID:
                    telemetry = try AudioTelemetry.decode(value)
                case AudioControlBLEProtocol.commandUUID:
                    lastCommandStatus = try CommandStatus.decode(value)
                default:
                    break
                }
            } catch {
                lastError = "The processor sent an invalid Bluetooth packet."
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == AudioControlBLEProtocol.configurationUUID else {
            if let error {
                Task { @MainActor in lastError = error.localizedDescription }
            }
            return
        }
        Task { @MainActor in
            guard let revision = pendingConfigurationRevision else { return }
            pendingConfigurationRevision = nil
            let message = error?.localizedDescription
            configurationWriteResult = ConfigurationWriteResult(
                revision: revision,
                errorMessage: message
            )
            if let message { lastError = message }
        }
    }
}
