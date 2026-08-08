import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var model: AudioControlViewModel
    @ObservedObject var tone: TestToneViewModel
    @ObservedObject var developerAudio: DeveloperAudioBridge
    @ObservedObject private var bluetooth: AudioControlBLEClient

    init(
        model: AudioControlViewModel,
        tone: TestToneViewModel,
        developerAudio: DeveloperAudioBridge
    ) {
        self.model = model
        self.tone = tone
        self.developerAudio = developerAudio
        _bluetooth = ObservedObject(wrappedValue: model.bluetooth)
    }

    var body: some View {
        TabView {
            tuneTab
                .tabItem {
                    Label("Tune", systemImage: "slider.horizontal.3")
                }

            testToneTab
                .tabItem {
                    Label("Test Tone", systemImage: "waveform")
                }

            agentTab
                .tabItem {
                    Label("Agent", systemImage: "laptopcomputer.and.iphone")
                }
        }
        .tint(AudioControlTheme.connected)
        .alert("Bluetooth", isPresented: Binding(
            get: { bluetooth.lastError != nil },
            set: { if !$0 { bluetooth.dismissError() } }
        )) {
            Button("OK", role: .cancel) { bluetooth.dismissError() }
        } message: {
            Text(bluetooth.lastError ?? "")
        }
    }

    private var tuneTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    processorPanel
                    if !model.canEdit {
                        lockedSettingsNotice
                    }
                    DSPControlPanel(model: model)
                        .disabled(!model.canEdit)
                        .opacity(model.canEdit ? 1 : 0.52)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(AudioControlTheme.canvas.ignoresSafeArea())
            .navigationTitle("Tune")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var testToneTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TestTonePanel(tone: tone)
                        .disabled(developerAudio.isBusy)
                        .opacity(developerAudio.isBusy ? 0.52 : 1)

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "iphone.and.arrow.forward.outward")
                            .foregroundStyle(AudioControlTheme.connected)
                        Text(developerAudio.isBusy
                            ? "Test Tone is locked while the connected agent controls the iPhone audio session."
                            : "The tone plays from the iPhone's selected audio output. It does not travel over the ESP32 control connection.")
                            .font(.caption)
                            .foregroundStyle(AudioControlTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(AudioControlTheme.canvas.ignoresSafeArea())
            .navigationTitle("Test Tone")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var agentTab: some View {
        NavigationStack {
            ScrollView {
                AgentControlPanel(agent: developerAudio)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
            }
            .background(AudioControlTheme.canvas.ignoresSafeArea())
            .navigationTitle("Agent Control")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var processorPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(configurationStatusColor.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: configurationStatusIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(configurationStatusColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("PROCESSOR STATE")
                        .font(.caption2.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(configurationStatusColor)
                    Text(configurationStatusTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AudioControlTheme.ink)
                    Text(configurationStatusDetail)
                        .font(.caption)
                        .foregroundStyle(AudioControlTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let revision = configurationRevision {
                    Text("REV \(revision)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(configurationStatusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(configurationStatusColor.opacity(0.10))
                        .clipShape(Capsule())
                }
            }

            processorProgress

            configurationActions

            Divider().overlay(AudioControlTheme.rule)

            Button(action: performDeviceAction) {
                HStack {
                    Image(systemName: bluetooth.state.actionSymbol)
                    Text(connectionActionTitle)
                    Spacer()
                    Text(bluetooth.state.label)
                        .font(.caption)
                        .foregroundStyle(AudioControlTheme.muted)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(deviceStatusColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!bluetooth.state.isActionable)
            .accessibilityHint(bluetooth.state.detail)
        }
        .controlPanel()
    }

    @ViewBuilder
    private var configurationActions: some View {
        switch model.configurationState {
        case .sending, .saving, .reading, .verifying:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(configurationStatusColor)
                Text(configurationProgressLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AudioControlTheme.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(configurationStatusColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .edited:
            HStack(spacing: 10) {
                Button("Discard changes", action: model.discardDraft)
                    .buttonStyle(.bordered)
                    .tint(AudioControlTheme.muted)
                Button(action: model.applyDraft) {
                    Label("Set on processor", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AudioControlTheme.signal)
                .disabled(!model.canApply)
            }
        case .failed:
            Button(action: model.refreshConfiguration) {
                Label("Read processor again", systemImage: "arrow.clockwise.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AudioControlTheme.signal)
        case .confirmed(let revision):
            Label("Displayed settings are saved on processor · revision \(revision)", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AudioControlTheme.connected)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .disconnected:
            EmptyView()
        }
    }

    private var processorProgress: some View {
        HStack(spacing: 7) {
            ProcessorMilestone(
                title: "LINK",
                state: linkMilestoneState,
                color: AudioControlTheme.connected
            )
            milestoneConnector(completed: linkMilestoneState == .complete)
            ProcessorMilestone(
                title: "READ",
                state: readMilestoneState,
                color: AudioControlTheme.connected
            )
            milestoneConnector(completed: readMilestoneState == .complete)
            ProcessorMilestone(
                title: "SAVED",
                state: savedMilestoneState,
                color: AudioControlTheme.connected
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processor progress: link \(linkMilestoneState.label), read \(readMilestoneState.label), saved \(savedMilestoneState.label)")
    }

    private func milestoneConnector(completed: Bool) -> some View {
        Rectangle()
            .fill(completed ? AudioControlTheme.connected : AudioControlTheme.rule)
            .frame(height: 2)
    }

    private var lockedSettingsNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "lock.fill")
                .foregroundStyle(AudioControlTheme.caution)
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings are locked")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AudioControlTheme.ink)
                Text(lockedSettingsDetail)
                    .font(.caption)
                    .foregroundStyle(AudioControlTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AudioControlTheme.caution.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var deviceStatusColor: Color {
        switch bluetooth.state {
        case .connected:
            AudioControlTheme.connected
        case .synchronizing:
            AudioControlTheme.caution
        case .permissionDenied:
            AudioControlTheme.signal
        case .bluetoothOff:
            AudioControlTheme.caution
        default:
            AudioControlTheme.muted
        }
    }

    private var connectionActionTitle: String {
        switch bluetooth.state {
        case .idle: "Connect to processor"
        case .scanning: "Stop searching"
        case .connecting, .synchronizing: "Cancel connection"
        case .connected: "Disconnect processor"
        case .permissionDenied: "Open Bluetooth settings"
        case .bluetoothOff: "Bluetooth is off"
        case .bluetoothUnavailable: "Bluetooth unavailable"
        }
    }

    private var configurationStatusTitle: String {
        switch model.configurationState {
        case .disconnected: "No processor settings loaded"
        case .reading: "Reading processor settings"
        case .verifying: "Settings read from processor"
        case .confirmed: "Saved on processor"
        case .edited: "Changes not sent"
        case .sending: "Sending settings"
        case .saving: "Saving on processor"
        case .failed: "Settings were not saved"
        }
    }

    private var configurationStatusDetail: String {
        switch model.configurationState {
        case .disconnected(let revision):
            if let revision {
                "The values below are the last confirmed revision \(revision). Connect before editing or treating them as live."
            } else {
                "The values below are an example until a processor connects and reports its actual configuration."
            }
        case .reading:
            "Controls remain locked until the ESP reports its authoritative configuration."
        case .verifying(let revision):
            "Revision \(revision) was read. Checking that it has finished saving to flash."
        case .confirmed(let revision):
            "The displayed controls match revision \(revision) stored on the ESP."
        case .edited(let savedRevision):
            "These are local draft changes. The ESP is still using saved revision \(savedRevision)."
        case .sending(let revision):
            "Sending revision \(revision). Waiting for the Bluetooth write and firmware acknowledgement."
        case .saving(let revision):
            "The ESP accepted revision \(revision). Waiting for flash persistence confirmation."
        case .failed(let message, let savedRevision):
            if let savedRevision {
                "\(message) Revision \(savedRevision) is the last confirmed saved state; the current ESP state is unverified."
            } else {
                "\(message) The current ESP state is unverified."
            }
        }
    }

    private var configurationStatusIcon: String {
        switch model.configurationState {
        case .confirmed: "checkmark.seal.fill"
        case .edited: "slider.horizontal.3"
        case .sending, .saving, .reading, .verifying: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected: "bolt.slash.fill"
        }
    }

    private var configurationStatusColor: Color {
        switch model.configurationState {
        case .confirmed: AudioControlTheme.connected
        case .edited: AudioControlTheme.signal
        case .sending, .saving, .reading, .verifying: AudioControlTheme.caution
        case .failed: AudioControlTheme.signal
        case .disconnected: AudioControlTheme.muted
        }
    }

    private var configurationRevision: UInt32? {
        switch model.configurationState {
        case .verifying(let revision), .confirmed(let revision),
             .sending(let revision), .saving(let revision):
            revision
        case .edited(let revision):
            revision
        case .failed(_, let revision), .disconnected(let revision):
            revision
        case .reading:
            nil
        }
    }

    private var configurationProgressLabel: String {
        switch model.configurationState {
        case .reading: "Waiting for the processor configuration…"
        case .verifying: "Verifying saved state…"
        case .sending: "Writing the complete draft…"
        case .saving: "Waiting for flash save confirmation…"
        default: "Working…"
        }
    }

    private var lockedSettingsDetail: String {
        switch model.configurationState {
        case .sending, .saving:
            "The current draft cannot change while the ESP confirms and saves it."
        case .reading, .verifying:
            "The app is reading the ESP before enabling any controls."
        case .failed:
            "The last write could not be confirmed. Read the processor again before editing."
        default:
            "Connect and finish reading the processor before changing a value."
        }
    }

    private var linkMilestoneState: ProcessorMilestone.State {
        switch bluetooth.state {
        case .connected, .synchronizing: .complete
        case .connecting, .scanning: .active
        default: .pending
        }
    }

    private var readMilestoneState: ProcessorMilestone.State {
        switch model.configurationState {
        case .reading: .active
        case .disconnected: .pending
        default: .complete
        }
    }

    private var savedMilestoneState: ProcessorMilestone.State {
        switch model.configurationState {
        case .confirmed: .complete
        case .sending, .saving, .verifying: .active
        default: .pending
        }
    }

    private func performDeviceAction() {
        if bluetooth.state.opensSettings,
           let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        } else {
            bluetooth.scanOrDisconnect()
        }
    }
}

private struct ProcessorMilestone: View {
    enum State: Equatable {
        case pending
        case active
        case complete

        var label: String {
            switch self {
            case .pending: "pending"
            case .active: "in progress"
            case .complete: "complete"
            }
        }
    }

    let title: String
    let state: State
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.7)
        }
        .foregroundStyle(foregroundColor)
    }

    private var symbol: String {
        switch state {
        case .pending: "circle"
        case .active: "circle.dotted"
        case .complete: "checkmark.circle.fill"
        }
    }

    private var foregroundColor: Color {
        state == .complete ? color : AudioControlTheme.muted
    }
}
