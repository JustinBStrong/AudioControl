import Combine
import Foundation

@MainActor
final class AudioControlViewModel: ObservableObject {
    @Published private(set) var settings = DSPConfiguration()
    @Published private(set) var subLevelDB = 0.0
    @Published private(set) var configurationState: ConfigurationSyncState =
        .disconnected(lastSavedRevision: nil)

    let bluetooth: AudioControlBLEClient

    static let subLevelRange = -12.0...0.0

    private var session = ConfigurationSession()
    private var subscriptions = Set<AnyCancellable>()
    private var applyTimeout: Task<Void, Never>?

    init(bluetooth: AudioControlBLEClient? = nil) {
        let resolvedBluetooth = bluetooth ?? AudioControlBLEClient()
        self.bluetooth = resolvedBluetooth

        resolvedBluetooth.$state
            .sink { [weak self] in self?.receive(connectionState: $0) }
            .store(in: &subscriptions)
        resolvedBluetooth.$receivedConfiguration
            .compactMap { $0 }
            .sink { [weak self] in self?.receive(configuration: $0) }
            .store(in: &subscriptions)
        resolvedBluetooth.$configurationWriteResult
            .compactMap { $0 }
            .sink { [weak self] in self?.receive(writeResult: $0) }
            .store(in: &subscriptions)
        resolvedBluetooth.$lastCommandStatus
            .compactMap { $0 }
            .sink { [weak self] in self?.receive(commandStatus: $0) }
            .store(in: &subscriptions)
        resolvedBluetooth.$telemetry
            .compactMap { $0 }
            .sink { [weak self] in self?.receive(telemetry: $0) }
            .store(in: &subscriptions)
    }

    var canEdit: Bool { session.canEdit }
    var canApply: Bool { session.canApply }
    var hasUnsavedChanges: Bool { session.hasUnsavedChanges }
    var lastSavedConfiguration: DSPConfiguration? { session.lastSaved }

    var peakBoostDB: Double {
        DSPResponseAnalyzer.peakBoostDB(for: settings)
    }

    var automaticHeadroomDB: Double {
        DSPResponseAnalyzer.automaticHeadroomDB(for: settings)
    }

    var predictedPeakDBFS: Double {
        peakBoostDB + settings.outputGainDB
    }

    func setDelay(_ value: Double) {
        update {
            $0.delayMilliseconds = value
            $0.delayEnabled = value > 0
        }
    }

    func setDelayEnabled(_ enabled: Bool) {
        update { $0.delayEnabled = enabled }
    }

    func setCutoff(_ value: Double) {
        update { $0.lowPassHz = value }
    }

    func setLowPassEnabled(_ enabled: Bool) {
        update { $0.lowPassEnabled = enabled }
    }

    func setSubLevel(_ value: Double) {
        guard canEdit else { return }
        subLevelDB = value.clamped(to: Self.subLevelRange)
        update { _ in }
    }

    func setDSPBypassed(_ value: Bool) {
        update { $0.dspBypassed = value }
    }

    func setShelfEnabled(_ enabled: Bool) {
        update { $0.bassShelf.enabled = enabled }
    }

    func setShelfFrequency(_ frequencyHz: Double) {
        update {
            $0.bassShelf.enabled = true
            $0.bassShelf.transitionHz = frequencyHz
        }
    }

    func setShelfGain(_ gainDB: Double) {
        update {
            $0.bassShelf.enabled = true
            $0.bassShelf.gainDB = gainDB
        }
    }

    func applyDraft() {
        guard let request = session.beginApply() else { return }
        publishSession()
        applyTimeout?.cancel()
        applyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self,
                  self.session.pendingRevision == request.revision else { return }
            self.session.failPendingWrite(
                "The processor did not confirm the settings before the connection timed out."
            )
            self.publishSession()
        }
        bluetooth.write(configuration: request)
    }

    func discardDraft() {
        session.discardDraft()
        publishSession(recalculateSubLevel: true)
    }

    func refreshConfiguration() {
        bluetooth.refreshConfiguration()
    }

    private func update(_ mutation: (inout DSPConfiguration) -> Void) {
        guard canEdit else { return }
        var next = settings
        mutation(&next)
        next = next.normalized()
        let headroom = DSPResponseAnalyzer.automaticHeadroomDB(for: next)
        next.outputGainDB = max(
            DSPConfiguration.gainRange.lowerBound,
            headroom + subLevelDB
        )
        session.replaceDraft(next)
        publishSession()
    }

    private func receive(connectionState: AudioControlBLEClient.ConnectionState) {
        switch connectionState {
        case .connecting, .synchronizing:
            if !session.isTransportConnected || session.authoritative != nil {
                session.beginReading()
                publishSession()
            }
        case .connected:
            if !session.isTransportConnected {
                session.beginReading()
                publishSession()
            }
        case .bluetoothUnavailable, .bluetoothOff, .permissionDenied, .idle, .scanning:
            if session.isTransportConnected {
                applyTimeout?.cancel()
                session.disconnect()
                publishSession(recalculateSubLevel: true)
            }
        }
    }

    private func receive(configuration: DSPConfiguration) {
        session.receive(configuration: configuration)
        publishSession(recalculateSubLevel: true)
    }

    private func receive(writeResult: ConfigurationWriteResult) {
        session.receiveWriteCompletion(
            revision: writeResult.revision,
            errorMessage: writeResult.errorMessage
        )
        finishApplyTimeoutIfSettled()
        publishSession(recalculateSubLevel: true)
    }

    private func receive(commandStatus: CommandStatus) {
        session.receive(status: commandStatus)
        finishApplyTimeoutIfSettled()
        publishSession(recalculateSubLevel: true)
    }

    private func receive(telemetry: AudioTelemetry) {
        session.receive(telemetry: telemetry)
        finishApplyTimeoutIfSettled()
        publishSession(recalculateSubLevel: true)
    }

    private func finishApplyTimeoutIfSettled() {
        if session.pendingRevision == nil {
            applyTimeout?.cancel()
        }
    }

    private func publishSession(recalculateSubLevel: Bool = false) {
        settings = session.draft
        configurationState = session.state
        if recalculateSubLevel {
            let headroom = DSPResponseAnalyzer.automaticHeadroomDB(for: settings)
            subLevelDB = (settings.outputGainDB - headroom)
                .clamped(to: Self.subLevelRange)
        }
    }
}
