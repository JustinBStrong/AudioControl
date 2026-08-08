import Foundation

public enum DeveloperAudioProtocol {
    public static let version = 1
    public static let serviceType = "ac-audio-dev"
}

public enum DeveloperAudioOperation: String, Codable, Sendable {
    case status
    case run
    case stop
}

public enum DeveloperAudioEventKind: String, Codable, Sendable {
    case status
    case uploadReady
    case accepted
    case completed
    case error
}

public enum DeveloperAudioActivity: String, Codable, Sendable {
    case idle
    case playing
    case recording
    case playingAndRecording
}

public struct DeveloperAudioCommand: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let operation: DeveloperAudioOperation
    public let playbackResource: String?
    public let recordMicrophone: Bool
    public let stopAfterPlayback: Bool
    public let maximumDurationSeconds: Double?
    public let postPlaybackSeconds: Double
    public let playbackGainDB: Double
    public let requireBluetoothA2DP: Bool
    public let requireBuiltInMicrophone: Bool

    public init(
        id: String = UUID().uuidString,
        operation: DeveloperAudioOperation,
        playbackResource: String? = nil,
        recordMicrophone: Bool = false,
        stopAfterPlayback: Bool = true,
        maximumDurationSeconds: Double? = nil,
        postPlaybackSeconds: Double = 0,
        playbackGainDB: Double = -30,
        requireBluetoothA2DP: Bool = true,
        requireBuiltInMicrophone: Bool = true
    ) {
        self.protocolVersion = DeveloperAudioProtocol.version
        self.id = id
        self.operation = operation
        self.playbackResource = playbackResource
        self.recordMicrophone = recordMicrophone
        self.stopAfterPlayback = stopAfterPlayback
        self.maximumDurationSeconds = maximumDurationSeconds
        self.postPlaybackSeconds = postPlaybackSeconds
        self.playbackGainDB = playbackGainDB
        self.requireBluetoothA2DP = requireBluetoothA2DP
        self.requireBuiltInMicrophone = requireBuiltInMicrophone
    }

    public func validated() throws -> DeveloperAudioCommand {
        guard protocolVersion == DeveloperAudioProtocol.version else {
            throw DeveloperAudioProtocolError.unsupportedVersion(protocolVersion)
        }
        guard !id.isEmpty, id.utf8.count <= 128 else {
            throw DeveloperAudioProtocolError.invalidValue("id")
        }
        guard playbackGainDB.isFinite, (-80...0).contains(playbackGainDB) else {
            throw DeveloperAudioProtocolError.invalidValue("playbackGainDB")
        }
        guard postPlaybackSeconds.isFinite, (0...30).contains(postPlaybackSeconds) else {
            throw DeveloperAudioProtocolError.invalidValue("postPlaybackSeconds")
        }
        if let maximumDurationSeconds {
            guard maximumDurationSeconds.isFinite,
                  (0.1...1_800).contains(maximumDurationSeconds) else {
                throw DeveloperAudioProtocolError.invalidValue("maximumDurationSeconds")
            }
        }

        if operation == .run {
            guard playbackResource != nil || recordMicrophone else {
                throw DeveloperAudioProtocolError.emptyRun
            }
            if stopAfterPlayback, playbackResource == nil {
                throw DeveloperAudioProtocolError.invalidValue("stopAfterPlayback")
            }
            if playbackResource == nil, recordMicrophone, maximumDurationSeconds == nil {
                throw DeveloperAudioProtocolError.missingRecordingDuration
            }
            if !stopAfterPlayback, maximumDurationSeconds == nil {
                throw DeveloperAudioProtocolError.invalidValue("maximumDurationSeconds")
            }
        }
        return self
    }
}

public struct DeveloperAudioRouteStatus: Codable, Equatable, Sendable {
    public let activity: DeveloperAudioActivity
    public let inputName: String
    public let inputType: String
    public let outputName: String
    public let outputType: String
    public let outputVolume: Float
    public let connectedPeer: String?
    public let agentControlEnabled: Bool

    public init(
        activity: DeveloperAudioActivity,
        inputName: String,
        inputType: String,
        outputName: String,
        outputType: String,
        outputVolume: Float,
        connectedPeer: String?,
        agentControlEnabled: Bool
    ) {
        self.activity = activity
        self.inputName = inputName
        self.inputType = inputType
        self.outputName = outputName
        self.outputType = outputType
        self.outputVolume = outputVolume
        self.connectedPeer = connectedPeer
        self.agentControlEnabled = agentControlEnabled
    }
}

public struct DeveloperAudioEvent: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let kind: DeveloperAudioEventKind
    public let message: String?
    public let resourceName: String?
    public let status: DeveloperAudioRouteStatus?

    public init(
        requestID: String,
        kind: DeveloperAudioEventKind,
        message: String? = nil,
        resourceName: String? = nil,
        status: DeveloperAudioRouteStatus? = nil
    ) {
        self.protocolVersion = DeveloperAudioProtocol.version
        self.requestID = requestID
        self.kind = kind
        self.message = message
        self.resourceName = resourceName
        self.status = status
    }
}

public enum DeveloperAudioProtocolError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidValue(String)
    case emptyRun
    case missingRecordingDuration

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Unsupported agent audio protocol version \(version)."
        case .invalidValue(let field):
            "The agent audio command contains an invalid \(field)."
        case .emptyRun:
            "A run command must play audio, record audio, or do both."
        case .missingRecordingDuration:
            "A recording-only command must include a maximum duration."
        }
    }
}
