import AudioControl
import Darwin
import Foundation
@preconcurrency import MultipeerConnectivity

private enum CLIAction {
    case status
    case play(input: URL, gainDB: Double, requireBluetooth: Bool)
    case record(output: URL, seconds: Double, requireBuiltInMic: Bool)
    case capture(
        input: URL,
        output: URL,
        gainDB: Double,
        tailSeconds: Double,
        requireBluetooth: Bool,
        requireBuiltInMic: Bool
    )
    case stop(output: URL?)

    var outputURL: URL? {
        switch self {
        case .record(let output, _, _), .capture(_, let output, _, _, _, _): output
        case .stop(let output): output
        case .status, .play: nil
        }
    }

    var inputURL: URL? {
        switch self {
        case .play(let input, _, _), .capture(let input, _, _, _, _, _): input
        case .status, .record, .stop: nil
        }
    }
}

private enum CLIError: LocalizedError {
    case usage(String)
    case timedOut(String)
    case connection(String)
    case remote(String)
    case outputExists(URL)
    case missingRecording

    var errorDescription: String? {
        switch self {
        case .usage(let message), .connection(let message), .remote(let message): message
        case .timedOut(let stage): "Timed out while \(stage)."
        case .outputExists(let url): "Refusing to overwrite existing output: \(url.path)"
        case .missingRecording: "The iPhone completed the command without returning the expected recording."
        }
    }
}

@MainActor
private final class AgentAudioCLI: NSObject {
    private let action: CLIAction
    private let requestID = UUID().uuidString
    private let peerID: MCPeerID
    private let session: MCSession
    private let browser: MCNearbyServiceBrowser
    private var targetPeer: MCPeerID?
    private var command: DeveloperAudioCommand!
    private var uploadResourceName: String?
    private var expectedRecordingName: String?
    private var receivedRecording = false
    private var commandCompleted = false
    private var finished = false
    private var failure: Error?
    private var stage = "discovering the iPhone"

    init(action: CLIAction) throws {
        self.action = action
        if let output = action.outputURL,
           FileManager.default.fileExists(atPath: output.path) {
            throw CLIError.outputExists(output)
        }
        if let input = action.inputURL {
            guard FileManager.default.fileExists(atPath: input.path),
                  input.pathExtension.lowercased() == "wav" else {
                throw CLIError.usage("Playback input must be an existing WAV file: \(input.path)")
            }
        }

        let displayName = "AudioControl Mac \(ProcessInfo.processInfo.processIdentifier)"
        let peerID = MCPeerID(displayName: displayName)
        self.peerID = peerID
        self.session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        self.browser = MCNearbyServiceBrowser(
            peer: peerID,
            serviceType: DeveloperAudioProtocol.serviceType
        )
        super.init()
        session.delegate = self
        browser.delegate = self
        command = makeCommand()
    }

    func run() throws {
        print("Looking for AudioControl. Open the Agent tab, enable Agent Control, and approve this Mac.")
        browser.startBrowsingForPeers()
        let timeout = Date().addingTimeInterval(1_860)
        while !finished, Date() < timeout {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        browser.stopBrowsingForPeers()
        session.disconnect()
        if let failure { throw failure }
        guard finished else { throw CLIError.timedOut(stage) }
    }

    private func makeCommand() -> DeveloperAudioCommand {
        switch action {
        case .status:
            DeveloperAudioCommand(
                id: requestID,
                operation: .status,
                requireBluetoothA2DP: false,
                requireBuiltInMicrophone: false
            )

        case .play(_, let gainDB, let requireBluetooth):
            DeveloperAudioCommand(
                id: requestID,
                operation: .run,
                playbackResource: uploadName(),
                playbackGainDB: gainDB,
                requireBluetoothA2DP: requireBluetooth,
                requireBuiltInMicrophone: false
            )

        case .record(_, let seconds, let requireBuiltInMic):
            DeveloperAudioCommand(
                id: requestID,
                operation: .run,
                recordMicrophone: true,
                stopAfterPlayback: false,
                maximumDurationSeconds: seconds,
                requireBluetoothA2DP: false,
                requireBuiltInMicrophone: requireBuiltInMic
            )

        case .capture(_, _, let gainDB, let tailSeconds, let requireBluetooth, let requireBuiltInMic):
            DeveloperAudioCommand(
                id: requestID,
                operation: .run,
                playbackResource: uploadName(),
                recordMicrophone: true,
                stopAfterPlayback: true,
                postPlaybackSeconds: tailSeconds,
                playbackGainDB: gainDB,
                requireBluetoothA2DP: requireBluetooth,
                requireBuiltInMicrophone: requireBuiltInMic
            )

        case .stop:
            DeveloperAudioCommand(
                id: requestID,
                operation: .stop,
                requireBluetoothA2DP: false,
                requireBuiltInMicrophone: false
            )
        }
    }

    private func uploadName() -> String {
        "upload-\(requestID).wav"
    }

    private func connected() {
        guard let targetPeer else { return }
        stage = "sending the command"
        if let inputURL = action.inputURL {
            let resourceName = uploadName()
            uploadResourceName = resourceName
            print("Connected. Uploading \(inputURL.lastPathComponent)…")
            session.sendResource(
                at: inputURL,
                withName: resourceName,
                toPeer: targetPeer
            ) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async {
                    self?.fail(CLIError.connection("WAV upload failed: \(error.localizedDescription)"))
                }
            }
        } else {
            sendCommand(to: targetPeer)
        }
    }

    private func sendCommand(to peer: MCPeerID) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(command)
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            fail(CLIError.connection("Could not send command: \(error.localizedDescription)"))
        }
    }

    private func receive(_ data: Data) {
        let event: DeveloperAudioEvent
        do {
            event = try JSONDecoder().decode(DeveloperAudioEvent.self, from: data)
        } catch {
            fail(CLIError.connection("Received an invalid event: \(error.localizedDescription)"))
            return
        }
        guard event.requestID == requestID || event.requestID == "unknown" else { return }

        switch event.kind {
        case .uploadReady:
            guard event.resourceName == uploadResourceName,
                  let targetPeer else { return }
            print("Upload ready. Sending audio command…")
            sendCommand(to: targetPeer)

        case .accepted:
            stage = "waiting for the iPhone audio command to finish"
            print(event.message ?? "Command accepted.")
            if let status = event.status { printStatus(status) }

        case .status:
            if let status = event.status {
                printStatus(status)
                succeed()
            } else {
                fail(CLIError.connection("The status response did not contain route data."))
            }

        case .completed:
            commandCompleted = true
            expectedRecordingName = event.resourceName
            print(event.message ?? "Command completed.")
            if let status = event.status { printStatus(status) }
            if action.outputURL == nil {
                succeed()
            } else if event.resourceName == nil {
                fail(CLIError.missingRecording)
            } else if receivedRecording {
                succeed()
            } else {
                stage = "downloading the microphone recording"
            }

        case .error:
            fail(CLIError.remote(event.message ?? "The iPhone rejected the command."))
        }
    }

    private func receiveResource(
        name: String,
        temporaryURL: URL?,
        error: Error?
    ) {
        if let error {
            fail(CLIError.connection("Recording download failed: \(error.localizedDescription)"))
            return
        }
        guard let outputURL = action.outputURL,
              let temporaryURL,
              name.hasPrefix("capture-") else { return }
        do {
            let parent = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: temporaryURL, to: outputURL)
            receivedRecording = true
            print("Recording saved to \(outputURL.path)")
            if commandCompleted,
               expectedRecordingName == nil || expectedRecordingName == name {
                succeed()
            }
        } catch {
            fail(CLIError.connection("Could not save recording: \(error.localizedDescription)"))
        }
    }

    private func printStatus(_ status: DeveloperAudioRouteStatus) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(status),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    private func succeed() {
        finished = true
    }

    private func fail(_ error: Error) {
        failure = error
        finished = true
    }
}

extension AgentAudioCLI: @preconcurrency MCNearbyServiceBrowserDelegate {
    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        guard targetPeer == nil,
              info?["protocol"] == String(DeveloperAudioProtocol.version) else { return }
        targetPeer = peerID
        browser.stopBrowsingForPeers()
        stage = "waiting for approval on \(peerID.displayName)"
        print("Found \(peerID.displayName). Approve the connection in the iPhone app.")
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 45)
    }

    func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {}

    func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        fail(CLIError.connection("Discovery failed: \(error.localizedDescription)"))
    }
}

extension AgentAudioCLI: @preconcurrency MCSessionDelegate {
    func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .connected:
                self?.connected()
            case .notConnected:
                if self?.finished == false {
                    self?.fail(CLIError.connection("The iPhone connection closed before the command finished."))
                }
            case .connecting:
                break
            @unknown default:
                self?.fail(CLIError.connection("The peer entered an unknown connection state."))
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in self?.receive(data) }
    }

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.receiveResource(name: resourceName, temporaryURL: localURL, error: error)
        }
    }
}

private func parseArguments(_ arguments: [String]) throws -> CLIAction {
    guard let verb = arguments.first else { throw CLIError.usage(usage) }
    let rest = Array(arguments.dropFirst())

    func value(after flag: String, default defaultValue: Double? = nil) throws -> Double {
        guard let index = rest.firstIndex(of: flag) else {
            if let defaultValue { return defaultValue }
            throw CLIError.usage("Missing required \(flag).\n\n\(usage)")
        }
        guard rest.indices.contains(index + 1),
              let number = Double(rest[index + 1]),
              number.isFinite else {
            throw CLIError.usage("\(flag) requires a finite number.")
        }
        return number
    }

    switch verb {
    case "status":
        return .status

    case "play":
        guard let input = rest.first, !input.hasPrefix("--") else {
            throw CLIError.usage(usage)
        }
        return .play(
            input: URL(fileURLWithPath: input).standardizedFileURL,
            gainDB: try value(after: "--gain-db", default: -30),
            requireBluetooth: !rest.contains("--allow-any-output")
        )

    case "record":
        guard let output = rest.first, !output.hasPrefix("--") else {
            throw CLIError.usage(usage)
        }
        return .record(
            output: URL(fileURLWithPath: output).standardizedFileURL,
            seconds: try value(after: "--seconds"),
            requireBuiltInMic: !rest.contains("--allow-any-input")
        )

    case "capture":
        guard rest.count >= 2,
              !rest[0].hasPrefix("--"),
              !rest[1].hasPrefix("--") else {
            throw CLIError.usage(usage)
        }
        return .capture(
            input: URL(fileURLWithPath: rest[0]).standardizedFileURL,
            output: URL(fileURLWithPath: rest[1]).standardizedFileURL,
            gainDB: try value(after: "--gain-db", default: -30),
            tailSeconds: try value(after: "--tail", default: 0),
            requireBluetooth: !rest.contains("--allow-any-output"),
            requireBuiltInMic: !rest.contains("--allow-any-input")
        )

    case "stop":
        let output = rest.first.map { URL(fileURLWithPath: $0).standardizedFileURL }
        return .stop(output: output)

    case "help", "--help", "-h":
        throw CLIError.usage(usage)

    default:
        throw CLIError.usage("Unknown command: \(verb)\n\n\(usage)")
    }
}

private let usage = """
Usage:
  swift run iphone-audio status
  swift run iphone-audio play INPUT.wav [--gain-db -30] [--allow-any-output]
  swift run iphone-audio record OUTPUT.wav --seconds N [--allow-any-input]
  swift run iphone-audio capture INPUT.wav OUTPUT.wav [--gain-db -30] [--tail N] [--allow-any-output] [--allow-any-input]
  swift run iphone-audio stop [OUTPUT.wav]

Playback gain defaults to -30 dB. Playback and capture require Bluetooth A2DP
unless --allow-any-output is supplied. Recording requires the iPhone built-in
microphone unless --allow-any-input is supplied. Existing output files are
never overwritten.
"""

do {
    let action = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let cli = try AgentAudioCLI(action: action)
    try cli.run()
} catch {
    fputs("iphone-audio: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
