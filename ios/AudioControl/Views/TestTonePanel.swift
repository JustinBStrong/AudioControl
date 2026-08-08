import SwiftUI

struct TestTonePanel: View {
    @ObservedObject var tone: TestToneViewModel
    @FocusState private var frequencyFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TEST SIGNAL")
                        .font(.caption.weight(.bold))
                        .tracking(1.6)
                        .foregroundStyle(AudioControlTheme.signal)
                    Text(tone.isPlaying ? "Continuous sine is live" : "Set amplifier gain safely")
                        .font(.subheadline)
                        .foregroundStyle(AudioControlTheme.muted)
                }
                Spacer()
                RoutePicker()
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Choose audio output")
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(
                    "40",
                    text: Binding(
                        get: { tone.controls.frequencyText },
                        set: tone.setFrequencyText
                    )
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 58, weight: .semibold, design: .rounded))
                .foregroundStyle(AudioControlTheme.ink)
                .focused($frequencyFieldFocused)
                .onSubmit(tone.commitFrequencyText)
                .accessibilityLabel("Test tone frequency")
                Text("Hz")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(AudioControlTheme.muted)
            }

            Slider(
                value: Binding(
                    get: { tone.controls.frequencyHz },
                    set: tone.setFrequencyFromSlider
                ),
                in: ToneControlModel.frequencyRange,
                step: 0.5
            ) {
                Text("Frequency")
            } minimumValueLabel: {
                Text("20")
                    .font(.caption.monospacedDigit())
            } maximumValueLabel: {
                Text("200")
                    .font(.caption.monospacedDigit())
            }
            .tint(AudioControlTheme.signal)

            VStack(alignment: .leading, spacing: 9) {
                Text("OUTPUT LEVEL · dBFS")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AudioControlTheme.muted)
                Picker("Output level", selection: Binding(
                    get: { tone.controls.levelDBFS },
                    set: tone.setLevel
                )) {
                    ForEach(ToneControlModel.permittedLevelsDBFS, id: \.self) { value in
                        Text(value == 0 ? "0" : String(format: "%.0f", value))
                            .tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text(tone.controls.levelDBFS == 0
                    ? "Full-scale digital calibration signal. Phone and receiver volume still independently affect the amplifier input. Use a continuous full-scale tone only as long as needed."
                    : "Digital attenuation applied before the separate phone and receiver volume controls.")
                    .font(.caption)
                    .foregroundStyle(AudioControlTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: tone.togglePlayback) {
                HStack(spacing: 10) {
                    Image(systemName: tone.isPlaying ? "stop.fill" : "waveform")
                    Text(tone.isPlaying ? "Stop test tone" : "Start continuous tone")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tone.isPlaying ? AudioControlTheme.ink : AudioControlTheme.canvas)
            .background(tone.isPlaying ? AudioControlTheme.panelRaised : AudioControlTheme.signal)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let error = tone.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(AudioControlTheme.signal)
            }
        }
        .controlPanel()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    tone.commitFrequencyText()
                    frequencyFieldFocused = false
                }
            }
        }
    }
}
