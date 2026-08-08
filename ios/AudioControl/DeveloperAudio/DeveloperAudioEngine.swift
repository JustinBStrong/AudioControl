import AVFoundation
import Foundation

struct DeveloperAudioCapture: Sendable {
    let recordingURL: URL?
    let route: DeveloperAudioRouteStatus
}

@MainActor
final class DeveloperAudioEngine {
    enum EngineError: LocalizedError {
        case alreadyRunning
        case playbackMissing
        case microphonePermissionDenied
        case builtInMicrophoneUnavailable
        case wrongInput(String)
        case bluetoothOutputRequired(String)
        case invalidInputFormat(sampleRate: Double, channels: AVAudioChannelCount)
        case operationFailed(operation: String, underlying: Error)
        case routeChanged
        case interrupted

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                "The iPhone is already executing an agent audio command."
            case .playbackMissing:
                "The requested playback resource is not available on the iPhone."
            case .microphonePermissionDenied:
                "Microphone access is disabled. Allow it in Settings before using agent recording."
            case .builtInMicrophoneUnavailable:
                "The iPhone built-in microphone is unavailable. Disconnect an accessory that is taking over microphone input."
            case .wrongInput(let name):
                "iOS selected \(name) as the microphone instead of the iPhone built-in microphone."
            case .bluetoothOutputRequired(let name):
                "iOS selected \(name) as the output instead of a Bluetooth A2DP receiver."
            case let .invalidInputFormat(sampleRate, channels):
                "The microphone format is invalid (\(sampleRate) Hz, \(channels) channels)."
            case let .operationFailed(operation, underlying):
                "The iPhone could not \(operation): \(underlying.localizedDescription)"
            case .routeChanged:
                "The audio route changed while the agent command was running."
            case .interrupted:
                "Another app or the system interrupted the agent audio command."
            }
        }
    }

    typealias Completion = (String, Result<DeveloperAudioCapture, Error>) -> Void

    var onCompletion: Completion?
    var onActivityChanged: ((DeveloperAudioActivity) -> Void)?

    private struct ActiveRun {
        let requestID: String
        let command: DeveloperAudioCommand
        let recordingURL: URL?
        let playbackFile: AVAudioFile?
        var recordingFile: AVAudioFile?
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var activeRun: ActiveRun?
    private var inputTapInstalled = false
    private var timeoutTask: Task<Void, Never>?
    private var tailTask: Task<Void, Never>?
    private var observers = [NSObjectProtocol]()

    private(set) var activity: DeveloperAudioActivity = .idle {
        didSet { onActivityChanged?(activity) }
    }

    init() {
        engine.attach(player)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.activeRun != nil else { return }
                self?.finish(with: .failure(EngineError.routeChanged))
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
            Task { @MainActor in
                self?.finish(with: .failure(EngineError.interrupted))
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finish(with: .failure(EngineError.interrupted))
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func status(connectedPeer: String?, agentControlEnabled: Bool) -> DeveloperAudioRouteStatus {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first
        let output = session.currentRoute.outputs.first
        return DeveloperAudioRouteStatus(
            activity: activity,
            inputName: input?.portName ?? "No active microphone",
            inputType: input?.portType.rawValue ?? "none",
            outputName: output?.portName ?? "No audio output",
            outputType: output?.portType.rawValue ?? "none",
            outputVolume: session.outputVolume,
            connectedPeer: connectedPeer,
            agentControlEnabled: agentControlEnabled
        )
    }

    func start(command rawCommand: DeveloperAudioCommand, playbackURL: URL?) async throws {
        guard activeRun == nil else { throw EngineError.alreadyRunning }
        let command = try rawCommand.validated()
        if command.playbackResource != nil, playbackURL == nil {
            throw EngineError.playbackMissing
        }
        if command.recordMicrophone {
            guard await Self.requestMicrophonePermission() else {
                throw EngineError.microphonePermissionDenied
            }
        }

        NotificationCenter.default.post(name: .developerAudioWillStart, object: nil)
        let session = AVAudioSession.sharedInstance()
        do {
            if command.recordMicrophone {
                try session.setCategory(
                    .playAndRecord,
                    mode: .measurement,
                    options: [.allowBluetoothA2DP]
                )
            } else {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)

            if command.recordMicrophone {
                guard let builtInMicrophone = session.availableInputs?.first(where: {
                    $0.portType == .builtInMic
                }) else {
                    throw EngineError.builtInMicrophoneUnavailable
                }
                try session.setPreferredInput(builtInMicrophone)
            }

            let route = session.currentRoute
            let input = route.inputs.first
            let output = route.outputs.first
            if command.requireBuiltInMicrophone,
               command.recordMicrophone,
               input?.portType != .builtInMic {
                throw EngineError.wrongInput(input?.portName ?? "No microphone")
            }
            if command.requireBluetoothA2DP,
               output?.portType != .bluetoothA2DP {
                throw EngineError.bluetoothOutputRequired(output?.portName ?? "No audio output")
            }

            let playbackFile = try playbackURL.map(AVAudioFile.init(forReading:))
            let recording = try command.recordMicrophone ? makeRecordingFile(requestID: command.id) : nil

            activeRun = ActiveRun(
                requestID: command.id,
                command: command,
                recordingURL: recording?.url,
                playbackFile: playbackFile,
                recordingFile: recording?.file
            )

            if let recordingFile = recording?.file {
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                guard inputFormat.sampleRate.isFinite,
                      inputFormat.sampleRate > 0,
                      inputFormat.channelCount > 0 else {
                    throw EngineError.invalidInputFormat(
                        sampleRate: inputFormat.sampleRate,
                        channels: inputFormat.channelCount
                    )
                }
                engine.inputNode.installTap(
                    onBus: 0,
                    bufferSize: 4096,
                    format: inputFormat
                ) { [weak self] buffer, _ in
                    do {
                        try recordingFile.write(from: buffer)
                    } catch {
                        Task { @MainActor in
                            self?.finish(with: .failure(EngineError.operationFailed(
                                operation: "write the microphone recording",
                                underlying: error
                            )))
                        }
                    }
                }
                inputTapInstalled = true
            }

            if let playbackFile {
                engine.connect(player, to: engine.mainMixerNode, format: playbackFile.processingFormat)
                player.volume = Float(pow(10, command.playbackGainDB / 20))
                player.scheduleFile(
                    playbackFile,
                    at: nil,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor in self?.playbackFinished(requestID: command.id) }
                }
            }

            engine.prepare()
            try engine.start()
            if playbackFile != nil { player.play() }

            switch (playbackFile != nil, command.recordMicrophone) {
            case (true, true): activity = .playingAndRecording
            case (true, false): activity = .playing
            case (false, true): activity = .recording
            case (false, false): activity = .idle
            }

            if let maximumDuration = command.maximumDurationSeconds {
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(maximumDuration))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.finishSuccessfully() }
                }
            }
        } catch {
            cleanup(deleteRecording: true)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            if let engineError = error as? EngineError { throw engineError }
            throw EngineError.operationFailed(operation: "start agent audio", underlying: error)
        }
    }

    func stop(responseRequestID: String? = nil) {
        guard activeRun != nil else { return }
        finishSuccessfully(responseRequestID: responseRequestID)
    }

    func suspend() {
        guard activeRun != nil else { return }
        finish(with: .failure(EngineError.interrupted))
    }

    private func playbackFinished(requestID: String) {
        guard let activeRun, activeRun.requestID == requestID else { return }
        guard activeRun.command.stopAfterPlayback else { return }
        let tail = activeRun.command.recordMicrophone
            ? activeRun.command.postPlaybackSeconds
            : 0
        if tail <= 0 {
            finishSuccessfully()
            return
        }
        tailTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(tail))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finishSuccessfully() }
        }
    }

    private func finishSuccessfully(responseRequestID: String? = nil) {
        guard activeRun != nil else { return }
        let status = status(connectedPeer: nil, agentControlEnabled: true)
        finish(with: .success(DeveloperAudioCapture(
            recordingURL: activeRun?.recordingURL,
            route: status
        )), deleteRecording: false, responseRequestID: responseRequestID)
    }

    private func finish(
        with result: Result<DeveloperAudioCapture, Error>,
        deleteRecording: Bool = true,
        responseRequestID: String? = nil
    ) {
        guard let requestID = activeRun?.requestID else { return }
        cleanup(deleteRecording: deleteRecording)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        onCompletion?(responseRequestID ?? requestID, result)
    }

    private func cleanup(deleteRecording: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        tailTask?.cancel()
        tailTask = nil
        player.stop()
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        engine.stop()
        engine.disconnectNodeOutput(player)
        let recordingURL = activeRun?.recordingURL
        activeRun?.recordingFile = nil
        activeRun = nil
        activity = .idle
        if deleteRecording, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
    }

    private func makeRecordingFile(requestID: String) throws -> (url: URL, file: AVAudioFile) {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate.isFinite,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0 else {
            throw EngineError.invalidInputFormat(
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioControl-Agent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let safeID = requestID.replacingOccurrences(
            of: "[^A-Za-z0-9-]",
            with: "-",
            options: .regularExpression
        )
        let url = directory.appendingPathComponent("capture-\(safeID).wav")
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: inputFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
        return (url, file)
    }

    private static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            true
        case .denied:
            false
        case .undetermined:
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            false
        }
    }
}

extension Notification.Name {
    static let developerAudioWillStart = Notification.Name("DeveloperAudioWillStart")
}
