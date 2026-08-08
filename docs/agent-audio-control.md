# Agent Control

Agent Control makes the iPhone's selected playback route and built-in microphone
available to a nearby Mac without baking a measurement procedure into the app.
The Mac decides what signal to generate, how quietly to play it, how long to
record, and what analysis to perform afterward.

The shipping app exposes only generic audio primitives:

- inspect the current input/output route and iPhone output volume;
- upload and play any WAV file;
- record the iPhone microphone for a caller-selected duration;
- play a WAV and record simultaneously, with an optional caller-selected tail;
- stop the current command; and
- return the unmodified microphone WAV to the Mac.

There is deliberately no fixed sweep, measurement preset, EQ decision, or
remote code interpreter.

## Language boundary

Swift is intentionally limited to the thin device boundary. The iPhone app
uses Swift because AVAudioSession, AVAudioEngine, microphone permission, A2DP
routing, and Multipeer Connectivity are native Apple APIs. The Mac CLI also
uses Swift only to speak that same Multipeer protocol reliably.

Signal generation and acoustic analysis belong on the Mac. Python can create
arbitrary WAV stimuli and process returned captures with NumPy, SciPy,
soundfile, or other established audio libraries. An agent can call the Swift
CLI as a subprocess from Python, so adding a new measurement or analysis does
not require changing or recompiling the iPhone app. Embedding Python, a Linux
container, JavaScript, or arbitrary code execution on the phone would add a
large runtime and security surface without improving that workflow.

## Consent and connection

1. Open **Agent** in AudioControl on the iPhone.
2. Turn on **Enable Agent Control**.
3. Run an `iphone-audio` command on the nearby Mac.
4. Approve that Mac by name in the iPhone app.

The CLI stores a stable, non-secret Multipeer identity in the Mac user's
Application Support directory. After the first approval, the app reconnects
that same peer automatically while Agent Control stays armed. Approval is
cleared when Agent Control is turned off, the app is backgrounded, or the app
terminates.

AudioControl uses Apple's encrypted Multipeer Connectivity session. Discovery
can use the local network, peer-to-peer Wi-Fi, and nearby-device connectivity,
so it does not require a conventional Wi-Fi router or a hard-coded IP address.
The app does not advertise while Agent Control is disabled. It also stops any
active recording/playback and disconnects the Mac when the app leaves the
foreground.

The Agent tab always shows the connected peer and current activity. Its Stop
button immediately ends remote audio. iOS supplies the normal first-use
microphone permission prompt.

## Mac CLI

Run commands from the `ios` directory:

```sh
swift run iphone-audio status

swift run iphone-audio play /absolute/path/stimulus.wav \
  --gain-db -30

swift run iphone-audio record /absolute/path/cabin.wav \
  --seconds 10

swift run iphone-audio capture \
  /absolute/path/stimulus.wav \
  /absolute/path/cabin.wav \
  --gain-db -30 \
  --tail 2
```

`capture` begins microphone recording before playback starts and stops after
the uploaded WAV plus the requested tail. The original WAV remains on the Mac;
the returned file is the iPhone microphone capture.

Playback gain defaults to **-30 dB** as a conservative safety choice. It is a
digital multiplier applied by the iPhone player; iPhone volume, Bluetooth
receiver level, DSP gain, and amplifier gain remain separate. The agent should
begin quietly and deliberately raise the command gain only when necessary.

Playback and capture reject non-A2DP output by default. Use
`--allow-any-output` only for bench testing. Recording rejects a non-built-in
microphone by default; use `--allow-any-input` only when that substitution is
intentional. The CLI refuses to overwrite an existing recording.

The Mac can generate a tone, multitone, sweep, impulse, music excerpt, or any
other stimulus with its preferred tooling and upload the resulting WAV. This is
the extension point: new acoustic experiments require Mac-side code, not a new
iPhone feature.

## Wire contract

The protocol version is `1`, advertised under Multipeer service type
`ac-audio-dev`. Commands and events are reliable JSON messages. WAVs travel as
Multipeer resources rather than JSON/base64 payloads.

The shared Codable definitions are in:

- `ios/AudioControl/DeveloperAudio/DeveloperAudioProtocol.swift`

The supported command operations are:

- `status`
- `run`
- `stop`

A `run` command chooses any combination supported by the generic engine:

- `playbackResource`: previously uploaded `upload-<request-id>.wav`, or `null`;
- `recordMicrophone`: whether to install an input tap and return a WAV;
- `stopAfterPlayback`: whether playback completion ends the command;
- `maximumDurationSeconds`: caller-selected recording duration or safety cap;
- `postPlaybackSeconds`: recording tail after playback;
- `playbackGainDB`: finite digital gain from `-80` through `0` dB;
- `requireBluetoothA2DP`; and
- `requireBuiltInMicrophone`.

Events report `uploadReady`, `accepted`, `completed`, `status`, or `error` and
include route/activity state when available. The reference CLI is intentionally
the canonical executable specification for discovery, invitation, resource
transfer, request/response handling, and recording download.

## Agent handoff prompt

The app's **Copy instructions for agent** button copies a short handoff prompt.
An agent receiving it should read this file, run `status` first, verify the
reported route, generate an appropriately quiet WAV on the Mac, and then use
`play`, `record`, or `capture` according to the experiment it has designed.
