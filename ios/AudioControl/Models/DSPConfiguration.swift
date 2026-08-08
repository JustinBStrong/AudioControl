import Foundation

struct DSPConfiguration: Equatable, Sendable {
    static let delayRange = 0.0...250.0
    static let cutoffRange = 40.0...160.0
    static let gainRange = -36.0...0.0

    var revision: UInt32 = 1
    var delayMilliseconds: Double = 0
    var lowPassHz: Double = 80
    var outputGainDB: Double = 0
    var delayEnabled = false
    var lowPassEnabled = true
    var dspBypassed = false
    var bassShelf = BassShelfConfiguration()

    var crossoverBypassed: Bool {
        get { !lowPassEnabled }
        set { lowPassEnabled = !newValue }
    }

    func normalized() -> DSPConfiguration {
        var result = self
        result.delayMilliseconds = delayMilliseconds.clamped(to: Self.delayRange)
        result.lowPassHz = lowPassHz.clamped(to: Self.cutoffRange)
        result.outputGainDB = outputGainDB.clamped(to: Self.gainRange)
        result.bassShelf = bassShelf.normalized()
        return result
    }
}

struct BassShelfConfiguration: Equatable, Sendable {
    static let transitionRange = 20.0...100.0
    static let gainRange = -6.0...6.0

    var enabled = false
    var transitionHz = 40.0
    var gainDB = 0.0

    func normalized() -> BassShelfConfiguration {
        var result = self
        result.transitionHz = transitionHz.clamped(to: Self.transitionRange)
        result.gainDB = gainDB.clamped(to: Self.gainRange)
        return result
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
