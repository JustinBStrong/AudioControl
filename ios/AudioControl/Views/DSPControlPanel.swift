import SwiftUI

struct DSPControlPanel: View {
    @ObservedObject var model: AudioControlViewModel
    @ObservedObject private var bluetooth: AudioControlBLEClient

    init(model: AudioControlViewModel) {
        self.model = model
        _bluetooth = ObservedObject(wrappedValue: model.bluetooth)
    }

    var body: some View {
        VStack(spacing: 16) {
            bypassPanel
            alignmentPanel
            bassShapePanel
            levelAndHeadroomPanel
        }
    }

    private var shelf: BassShelfConfiguration {
        model.settings.bassShelf
    }

    private var bypassPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("A/B COMPARISON", color: AudioControlTheme.signal)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bypass all DSP")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AudioControlTheme.ink)
                    Text("Prepare an unprocessed comparison. Tap Set on processor above to make this draft active.")
                        .font(.caption)
                        .foregroundStyle(AudioControlTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Bypass all DSP", isOn: Binding(
                    get: { model.settings.dspBypassed },
                    set: model.setDSPBypassed
                ))
                .labelsHidden()
                .tint(AudioControlTheme.signal)
            }

            StatusMessage(
                color: model.settings.dspBypassed
                    ? AudioControlTheme.signal
                    : AudioControlTheme.connected,
                icon: model.settings.dspBypassed
                    ? "arrow.trianglehead.branch"
                    : "waveform.path.ecg",
                title: model.settings.dspBypassed
                    ? "Bypass is active"
                    : "Processing is active",
                message: model.settings.dspBypassed
                    ? "The input is passing through unchanged for comparison."
                    : "Your delay, bass shape, low-pass, and level settings are in the signal path."
            )
        }
        .controlPanel()
    }

    private var alignmentPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("ALIGNMENT", color: AudioControlTheme.connected)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Subwoofer delay")
                        .font(.headline)
                        .foregroundStyle(AudioControlTheme.ink)
                    Text("Match the subwoofer to the delayed door speakers.")
                        .font(.caption)
                        .foregroundStyle(AudioControlTheme.muted)
                }
                Spacer()
                Toggle("Subwoofer delay", isOn: Binding(
                    get: { model.settings.delayEnabled },
                    set: model.setDelayEnabled
                ))
                .labelsHidden()
                .tint(AudioControlTheme.connected)
            }

            ParameterSlider(
                title: "Delay time",
                value: Binding(
                    get: { model.settings.delayMilliseconds },
                    set: model.setDelay
                ),
                range: DSPConfiguration.delayRange,
                step: 0.1,
                formattedValue: String(format: "%.1f ms", model.settings.delayMilliseconds),
                tint: AudioControlTheme.connected
            )

            Text(model.settings.delayEnabled
                ? "Draft value. Tap Set on processor to apply the complete configuration."
                : "Off in this draft. The selected delay time is retained until you apply it.")
                .font(.caption)
                .foregroundStyle(AudioControlTheme.muted)
        }
        .controlPanel()
    }

    private var bassShapePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("BASS SHAPE", color: AudioControlTheme.signal)

            VStack(alignment: .leading, spacing: 4) {
                Text("Frequency response")
                    .font(.headline)
                    .foregroundStyle(AudioControlTheme.ink)
                Text("The dark line combines the bass shelf and low-pass before automatic headroom.")
                    .font(.caption)
                    .foregroundStyle(AudioControlTheme.muted)
            }

            FrequencyResponseGraph(configuration: model.settings)

            shelfEditor

            Divider().overlay(AudioControlTheme.rule)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Low-pass filter")
                        .font(.headline)
                        .foregroundStyle(AudioControlTheme.ink)
                    Text("Removes voices and other sound above the subwoofer range.")
                        .font(.caption)
                        .foregroundStyle(AudioControlTheme.muted)
                }
                Spacer()
                Toggle("Low-pass filter", isOn: Binding(
                    get: { model.settings.lowPassEnabled },
                    set: model.setLowPassEnabled
                ))
                .labelsHidden()
                .tint(AudioControlTheme.connected)
            }

            ParameterSlider(
                title: "Cutoff",
                value: Binding(
                    get: { model.settings.lowPassHz },
                    set: model.setCutoff
                ),
                range: DSPConfiguration.cutoffRange,
                step: 1,
                formattedValue: String(format: "%.0f Hz", model.settings.lowPassHz),
                tint: AudioControlTheme.connected
            )
            .disabled(!model.settings.lowPassEnabled)
            .opacity(model.settings.lowPassEnabled ? 1 : 0.45)
        }
        .controlPanel()
    }

    private var shelfEditor: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Deep bass lift")
                        .font(.headline)
                        .foregroundStyle(AudioControlTheme.ink)
                    Text("Raise or lower the lowest bass without changing the rest of the range.")
                        .font(.caption)
                        .foregroundStyle(AudioControlTheme.muted)
                }
                Spacer()
                Toggle("Deep bass lift", isOn: Binding(
                    get: { shelf.enabled },
                    set: model.setShelfEnabled
                ))
                .labelsHidden()
                .tint(AudioControlTheme.signal)
            }

            ParameterSlider(
                title: "Lift",
                value: Binding(
                    get: { shelf.gainDB },
                    set: model.setShelfGain
                ),
                range: BassShelfConfiguration.gainRange,
                step: 0.25,
                formattedValue: String(format: "%+.2f dB", shelf.gainDB),
                tint: AudioControlTheme.signal
            )

            ParameterSlider(
                title: "Transition",
                value: Binding(
                    get: { shelf.transitionHz },
                    set: model.setShelfFrequency
                ),
                range: BassShelfConfiguration.transitionRange,
                step: 1,
                formattedValue: String(format: "%.0f Hz", shelf.transitionHz),
                tint: AudioControlTheme.signal
            )

            Text("The selected lift is strongest below the transition and smoothly returns toward 0 dB above it. At the transition itself, about half the lift remains.")
                .font(.caption)
                .foregroundStyle(AudioControlTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(shelf.enabled ? 1 : 0.62)
    }

    private var levelAndHeadroomPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("LEVEL & SAFETY", color: AudioControlTheme.connected)

            ParameterSlider(
                title: "Sub level",
                value: Binding(
                    get: { model.subLevelDB },
                    set: model.setSubLevel
                ),
                range: AudioControlViewModel.subLevelRange,
                step: 0.5,
                formattedValue: model.subLevelDB == 0
                    ? "Full"
                    : String(format: "%.1f dB", model.subLevelDB),
                tint: AudioControlTheme.connected
            )

            Divider().overlay(AudioControlTheme.rule)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.automaticHeadroomDB < 0
                    ? "arrow.down.to.line.compact"
                    : "checkmark.shield")
                    .font(.title3)
                    .foregroundStyle(AudioControlTheme.connected)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Automatic digital headroom")
                        .font(.headline)
                        .foregroundStyle(AudioControlTheme.ink)
                    if model.automaticHeadroomDB < 0 {
                        Text(String(
                            format: "Your curve adds up to +%.1f dB. The DSP lowers the full signal by %.1f dB so boosted peaks fit without clipping.",
                            model.peakBoostDB,
                            abs(model.automaticHeadroomDB)
                        ))
                    } else {
                        Text("Your curve does not rise above the original signal, so no headroom reduction is needed.")
                    }
                }
                .font(.caption)
                .foregroundStyle(AudioControlTheme.muted)
            }

            HStack(spacing: 10) {
                SignalMetric(title: "BOOST", value: String(format: "%+.1f dB", model.peakBoostDB))
                SignalMetric(title: "AUTO", value: String(format: "%.1f dB", model.automaticHeadroomDB))
                SignalMetric(title: "OUTPUT", value: String(format: "%.1f dB", model.settings.outputGainDB))
            }

            StatusMessage(
                color: AudioControlTheme.caution,
                icon: "bolt.trianglebadge.exclamationmark.fill",
                title: "Digital protection has a boundary",
                message: "Automatic headroom prevents clipping inside this DSP. It cannot prevent amplifier clipping or subwoofer over-excursion; set amplifier gain with the final tuning active."
            )

            clippingStatus
        }
        .controlPanel()
    }

    @ViewBuilder
    private var clippingStatus: some View {
        if bluetooth.telemetry?.inputClipped == true {
            StatusMessage(
                color: AudioControlTheme.signal,
                icon: "exclamationmark.triangle.fill",
                title: "Input clipping detected",
                message: "Lower the Bluetooth receiver output. DSP headroom cannot repair a signal that was clipped before processing."
            )
        } else if bluetooth.telemetry?.outputClipped == true {
            StatusMessage(
                color: AudioControlTheme.signal,
                icon: "exclamationmark.triangle.fill",
                title: "DSP output clipping detected",
                message: "The actual signal exceeded the prediction. Reduce bass lift or sub level."
            )
        } else if bluetooth.telemetry != nil {
            StatusMessage(
                color: AudioControlTheme.connected,
                icon: "checkmark.circle.fill",
                title: "No clipping detected",
                message: "Live input and DSP output monitoring are active."
            )
        } else {
            StatusMessage(
                color: AudioControlTheme.muted,
                icon: "waveform.badge.magnifyingglass",
                title: "Waiting for live signal data",
                message: "Clipping monitoring starts when the ESP32 is connected."
            )
        }
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(1.6)
            .foregroundStyle(color)
    }

}

private struct SignalMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(AudioControlTheme.muted)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(AudioControlTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AudioControlTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct StatusMessage: View {
    let color: Color
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AudioControlTheme.ink)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AudioControlTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formattedValue: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                    .foregroundStyle(AudioControlTheme.ink)
                Spacer()
                Text(formattedValue)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(AudioControlTheme.muted)
            }
            Slider(value: $value, in: range, step: step)
                .tint(tint)
                .accessibilityLabel(title)
                .accessibilityValue(formattedValue)
        }
    }
}
