import SwiftUI

struct FrequencyResponseGraph: View {
    let configuration: DSPConfiguration

    private let graphGainRange = -18.0...6.0
    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { proxy in
                let plot = plotRect(for: proxy.size)
                Canvas { context, _ in
                    drawGrid(in: &context, plot: plot)
                    drawFilterResponses(in: &context, plot: plot)
                    drawCombinedResponse(in: &context, plot: plot)
                    drawCutoff(in: &context, plot: plot)
                }
            }
            .frame(height: 232)

            HStack(spacing: 9) {
                legendItem(color: AudioControlTheme.ink, label: "Combined", lineWidth: 3)
                legendItem(color: AudioControlTheme.signal, label: "Bass shelf")
                legendItem(color: AudioControlTheme.connected, label: "Low-pass")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bass frequency response")
        .accessibilityValue("Bass shelf and low-pass curve before automatic headroom")
    }

    private func legendItem(color: Color, label: String, lineWidth: CGFloat = 2) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: 13, height: lineWidth)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AudioControlTheme.muted)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, plot: CGRect) {
        let frequencies: [Double] = [20, 30, 40, 60, 80, 120, 160, 200]
        for frequency in frequencies {
            let x = xPosition(for: frequency, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(AudioControlTheme.rule.opacity(0.45)), lineWidth: 1)
            context.draw(
                Text("\(Int(frequency))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AudioControlTheme.muted),
                at: CGPoint(x: x, y: plot.maxY + 8),
                anchor: .top
            )
        }

        for gain in [-18.0, -12, -6, 0, 6] {
            let y = yPosition(for: gain, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                line,
                with: .color(gain == 0 ? AudioControlTheme.ink.opacity(0.38) : AudioControlTheme.rule.opacity(0.5)),
                style: StrokeStyle(lineWidth: gain == 0 ? 1.5 : 1, dash: gain == 0 ? [] : [3, 4])
            )
            context.draw(
                Text(gain == 0 ? "0" : String(format: "%+.0f", gain))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AudioControlTheme.muted),
                at: CGPoint(x: plot.minX - 7, y: y),
                anchor: .trailing
            )
        }
    }

    private func drawFilterResponses(in context: inout GraphicsContext, plot: CGRect) {
        if configuration.bassShelf.enabled {
            let points = shelfResponsePoints()
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: CGPoint(
                x: xPosition(for: first.frequencyHz, in: plot),
                y: yPosition(for: first.gainDB, in: plot)
            ))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(
                    x: xPosition(for: point.frequencyHz, in: plot),
                    y: yPosition(for: point.gainDB, in: plot)
                ))
            }

            var fill = path
            fill.addLine(to: CGPoint(x: plot.maxX, y: yPosition(for: 0, in: plot)))
            fill.addLine(to: CGPoint(x: plot.minX, y: yPosition(for: 0, in: plot)))
            fill.closeSubpath()
            context.fill(fill, with: .color(AudioControlTheme.signal.opacity(0.10)))

            context.stroke(
                path,
                with: .color(AudioControlTheme.signal.opacity(0.72)),
                style: StrokeStyle(lineWidth: 2.5)
            )
        }

        guard configuration.lowPassEnabled else { return }
        var lowPassOnly = DSPConfiguration()
        lowPassOnly.lowPassEnabled = true
        lowPassOnly.lowPassHz = configuration.lowPassHz
        lowPassOnly.bassShelf.enabled = false
        let points = DSPResponseAnalyzer.responsePoints(for: lowPassOnly, count: 181)
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: CGPoint(
            x: xPosition(for: first.frequencyHz, in: plot),
            y: yPosition(for: first.gainDB, in: plot)
        ))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(
                x: xPosition(for: point.frequencyHz, in: plot),
                y: yPosition(for: point.gainDB, in: plot)
            ))
        }
        context.stroke(
            path,
            with: .color(AudioControlTheme.connected.opacity(0.62)),
            style: StrokeStyle(lineWidth: 2, dash: [4, 4])
        )
    }

    private func drawCombinedResponse(in context: inout GraphicsContext, plot: CGRect) {
        let points = DSPResponseAnalyzer.responsePoints(for: configuration, count: 241)
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: CGPoint(
            x: xPosition(for: first.frequencyHz, in: plot),
            y: yPosition(for: first.gainDB, in: plot)
        ))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(
                x: xPosition(for: point.frequencyHz, in: plot),
                y: yPosition(for: point.gainDB, in: plot)
            ))
        }
        context.stroke(
            path,
            with: .color(AudioControlTheme.ink),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawCutoff(in context: inout GraphicsContext, plot: CGRect) {
        guard configuration.lowPassEnabled else { return }
        let x = xPosition(for: configuration.lowPassHz, in: plot)
        var line = Path()
        line.move(to: CGPoint(x: x, y: plot.minY))
        line.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(
            line,
            with: .color(AudioControlTheme.connected.opacity(0.8)),
            style: StrokeStyle(lineWidth: 2, dash: [6, 5])
        )
    }

    private func shelfResponsePoints(count: Int = 181) -> [DSPResponsePoint] {
        let range = DSPResponseAnalyzer.displayFrequencyRange
        let lower = log10(range.lowerBound)
        let span = log10(range.upperBound) - lower
        return (0..<count).map { index in
            let progress = Double(index) / Double(count - 1)
            let frequency = pow(10, lower + progress * span)
            return DSPResponsePoint(
                frequencyHz: frequency,
                gainDB: DSPResponseAnalyzer.shelfResponseDB(
                    for: configuration.bassShelf,
                    at: frequency
                )
            )
        }
    }

    private func plotRect(for size: CGSize) -> CGRect {
        CGRect(x: 31, y: 12, width: max(1, size.width - 43), height: max(1, size.height - 42))
    }

    private func xPosition(for frequencyHz: Double, in plot: CGRect) -> CGFloat {
        let range = DSPResponseAnalyzer.displayFrequencyRange
        let progress = (log10(frequencyHz.clamped(to: range)) - log10(range.lowerBound))
            / (log10(range.upperBound) - log10(range.lowerBound))
        return plot.minX + CGFloat(progress) * plot.width
    }

    private func yPosition(for gainDB: Double, in plot: CGRect) -> CGFloat {
        let gain = gainDB.clamped(to: graphGainRange)
        let progress = (graphGainRange.upperBound - gain)
            / (graphGainRange.upperBound - graphGainRange.lowerBound)
        return plot.minY + CGFloat(progress) * plot.height
    }
}
