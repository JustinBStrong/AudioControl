import SwiftUI
import UIKit

struct AgentControlPanel: View {
    @ObservedObject var agent: DeveloperAudioBridge
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            controlCard
            if agent.pendingPeerName != nil {
                approvalCard
            }
            routeCard
            instructionsCard
        }
        .onAppear(perform: agent.refreshStatus)
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: statusIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("MAC AGENT ACCESS")
                        .font(.caption2.weight(.bold))
                        .tracking(1.4)
                        .foregroundStyle(statusColor)
                    Text(agent.connectionState.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AudioControlTheme.ink)
                    Text(agent.lastEvent)
                        .font(.caption)
                        .foregroundStyle(AudioControlTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            Toggle("Enable Agent Control", isOn: Binding(
                get: { agent.isEnabled },
                set: agent.setEnabled
            ))
            .font(.subheadline.weight(.semibold))
            .tint(AudioControlTheme.connected)

            if agent.isBusy {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(AudioControlTheme.signal)
                    Text(activityText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AudioControlTheme.ink)
                    Spacer()
                    Button("Stop", role: .destructive, action: agent.stopRemoteAudio)
                        .buttonStyle(.bordered)
                }
                .padding(12)
                .background(AudioControlTheme.signal.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Text("Control is off by default. A nearby Mac must request access, and you must approve it before it can play audio or use the microphone.")
                .font(.caption)
                .foregroundStyle(AudioControlTheme.muted)
        }
        .controlPanel()
    }

    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection request", systemImage: "person.badge.key.fill")
                .font(.headline)
                .foregroundStyle(AudioControlTheme.ink)
            Text("\(agent.pendingPeerName ?? "A nearby Mac") wants to control playback and microphone recording for this app session.")
                .font(.subheadline)
                .foregroundStyle(AudioControlTheme.muted)
            HStack(spacing: 10) {
                Button("Reject", action: agent.rejectPendingConnection)
                    .buttonStyle(.bordered)
                    .tint(AudioControlTheme.muted)
                Button(action: agent.approvePendingConnection) {
                    Label("Allow this Mac", systemImage: "checkmark.shield.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AudioControlTheme.connected)
            }
        }
        .controlPanel()
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("IPHONE AUDIO ROUTE")
                .font(.caption2.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(AudioControlTheme.muted)
            routeRow(
                icon: "mic.fill",
                title: "Microphone",
                value: agent.routeStatus.inputName
            )
            Divider().overlay(AudioControlTheme.rule)
            routeRow(
                icon: "speaker.wave.2.fill",
                title: "Playback",
                value: agent.routeStatus.outputName
            )
            Divider().overlay(AudioControlTheme.rule)
            routeRow(
                icon: "waveform",
                title: "Agent activity",
                value: activityText
            )
            Text("The built-in microphone is selected when a recording command begins. Playback commands can require Bluetooth A2DP and will fail rather than silently use the iPhone speaker.")
                .font(.caption)
                .foregroundStyle(AudioControlTheme.muted)
        }
        .controlPanel()
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Give your agent control", systemImage: "terminal.fill")
                .font(.headline)
                .foregroundStyle(AudioControlTheme.ink)
            Text("The Mac tool provides generic status, WAV playback, microphone recording, simultaneous play-and-record, Stop, and recording download commands. It contains no fixed sweep or tuning routine.")
                .font(.subheadline)
                .foregroundStyle(AudioControlTheme.muted)
            Button(action: copyAgentInstructions) {
                Label(
                    copied ? "Instructions copied" : "Copy instructions for agent",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AudioControlTheme.signal)
            Text("The public protocol and CLI are documented in docs/agent-audio-control.md in the source-available AudioControl repository.")
                .font(.caption)
                .foregroundStyle(AudioControlTheme.muted)
        }
        .controlPanel()
    }

    private func routeRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(AudioControlTheme.connected)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AudioControlTheme.muted)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AudioControlTheme.ink)
            }
            Spacer()
        }
    }

    private var activityText: String {
        switch agent.activity {
        case .idle: "Idle"
        case .playing: "Agent is playing audio"
        case .recording: "Agent is recording the microphone"
        case .playingAndRecording: "Agent is playing and recording"
        }
    }

    private var statusColor: Color {
        switch agent.connectionState {
        case .connected: agent.isBusy ? AudioControlTheme.signal : AudioControlTheme.connected
        case .approvalRequired, .connecting: AudioControlTheme.caution
        case .failed: AudioControlTheme.signal
        case .disabled, .advertising: AudioControlTheme.muted
        }
    }

    private var statusIcon: String {
        switch agent.connectionState {
        case .connected: agent.isBusy ? "waveform.circle.fill" : "checkmark.circle.fill"
        case .approvalRequired: "person.badge.key.fill"
        case .connecting, .advertising: "antenna.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle.fill"
        case .disabled: "power"
        }
    }

    private func copyAgentInstructions() {
        UIPasteboard.general.string = """
        I have the AudioControl iPhone app open. Read docs/agent-audio-control.md in the AudioControl repository, then use the `iphone-audio` CLI from the ios directory to control the iPhone microphone and selected Bluetooth playback route. Start with `swift run iphone-audio status`. Ask me to enable Agent Control and approve this Mac when the app prompts. Do not assume a fixed measurement signal; generate and upload whatever conservative-level WAV is appropriate for the task.
        """
        copied = true
    }
}
