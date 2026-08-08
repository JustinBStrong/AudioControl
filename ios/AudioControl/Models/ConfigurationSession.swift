import Foundation

enum ConfigurationSyncState: Equatable, Sendable {
    case disconnected(lastSavedRevision: UInt32?)
    case reading
    case verifying(revision: UInt32)
    case confirmed(revision: UInt32)
    case edited(savedRevision: UInt32)
    case sending(revision: UInt32)
    case saving(revision: UInt32)
    case failed(message: String, savedRevision: UInt32?)
}

struct ConfigurationSession: Sendable {
    private struct PendingWrite: Sendable {
        let request: DSPConfiguration
        var writeCompleted = false
        var statusAccepted = false
        var configurationAccepted: DSPConfiguration?
        var persistenceConfirmed = false
    }

    private(set) var draft = DSPConfiguration()
    private(set) var authoritative: DSPConfiguration?
    private(set) var lastSaved: DSPConfiguration?
    private(set) var state: ConfigurationSyncState = .disconnected(lastSavedRevision: nil)
    private(set) var isTransportConnected = false
    private var pendingWrite: PendingWrite?

    var canEdit: Bool {
        guard isTransportConnected, authoritative != nil, pendingWrite == nil else {
            return false
        }
        switch state {
        case .confirmed, .edited:
            return true
        case .disconnected, .reading, .verifying, .sending, .saving, .failed:
            return false
        }
    }

    var hasUnsavedChanges: Bool {
        guard let authoritative else { return false }
        return !draft.hasSameSettings(as: authoritative)
    }

    var canApply: Bool { canEdit && hasUnsavedChanges }

    var pendingRevision: UInt32? { pendingWrite?.request.revision }

    mutating func beginReading() {
        isTransportConnected = true
        authoritative = nil
        pendingWrite = nil
        state = .reading
    }

    mutating func disconnect() {
        isTransportConnected = false
        pendingWrite = nil
        authoritative = nil
        if let lastSaved {
            draft = lastSaved
        }
        state = .disconnected(lastSavedRevision: lastSaved?.revision)
    }

    mutating func receive(configuration rawConfiguration: DSPConfiguration) {
        guard isTransportConnected else { return }
        let configuration = rawConfiguration.normalized()

        if var pendingWrite {
            guard configuration.revision == pendingWrite.request.revision else {
                // Notifications for the previously saved revision can arrive while
                // the low-duty-cycle BLE write is still in flight.
                return
            }
            guard configuration.hasSameSettings(as: pendingWrite.request) else {
                failPendingWrite("The processor returned different settings than the draft.")
                return
            }
            pendingWrite.configurationAccepted = configuration
            self.pendingWrite = pendingWrite
            state = .saving(revision: configuration.revision)
            finishPendingWriteIfPossible()
            return
        }

        authoritative = configuration
        draft = configuration
        state = .verifying(revision: configuration.revision)
    }

    mutating func replaceDraft(_ rawDraft: DSPConfiguration) {
        guard canEdit, let authoritative else { return }
        var next = rawDraft.normalized()
        next.revision = authoritative.revision
        draft = next
        state = hasUnsavedChanges
            ? .edited(savedRevision: authoritative.revision)
            : stateForAuthoritativeRevision(authoritative.revision)
    }

    mutating func discardDraft() {
        guard canEdit, let authoritative else { return }
        draft = authoritative
        state = stateForAuthoritativeRevision(authoritative.revision)
    }

    mutating func beginApply() -> DSPConfiguration? {
        guard canApply, let authoritative else { return nil }
        var request = draft
        request.revision = authoritative.revision &+ 1
        pendingWrite = PendingWrite(request: request)
        state = .sending(revision: request.revision)
        return request
    }

    mutating func receiveWriteCompletion(revision: UInt32, errorMessage: String?) {
        guard var pendingWrite, pendingWrite.request.revision == revision else { return }
        if let errorMessage {
            failPendingWrite(errorMessage)
            return
        }
        pendingWrite.writeCompleted = true
        self.pendingWrite = pendingWrite
        finishPendingWriteIfPossible()
    }

    mutating func receive(status: CommandStatus) {
        guard var pendingWrite, pendingWrite.request.revision == status.requestID else { return }
        guard status.status == 0 else {
            failPendingWrite("The processor rejected the settings (status \(status.status)).")
            return
        }
        pendingWrite.statusAccepted = true
        self.pendingWrite = pendingWrite
        finishPendingWriteIfPossible()
    }

    mutating func receive(telemetry: AudioTelemetry) {
        guard isTransportConnected else { return }
        if var pendingWrite, telemetry.configurationRevision == pendingWrite.request.revision {
            pendingWrite.persistenceConfirmed = !telemetry.settingsDirty
            self.pendingWrite = pendingWrite
            if telemetry.settingsDirty {
                state = .saving(revision: telemetry.configurationRevision)
            }
            finishPendingWriteIfPossible()
            return
        }

        guard let authoritative,
              telemetry.configurationRevision == authoritative.revision,
              !hasUnsavedChanges else { return }
        if telemetry.settingsDirty {
            state = .saving(revision: authoritative.revision)
        } else {
            lastSaved = authoritative
            state = .confirmed(revision: authoritative.revision)
        }
    }

    mutating func failPendingWrite(_ message: String) {
        let savedRevision = lastSaved?.revision ?? authoritative?.revision
        pendingWrite = nil
        state = .failed(message: message, savedRevision: savedRevision)
    }

    private mutating func finishPendingWriteIfPossible() {
        guard let pendingWrite,
              pendingWrite.writeCompleted,
              pendingWrite.statusAccepted,
              pendingWrite.persistenceConfirmed,
              let accepted = pendingWrite.configurationAccepted else { return }
        authoritative = accepted
        lastSaved = accepted
        draft = accepted
        self.pendingWrite = nil
        state = .confirmed(revision: accepted.revision)
    }

    private func stateForAuthoritativeRevision(_ revision: UInt32) -> ConfigurationSyncState {
        lastSaved?.revision == revision
            ? .confirmed(revision: revision)
            : .verifying(revision: revision)
    }
}

extension DSPConfiguration {
    func hasSameSettings(as other: DSPConfiguration) -> Bool {
        var lhs = normalized()
        var rhs = other.normalized()
        lhs.revision = 0
        rhs.revision = 0
        return lhs == rhs
    }
}
