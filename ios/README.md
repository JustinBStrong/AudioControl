# AudioControl for iPhone

Native SwiftUI controller for the AudioControl ESP32 processor. The app sends
DSP settings over Bluetooth Low Energy, generates local test signals, and lets
an explicitly approved Mac agent control generic iPhone playback and microphone
recording primitives.

## Open and run

`AudioControl.xcodeproj` is checked in and can be opened directly in Xcode 26.3
or newer for App Store submission. If `project.yml` changes, regenerate it with:

```sh
cd ios
xcodegen generate
```

Run the build and model/protocol tests with:

```sh
xcodebuild \
  -project AudioControl.xcodeproj \
  -scheme AudioControl \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .derived \
  test CODE_SIGNING_ALLOWED=NO
```

The portable control and BLE codec layer also compiles and tests natively on
Apple Silicon without launching an iOS Simulator:

```sh
cd ios
swift test
```

The Simulator verifies the UI, packet codec, and control-model behavior. A
physical iPhone is required to validate Core Bluetooth against the ESP32 and
to verify the A2DP audio route and absolute playback level.

## Tune interface

- Dedicated Tune, Test Tone, and Agent tabs
- Processor-state card that distinguishes disconnected examples, configuration
  reads, local drafts, writes, and confirmed flash persistence
- DSP controls remain locked until the ESP's saved configuration is read and
  verified
- Changes stay local until **Set on processor** is tapped; a saved revision is
  shown only after the BLE write, firmware acknowledgement, authoritative
  configuration notification, and persistence telemetry all agree
- Explicit subwoofer delay and low-pass enable switches
- Log-frequency response graph that separates the combined filter shape, shaded
  low-shelf contribution, and low-pass response
- Configurable Deep Bass Lift amount and 20-100 Hz transition
- Automatic headroom derived from the maximum of the combined filter curve,
  including a 0.5 dB safety margin
- Separate sub-level attenuation, live clipping telemetry, and a visible total
  DSP output gain

Automatic headroom prevents digital clipping inside the DSP. It does not
prevent the amplifier from clipping or the subwoofer from exceeding its thermal
or mechanical limits. Amplifier gain should be set with the final tuning active.

## Test-tone behavior

- Continuous 20-200 Hz sine; default 40 Hz
- Frequency slider and numeric input remain synchronized
- Click-resistant frequency and level changes using per-sample smoothing
- Explicit -20, -10, -5, and 0 dBFS generated levels; default 0 dBFS for
  conservative full-scale gain calibration
- 35 ms fade before a user-requested stop
- Immediate safe stop for interruption, media reset, or app backgrounding
- Normal `.playback` audio session and standard output-route picker

The selected dBFS value describes the generated digital signal. iPhone volume,
the Bluetooth receiver volume, and amplifier gain still affect voltage at the
amplifier input.

## Agent Control

- Off by default and advertised only after the user enables it
- Requires approval of the requesting Mac by peer name
- Uses an encrypted Apple Multipeer Connectivity session, without a fixed IP or
  conventional Wi-Fi-router requirement
- Reports the actual input/output route and refuses an unexpected route by
  default
- Accepts any Mac-generated WAV rather than embedding a measurement sweep
- Can play, record, play-and-record, stop, and return the raw microphone WAV
- Uses `.playAndRecord` with iOS `.measurement` mode when the microphone is
  requested
- Shows active playback/recording in the app with an immediate Stop control

The Mac CLI and complete contract are documented in
`../docs/agent-audio-control.md`.

## Delay control

Moving the delay slider above 0 ms enables the delay stage in the local draft;
moving it back to 0 ms disables it in that draft. Tap **Set on processor** to
send the complete draft. The explicit **Subwoofer delay** switch can temporarily
bypass delay without discarding the selected time.

## BLE protocol

The client implements the canonical contract in `../protocol/ble-v2.md`:

- 22-byte configuration with CRC-16/CCITT-FALSE
- 20-byte telemetry notifications
- 8-byte command/status messages
- Reliable writes with response and MTU-length validation
