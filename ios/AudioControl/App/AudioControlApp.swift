import SwiftUI

@main
struct AudioControlApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AudioControlViewModel()
    @StateObject private var tone = TestToneViewModel()
    @StateObject private var developerAudio = DeveloperAudioBridge()

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                tone: tone,
                developerAudio: developerAudio
            )
                .preferredColorScheme(.light)
                .onAppear {
                    developerAudio.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: .developerAudioWillStart)) { _ in
                    tone.stopImmediately()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                tone.stopImmediately()
                developerAudio.suspend()
            } else {
                developerAudio.start()
            }
        }
    }
}
