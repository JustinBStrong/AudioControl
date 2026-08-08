import Foundation

struct ToneControlModel: Equatable, Sendable {
    static let frequencyRange = 20.0...200.0
    static let permittedLevelsDBFS: [Double] = [-20, -10, -5, 0]

    private(set) var frequencyHz: Double
    private(set) var frequencyText: String
    private(set) var levelDBFS: Double

    init(frequencyHz: Double = 40, levelDBFS: Double = 0) {
        let frequency = frequencyHz.clamped(to: Self.frequencyRange)
        self.frequencyHz = frequency
        self.frequencyText = Self.format(frequency)
        self.levelDBFS = Self.closestLevel(to: levelDBFS)
    }

    mutating func setFrequencyFromSlider(_ value: Double) {
        frequencyHz = value.clamped(to: Self.frequencyRange)
        frequencyText = Self.format(frequencyHz)
    }

    mutating func setFrequencyText(_ text: String) {
        frequencyText = text
        guard let parsed = Self.parse(text) else { return }
        frequencyHz = parsed.clamped(to: Self.frequencyRange)
    }

    mutating func commitFrequencyText() {
        frequencyHz = frequencyHz.clamped(to: Self.frequencyRange)
        frequencyText = Self.format(frequencyHz)
    }

    mutating func setLevelDBFS(_ value: Double) {
        levelDBFS = Self.closestLevel(to: value)
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "."))
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private static func closestLevel(to value: Double) -> Double {
        permittedLevelsDBFS.min(by: { abs($0 - value) < abs($1 - value) }) ?? 0
    }
}
