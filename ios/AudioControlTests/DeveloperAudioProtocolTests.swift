import XCTest
@testable import AudioControl

final class DeveloperAudioProtocolTests: XCTestCase {
    func testCaptureCommandRoundTripsWithoutLosingAgentChoices() throws {
        let command = DeveloperAudioCommand(
            id: "capture-1",
            operation: .run,
            playbackResource: "upload-capture-1.wav",
            recordMicrophone: true,
            stopAfterPlayback: true,
            maximumDurationSeconds: 30,
            postPlaybackSeconds: 2.5,
            playbackGainDB: -24,
            requireBluetoothA2DP: true,
            requireBuiltInMicrophone: true
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DeveloperAudioCommand.self, from: data)

        XCTAssertEqual(decoded, command)
        XCTAssertNoThrow(try decoded.validated())
    }

    func testGenericPlaybackMayUseAnyUploadedWAV() throws {
        let command = DeveloperAudioCommand(
            operation: .run,
            playbackResource: "upload-any-signal.wav",
            playbackGainDB: -30
        )

        XCTAssertNoThrow(try command.validated())
        XCTAssertEqual(command.playbackResource, "upload-any-signal.wav")
    }

    func testRecordingOnlyRequiresAnExplicitSafetyDuration() {
        let command = DeveloperAudioCommand(
            operation: .run,
            recordMicrophone: true,
            stopAfterPlayback: false,
            maximumDurationSeconds: nil,
            requireBluetoothA2DP: false
        )

        XCTAssertThrowsError(try command.validated()) { error in
            XCTAssertEqual(error as? DeveloperAudioProtocolError, .missingRecordingDuration)
        }
    }

    func testRemotePlaybackCannotRequestPositiveDigitalGain() {
        let command = DeveloperAudioCommand(
            operation: .run,
            playbackResource: "upload-hot.wav",
            playbackGainDB: 3
        )

        XCTAssertThrowsError(try command.validated()) { error in
            XCTAssertEqual(error as? DeveloperAudioProtocolError, .invalidValue("playbackGainDB"))
        }
    }

    func testStatusEventRoundTripsRouteAndConsentState() throws {
        let status = DeveloperAudioRouteStatus(
            activity: .idle,
            inputName: "iPhone Microphone",
            inputType: "MicrophoneBuiltIn",
            outputName: "T59",
            outputType: "BluetoothA2DPOutput",
            outputVolume: 0.5,
            connectedPeer: "Justin's MacBook Pro",
            agentControlEnabled: true
        )
        let event = DeveloperAudioEvent(
            requestID: "status-1",
            kind: .status,
            status: status
        )

        let decoded = try JSONDecoder().decode(
            DeveloperAudioEvent.self,
            from: JSONEncoder().encode(event)
        )

        XCTAssertEqual(decoded, event)
    }
}
