import AVFoundation
import Foundation
import MultipeerConnectivity
import UIKit

@MainActor
final class DeveloperAudioBridge: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case disabled
        case advertising
        case approvalRequired(String)
        case connecting(String)
        case connected(String)
        case failed(String)

        var title: String {
            switch self {
            case .disabled: "Agent Control is off"
            case .advertising: "Waiting for a Mac agent"
            case .approvalRequired: "Connection approval required"
            case .connecting(let peer): "Connecting to \(peer)"
            case .connected(let peer): "Connected to \(peer)"
            case .failed: "Agent Control needs attention"
            }
        }
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var connectionState: ConnectionState = .disabled
    @Published private(set) var activity: DeveloperAudioActivity = .idle
    @Published private(set) var routeStatus: DeveloperAudioRouteStatus
    @Published private(set) var lastEvent = "No agent commands have run"

    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let audioEngine = DeveloperAudioEngine()
    private var pendingInvitation: ((Bool, MCSession?) -> Void)?
    private var pendingPeer: MCPeerID?
    private var uploadedResources = [String: URL]()
    private var activePlaybackResource: String?
    private var isForeground = false

    override init() {
        let deviceName = String(UIDevice.current.name.prefix(48))
        let peerID = MCPeerID(displayName: deviceName.isEmpty ? "AudioControl iPhone" : deviceName)
        self.peerID = peerID
        self.session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["protocol": String(DeveloperAudioProtocol.version)],
            serviceType: DeveloperAudioProtocol.serviceType
        )
        self.routeStatus = DeveloperAudioRouteStatus(
            activity: .idle,
            inputName: "No active microphone",
            inputType: "none",
            outputName: "Checking audio output…",
            outputType: "none",
            outputVolume: 0,
            connectedPeer: nil,
            agentControlEnabled: false
        )
        super.init()
        session.delegate = self
        advertiser.delegate = self
        audioEngine.onActivityChanged = { [weak self] activity in
            self?.activity = activity
            self?.refreshStatus()
        }
        audioEngine.onCompletion = { [weak self] requestID, result in
            self?.complete(requestID: requestID, result: result)
        }
        refreshStatus()
    }

    var pendingPeerName: String? { pendingPeer?.displayName }
    var connectedPeerName: String? { session.connectedPeers.first?.displayName }
    var isBusy: Bool { activity != .idle }

    func start() {
        isForeground = true
        refreshStatus()
        if isEnabled { beginAdvertisingIfNeeded() }
    }

    func suspend() {
        isForeground = false
        advertiser.stopAdvertisingPeer()
        rejectPendingConnection()
        audioEngine.suspend()
        session.disconnect()
        connectionState = isEnabled ? .advertising : .disabled
        refreshStatus()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            lastEvent = "Agent Control enabled for this app session"
            beginAdvertisingIfNeeded()
        } else {
            lastEvent = "Agent Control disabled"
            advertiser.stopAdvertisingPeer()
            rejectPendingConnection()
            audioEngine.suspend()
            session.disconnect()
            deleteUploadedResources()
            connectionState = .disabled
        }
        refreshStatus()
    }

    func approvePendingConnection() {
        guard let invitation = pendingInvitation,
              let peer = pendingPeer else { return }
        pendingInvitation = nil
        pendingPeer = nil
        connectionState = .connecting(peer.displayName)
        invitation(true, session)
    }

    func rejectPendingConnection() {
        pendingInvitation?(false, nil)
        pendingInvitation = nil
        pendingPeer = nil
        if isEnabled {
            connectionState = .advertising
        }
    }

    func stopRemoteAudio() {
        guard isBusy else { return }
        lastEvent = "Stopping remote audio at the iPhone"
        audioEngine.stop()
    }

    func refreshStatus() {
        routeStatus = audioEngine.status(
            connectedPeer: connectedPeerName,
            agentControlEnabled: isEnabled
        )
    }

    private func beginAdvertisingIfNeeded() {
        guard isEnabled, isForeground, session.connectedPeers.isEmpty else { return }
        advertiser.startAdvertisingPeer()
        connectionState = .advertising
    }

    private func handle(_ data: Data, from peer: MCPeerID) {
        guard isEnabled, session.connectedPeers.contains(peer) else { return }
        let command: DeveloperAudioCommand
        do {
            command = try JSONDecoder().decode(DeveloperAudioCommand.self, from: data).validated()
        } catch {
            send(DeveloperAudioEvent(
                requestID: "unknown",
                kind: .error,
                message: error.localizedDescription
            ), to: peer)
            return
        }

        switch command.operation {
        case .status:
            refreshStatus()
            send(DeveloperAudioEvent(
                requestID: command.id,
                kind: .status,
                status: routeStatus
            ), to: peer)

        case .stop:
            if audioEngine.activity == .idle {
                send(DeveloperAudioEvent(
                    requestID: command.id,
                    kind: .completed,
                    message: "No remote audio command was running.",
                    status: routeStatus
                ), to: peer)
            } else {
                lastEvent = "\(peer.displayName) requested Stop"
                audioEngine.stop(responseRequestID: command.id)
            }

        case .run:
            guard audioEngine.activity == .idle else {
                send(DeveloperAudioEvent(
                    requestID: command.id,
                    kind: .error,
                    message: DeveloperAudioEngine.EngineError.alreadyRunning.localizedDescription,
                    status: routeStatus
                ), to: peer)
                return
            }
            let playbackURL = command.playbackResource.flatMap { uploadedResources[$0] }
            if command.playbackResource != nil, playbackURL == nil {
                send(DeveloperAudioEvent(
                    requestID: command.id,
                    kind: .error,
                    message: DeveloperAudioEngine.EngineError.playbackMissing.localizedDescription
                ), to: peer)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                self.activePlaybackResource = command.playbackResource
                do {
                    try await self.audioEngine.start(command: command, playbackURL: playbackURL)
                    self.lastEvent = self.commandDescription(command, peer: peer.displayName)
                    self.refreshStatus()
                    self.send(DeveloperAudioEvent(
                        requestID: command.id,
                        kind: .accepted,
                        message: self.lastEvent,
                        status: self.routeStatus
                    ), to: peer)
                } catch {
                    if let resourceName = self.activePlaybackResource,
                       let url = self.uploadedResources.removeValue(forKey: resourceName) {
                        try? FileManager.default.removeItem(at: url)
                    }
                    self.activePlaybackResource = nil
                    self.send(DeveloperAudioEvent(
                        requestID: command.id,
                        kind: .error,
                        message: error.localizedDescription,
                        status: self.routeStatus
                    ), to: peer)
                    self.lastEvent = error.localizedDescription
                    self.refreshStatus()
                }
            }
        }
    }

    private func complete(
        requestID: String,
        result: Result<DeveloperAudioCapture, Error>
    ) {
        if let resourceName = activePlaybackResource,
           let url = uploadedResources.removeValue(forKey: resourceName) {
            try? FileManager.default.removeItem(at: url)
        }
        activePlaybackResource = nil
        refreshStatus()
        guard let peer = session.connectedPeers.first else {
            if case .success(let capture) = result, let url = capture.recordingURL {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }

        switch result {
        case .failure(let error):
            lastEvent = error.localizedDescription
            send(DeveloperAudioEvent(
                requestID: requestID,
                kind: .error,
                message: error.localizedDescription,
                status: routeStatus
            ), to: peer)

        case .success(let capture):
            guard let recordingURL = capture.recordingURL else {
                lastEvent = "Remote playback completed"
                send(DeveloperAudioEvent(
                    requestID: requestID,
                    kind: .completed,
                    message: lastEvent,
                    status: routeStatus
                ), to: peer)
                return
            }

            let resourceName = recordingURL.lastPathComponent
            lastEvent = "Remote recording completed and is returning to \(peer.displayName)"
            send(DeveloperAudioEvent(
                requestID: requestID,
                kind: .completed,
                message: lastEvent,
                resourceName: resourceName,
                status: routeStatus
            ), to: peer)
            let completion: @Sendable (Error?) -> Void = { [weak self] error in
                try? FileManager.default.removeItem(at: recordingURL)
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in
                    self?.lastEvent = "Could not return the recording: \(message)"
                }
            }
            session.sendResource(
                at: recordingURL,
                withName: resourceName,
                toPeer: peer,
                withCompletionHandler: completion
            )
        }
    }

    private func receiveResource(
        named resourceName: String,
        at stagedURL: URL?,
        errorMessage: String?,
        from peer: MCPeerID
    ) {
        if let errorMessage {
            send(DeveloperAudioEvent(
                requestID: requestID(fromUploadResource: resourceName),
                kind: .error,
                message: "The iPhone could not receive \(resourceName): \(errorMessage)"
            ), to: peer)
            return
        }
        guard resourceName == URL(fileURLWithPath: resourceName).lastPathComponent,
              resourceName.hasPrefix("upload-"),
              resourceName.lowercased().hasSuffix(".wav"),
              let stagedURL else {
            send(DeveloperAudioEvent(
                requestID: requestID(fromUploadResource: resourceName),
                kind: .error,
                message: "Only upload-*.wav resources are accepted."
            ), to: peer)
            return
        }

        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioControl-Agent-Uploads", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(resourceName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: stagedURL, to: destination)
            uploadedResources[resourceName] = destination
            send(DeveloperAudioEvent(
                requestID: requestID(fromUploadResource: resourceName),
                kind: .uploadReady,
                resourceName: resourceName
            ), to: peer)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            send(DeveloperAudioEvent(
                requestID: requestID(fromUploadResource: resourceName),
                kind: .error,
                message: "The iPhone could not store \(resourceName): \(error.localizedDescription)"
            ), to: peer)
        }
    }

    nonisolated private static func stageIncomingResource(
        named resourceName: String,
        at localURL: URL?,
        error: Error?
    ) -> StagedIncomingResource {
        if let error {
            return StagedIncomingResource(
                resourceName: resourceName,
                url: nil,
                errorMessage: error.localizedDescription
            )
        }
        guard let localURL else {
            return StagedIncomingResource(
                resourceName: resourceName,
                url: nil,
                errorMessage: "Multipeer did not provide a temporary file."
            )
        }
        do {
            let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 128 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AudioControl-Agent-Incoming", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let stagedURL = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: localURL, to: stagedURL)
            return StagedIncomingResource(
                resourceName: resourceName,
                url: stagedURL,
                errorMessage: nil
            )
        } catch {
            return StagedIncomingResource(
                resourceName: resourceName,
                url: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func deleteUploadedResources() {
        uploadedResources.values.forEach { try? FileManager.default.removeItem(at: $0) }
        uploadedResources.removeAll()
        activePlaybackResource = nil
    }

    private func requestID(fromUploadResource resourceName: String) -> String {
        String(resourceName.dropFirst("upload-".count).dropLast(".wav".count))
    }

    private func commandDescription(_ command: DeveloperAudioCommand, peer: String) -> String {
        switch (command.playbackResource != nil, command.recordMicrophone) {
        case (true, true): "\(peer) is playing audio and recording the iPhone microphone"
        case (true, false): "\(peer) is playing audio through the selected output"
        case (false, true): "\(peer) is recording the iPhone microphone"
        case (false, false): "\(peer) sent an empty command"
        }
    }

    private func send(_ event: DeveloperAudioEvent, to peer: MCPeerID) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(event)
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            lastEvent = "Could not reply to \(peer.displayName): \(error.localizedDescription)"
        }
    }
}

extension DeveloperAudioBridge: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            guard self.isEnabled, self.pendingInvitation == nil else {
                invitationHandler(false, nil)
                return
            }
            self.pendingPeer = peerID
            self.pendingInvitation = invitationHandler
            self.connectionState = .approvalRequired(peerID.displayName)
            self.lastEvent = "\(peerID.displayName) is requesting Agent Control"
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        Task { @MainActor in
            self.connectionState = .failed(error.localizedDescription)
            self.lastEvent = error.localizedDescription
        }
    }
}

extension DeveloperAudioBridge: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        Task { @MainActor in
            switch state {
            case .notConnected:
                self.connectionState = self.isEnabled ? .advertising : .disabled
                self.lastEvent = "\(peerID.displayName) disconnected"
                self.audioEngine.suspend()
                self.deleteUploadedResources()
                self.beginAdvertisingIfNeeded()
            case .connecting:
                self.connectionState = .connecting(peerID.displayName)
            case .connected:
                self.advertiser.stopAdvertisingPeer()
                self.connectionState = .connected(peerID.displayName)
                self.lastEvent = "Agent Control connected to \(peerID.displayName)"
            @unknown default:
                self.connectionState = .failed("Unknown peer connection state")
            }
            self.refreshStatus()
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handle(data, from: peerID) }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        let staged = Self.stageIncomingResource(
            named: resourceName,
            at: localURL,
            error: error
        )
        Task { @MainActor in
            self.receiveResource(
                named: staged.resourceName,
                at: staged.url,
                errorMessage: staged.errorMessage,
                from: peerID
            )
        }
    }
}

private struct StagedIncomingResource: Sendable {
    let resourceName: String
    let url: URL?
    let errorMessage: String?
}
