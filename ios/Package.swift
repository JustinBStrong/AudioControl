// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioControlCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AudioControlCore", targets: ["AudioControl"]),
        .executable(name: "iphone-audio", targets: ["iPhoneAudioCLI"]),
    ],
    targets: [
        .target(
            name: "AudioControl",
            path: "AudioControl",
            exclude: [
                "App",
                "Audio",
                "Theme",
                "Views",
                "Bluetooth/AudioControlBLEClient.swift",
                "Models/AudioControlViewModel.swift",
                "Models/TestToneViewModel.swift",
                "DeveloperAudio/DeveloperAudioBridge.swift",
                "DeveloperAudio/DeveloperAudioEngine.swift",
                "Info.plist",
            ],
            sources: [
                "Models/DSPConfiguration.swift",
                "Models/DSPResponse.swift",
                "Models/ConfigurationSession.swift",
                "Models/ToneControlModel.swift",
                "Bluetooth/AudioControlBLEProtocol.swift",
                "DeveloperAudio/DeveloperAudioProtocol.swift",
            ]
        ),
        .executableTarget(
            name: "iPhoneAudioCLI",
            dependencies: ["AudioControl"],
            path: "Tools/iPhoneAudioCLI"
        ),
        .testTarget(
            name: "AudioControlTests",
            dependencies: ["AudioControl"],
            path: "AudioControlTests"
        ),
    ]
)
