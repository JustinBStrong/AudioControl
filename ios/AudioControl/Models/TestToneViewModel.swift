import Foundation

@MainActor
final class TestToneViewModel: ObservableObject {
    @Published private(set) var controls = ToneControlModel()
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private let generator: TestToneGenerator

    init(generator: TestToneGenerator = TestToneGenerator()) {
        self.generator = generator
        generator.onForcedStop = { [weak self] in
            self?.isPlaying = false
        }
    }

    func setFrequencyFromSlider(_ value: Double) {
        controls.setFrequencyFromSlider(value)
        updateGenerator()
    }

    func setFrequencyText(_ value: String) {
        controls.setFrequencyText(value)
        updateGenerator()
    }

    func commitFrequencyText() {
        controls.commitFrequencyText()
        updateGenerator()
    }

    func setLevel(_ value: Double) {
        controls.setLevelDBFS(value)
        updateGenerator()
    }

    func togglePlayback() {
        isPlaying ? stop() : start()
    }

    func start() {
        do {
            try generator.start(
                frequencyHz: controls.frequencyHz,
                levelDBFS: controls.levelDBFS
            )
            errorMessage = nil
            isPlaying = true
        } catch {
            isPlaying = false
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        generator.stopWithFade()
        isPlaying = false
    }

    func stopImmediately() {
        guard isPlaying else { return }
        generator.forceStop()
        isPlaying = false
    }

    private func updateGenerator() {
        guard isPlaying else { return }
        generator.update(
            frequencyHz: controls.frequencyHz,
            levelDBFS: controls.levelDBFS
        )
    }
}

