import Foundation

struct DSPResponsePoint: Equatable, Sendable {
    let frequencyHz: Double
    let gainDB: Double
}

enum DSPResponseAnalyzer {
    static let sampleRateHz = 48_000.0
    static let displayFrequencyRange = 20.0...200.0
    static let safetyMarginDB = 0.5

    static func responsePoints(
        for configuration: DSPConfiguration,
        count: Int = 181
    ) -> [DSPResponsePoint] {
        let count = max(2, count)
        let lower = log10(displayFrequencyRange.lowerBound)
        let span = log10(displayFrequencyRange.upperBound) - lower
        return (0..<count).map { index in
            let progress = Double(index) / Double(count - 1)
            let frequency = pow(10, lower + progress * span)
            return DSPResponsePoint(
                frequencyHz: frequency,
                gainDB: responseDB(for: configuration, at: frequency)
            )
        }
    }

    static func responseDB(
        for configuration: DSPConfiguration,
        at frequencyHz: Double
    ) -> Double {
        guard !configuration.dspBypassed else { return 0 }
        let normalized = configuration.normalized()
        var response = 0.0

        if normalized.bassShelf.enabled {
            response += shelfResponseDB(
                for: normalized.bassShelf,
                at: frequencyHz
            )
        }

        if normalized.lowPassEnabled {
            let stage = lowPassCoefficients(
                cutoffHz: normalized.lowPassHz,
                q: 1 / sqrt(2)
            ).magnitudeDB(at: frequencyHz)
            response += stage * 2
        }
        return response
    }

    static func peakBoostDB(for configuration: DSPConfiguration) -> Double {
        guard !configuration.dspBypassed else { return 0 }
        let normalized = configuration.normalized()
        var frequencies = responsePoints(for: configuration, count: 721).map(\.frequencyHz)
        frequencies.append(normalized.lowPassHz)
        frequencies.append(normalized.bassShelf.transitionHz)
        let sampledPeak = frequencies.map {
            responseDB(for: configuration, at: $0)
        }.max() ?? 0
        let lowFrequencyShelfGain = normalized.bassShelf.enabled
            ? normalized.bassShelf.gainDB
            : 0
        return max(0, sampledPeak, lowFrequencyShelfGain)
    }

    static func automaticHeadroomDB(for configuration: DSPConfiguration) -> Double {
        let peak = peakBoostDB(for: configuration)
        guard peak > 0.01 else { return 0 }
        let required = peak + safetyMarginDB
        return max(DSPConfiguration.gainRange.lowerBound, -ceil(required * 100) / 100)
    }

    static func shelfResponseDB(
        for shelf: BassShelfConfiguration,
        at frequencyHz: Double
    ) -> Double {
        guard shelf.enabled else { return 0 }
        return lowShelfCoefficients(
            frequencyHz: shelf.transitionHz,
            gainDB: shelf.gainDB
        ).magnitudeDB(at: frequencyHz)
    }

    private static func lowPassCoefficients(cutoffHz: Double, q: Double) -> BiquadCoefficients {
        let omega = 2 * Double.pi * cutoffHz / sampleRateHz
        let cosine = cos(omega)
        let sine = sin(omega)
        let alpha = sine / (2 * q)
        return BiquadCoefficients.normalized(
            b0: (1 - cosine) * 0.5,
            b1: 1 - cosine,
            b2: (1 - cosine) * 0.5,
            a0: 1 + alpha,
            a1: -2 * cosine,
            a2: 1 - alpha
        )
    }

    private static func lowShelfCoefficients(
        frequencyHz: Double,
        gainDB: Double
    ) -> BiquadCoefficients {
        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequencyHz / sampleRateHz
        let cosine = cos(omega)
        let alpha = sin(omega) * sqrt(2) * 0.5
        let twoSqrtAAlpha = 2 * sqrt(amplitude) * alpha
        let aPlusOne = amplitude + 1
        let aMinusOne = amplitude - 1
        return BiquadCoefficients.normalized(
            b0: amplitude * (aPlusOne - aMinusOne * cosine + twoSqrtAAlpha),
            b1: 2 * amplitude * (aMinusOne - aPlusOne * cosine),
            b2: amplitude * (aPlusOne - aMinusOne * cosine - twoSqrtAAlpha),
            a0: aPlusOne + aMinusOne * cosine + twoSqrtAAlpha,
            a1: -2 * (aMinusOne + aPlusOne * cosine),
            a2: aPlusOne + aMinusOne * cosine - twoSqrtAAlpha
        )
    }
}

private struct BiquadCoefficients {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    static func normalized(
        b0: Double,
        b1: Double,
        b2: Double,
        a0: Double,
        a1: Double,
        a2: Double
    ) -> BiquadCoefficients {
        BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }

    func magnitudeDB(at frequencyHz: Double) -> Double {
        let omega = 2 * Double.pi * frequencyHz / DSPResponseAnalyzer.sampleRateHz
        let numeratorReal = b0 + b1 * cos(omega) + b2 * cos(2 * omega)
        let numeratorImaginary = -b1 * sin(omega) - b2 * sin(2 * omega)
        let denominatorReal = 1 + a1 * cos(omega) + a2 * cos(2 * omega)
        let denominatorImaginary = -a1 * sin(omega) - a2 * sin(2 * omega)
        let numeratorPower = numeratorReal * numeratorReal
            + numeratorImaginary * numeratorImaginary
        let denominatorPower = denominatorReal * denominatorReal
            + denominatorImaginary * denominatorImaginary
        return 10 * log10(max(numeratorPower / denominatorPower, 1e-20))
    }
}
