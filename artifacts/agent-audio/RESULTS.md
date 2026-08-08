# Agent Control integration verification

Verified August 7, 2026 on an Apple Silicon Mac and one iPhone 16 Pro simulator
running iOS 18.2.

## Build and protocol

- `swift test`: 28 tests passed, including five Agent Control protocol tests.
- `xcodebuild ... test`: the complete iOS app and test bundle passed on the
  iPhone 16 Pro simulator.
- The rendered tab bar contains Tune, Test Tone, and Agent. No Measure tab or
  fixed sweep controls remain.

## Mac-to-iPhone integration

The checked-in `iphone-audio` CLI and shipping app completed these live
Multipeer tests:

1. Discovered the simulator only after Agent Control was enabled.
2. Displayed the Mac peer name and required explicit approval.
3. Returned live status showing the simulator Speaker route and output volume.
4. Uploaded an arbitrary 48 kHz PCM WAV generated outside the app.
5. Played the WAV at caller-selected `-30 dB` digital gain.
6. Played and recorded simultaneously using the iOS measurement audio mode.
7. Returned the microphone recording to a caller-selected Mac path.
8. Reconnected the same stored Mac identity without a second approval while
   Agent Control remained armed.

The returned test recording was a valid WAV:

```text
codec:       pcm_f32le
sample rate: 44100 Hz
channels:    1
duration:    0.500000 s
size:        92,296 bytes
```

The output sample rate intentionally follows the active iOS microphone route;
the protocol does not assume 44.1 or 48 kHz.

## Remaining physical-device verification

The simulator validates discovery, consent, command/event flow, arbitrary WAV
resource transfer, AVAudioEngine lifecycle, capture creation, download, and
route rejection controls. It cannot establish the final physical combination
of the iPhone built-in microphone with a car Bluetooth A2DP output. That path
must still be exercised on the actual iPhone and receiver before acoustic
measurement work begins.
