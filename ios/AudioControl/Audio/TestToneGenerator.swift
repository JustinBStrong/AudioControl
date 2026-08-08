import AVFoundation
import Foundation
import os

final class TestToneGenerator: @unchecked Sendable {
    enum GeneratorError: LocalizedError {
        case couldNotCreateFormat
        case invalidOutputFormat(sampleRate: Double, channels: AVAudioChannelCount)
        case operationFailed(operation: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateFormat:
                "The test-tone audio format could not be created."
            case let .invalidOutputFormat(sampleRate, channels):
                "The selected audio output has an invalid format (\(sampleRate) Hz, \(channels) channels)."
            case let .operationFailed(operation, underlying):
                "The test tone could not \(operation): \(underlying.localizedDescription)"
            }
        }
    }

    var onForcedStop: (@MainActor () -> Void)?

    private let parameters = ToneParameterStore()
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var stopGeneration = 0
    private var observers = [NSObjectProtocol]()

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
            self?.forceStop()
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in self?.forceStop() })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start(frequencyHz: Double, levelDBFS: Double) throws {
        stopGeneration &+= 1
        if engine.isRunning {
            update(frequencyHz: frequencyHz, levelDBFS: levelDBFS)
            return
        }

        // A failed engine start can leave an attached source behind. Always
        // begin from a known graph before configuring the current audio route.
        removeSourceNode()

        let session = AVAudioSession.sharedInstance()
        do {
            // The playback category already follows A2DP and AirPlay routes.
            // allowBluetoothA2DP is only needed to augment other categories.
            try session.setCategory(.playback, mode: .default)
        } catch {
            throw GeneratorError.operationFailed(operation: "configure the audio session", underlying: error)
        }
        do {
            try session.setActive(true)
        } catch {
            throw GeneratorError.operationFailed(operation: "activate the audio session", underlying: error)
        }

        // The simulator normally exposes 48 kHz stereo, but a physical
        // iPhone's route may be 44.1/48 kHz and mono/stereo. Connecting a
        // source node with a hard-coded format can make AVAudioEngine reject
        // the graph with OSStatus -50 (paramErr).
        let routeFormat = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = routeFormat.sampleRate
        let channelCount = min(routeFormat.channelCount, 2)
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            deactivateSession()
            throw GeneratorError.invalidOutputFormat(
                sampleRate: sampleRate,
                channels: routeFormat.channelCount
            )
        }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ) else {
            deactivateSession()
            throw GeneratorError.couldNotCreateFormat
        }

        parameters.set(frequencyHz: frequencyHz, levelDBFS: levelDBFS, enabled: true)
        let parameters = self.parameters
        let renderState = ToneRenderState()
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let target = parameters.snapshot()
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frequencyPole = exp(-1 / (0.015 * sampleRate))
            let amplitudePole = exp(-1 / (0.010 * sampleRate))

            for frame in 0..<Int(frameCount) {
                renderState.frequencyHz = target.frequencyHz
                    + frequencyPole * (renderState.frequencyHz - target.frequencyHz)
                renderState.amplitude = target.amplitude
                    + amplitudePole * (renderState.amplitude - target.amplitude)
                renderState.phase += 2 * .pi * renderState.frequencyHz / sampleRate
                if renderState.phase >= 2 * .pi { renderState.phase -= 2 * .pi }
                let sample = Float(sin(renderState.phase) * renderState.amplitude)

                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    data[frame] = sample
                }
            }
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeSourceNode()
            deactivateSession()
            throw GeneratorError.operationFailed(operation: "start audio playback", underlying: error)
        }
    }

    func update(frequencyHz: Double, levelDBFS: Double) {
        parameters.set(frequencyHz: frequencyHz, levelDBFS: levelDBFS, enabled: true)
    }

    func stopWithFade() {
        parameters.setEnabled(false)
        stopGeneration &+= 1
        let generation = stopGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            guard let self, self.stopGeneration == generation else { return }
            self.tearDown()
        }
    }

    func forceStop() {
        stopGeneration &+= 1
        parameters.setEnabled(false)
        tearDown()
        Task { @MainActor [weak self] in self?.onForcedStop?() }
    }

    private func tearDown() {
        engine.stop()
        removeSourceNode()
        deactivateSession()
    }

    private func removeSourceNode() {
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private struct ToneParameters {
    var frequencyHz = 40.0
    var amplitude = 0.0
}

private final class ToneParameterStore: @unchecked Sendable {
    private struct State {
        var frequencyHz = 40.0
        var levelDBFS = 0.0
        var enabled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func set(frequencyHz: Double, levelDBFS: Double, enabled: Bool) {
        state.withLock {
            $0.frequencyHz = frequencyHz.clamped(to: ToneControlModel.frequencyRange)
            $0.levelDBFS = levelDBFS.clamped(to: -80...0)
            $0.enabled = enabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        state.withLock { $0.enabled = enabled }
    }

    func snapshot() -> ToneParameters {
        state.withLock {
            ToneParameters(
                frequencyHz: $0.frequencyHz,
                amplitude: $0.enabled ? pow(10, $0.levelDBFS / 20) : 0
            )
        }
    }
}

private final class ToneRenderState: @unchecked Sendable {
    var phase = 0.0
    var frequencyHz = 40.0
    var amplitude = 0.0
}
