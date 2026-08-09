# AudioControl

AudioControl is an iPhone-controlled DSP for aligning and tuning an aftermarket
car subwoofer without surrendering the full-range source signal to the factory
head unit.

The system places an ESP32 Audio Kit between a Bluetooth receiver and the
subwoofer amplifier. Native firmware delays and filters the stereo line input;
a SwiftUI app reads and writes the saved DSP configuration over Bluetooth Low
Energy. The app also exposes a consent-gated audio bridge so a nearby Mac agent
can make repeatable in-car acoustic measurements with the iPhone microphone.

> **Project status:** the DSP, BLE protocol, iPhone app, Mac audio-control CLI,
> portable simulator, and physical-board firmware are implemented. App Store
> distribution is being prepared. Physical vehicle tuning still depends on the
> specific source, amplifier, enclosure, and cabin.

## What it does

- Adds 0–500 ms of subwoofer delay without delaying the door speakers.
- Applies a configurable fourth-order Linkwitz–Riley low-pass crossover.
- Adds an optional low shelf for broad deep-bass shaping.
- Reserves digital headroom automatically and reports DSP clipping telemetry.
- Saves configuration on the ESP32 only after an explicit **Set on processor**
  action and confirms the persisted revision.
- Generates a continuous, adjustable 20–200 Hz iPhone test tone for amplifier
  gain setup.
- Lets an explicitly approved nearby Mac play arbitrary WAV test signals,
  record the iPhone microphone in measurement mode, and retrieve the raw WAV.

The phone does **not** execute downloaded code. Swift handles the iPhone audio
session and nearby transport; Python, REW, or another desktop audio tool can
generate stimuli and analyze recordings on the Mac.

## System shape

```text
Bluetooth source
    ├── 3.5 mm ──> factory head unit ──> door speakers
    └── RCA/line ─> ESP32 Audio Kit ───> subwoofer amplifier ──> subwoofer
                         ▲
                         └── BLE configuration from AudioControl for iPhone
```

The intended board is the ESP32 Audio Kit V2.2 A618 using the ESP32-A1S and
ES8388 codec. See [board integration](docs/board-integration.md) before adapting
the firmware to another revision; similar-looking boards do not always share
codec pin assignments or input routing.

## Repository map

| Path | Purpose |
| --- | --- |
| [`ios/`](ios/) | SwiftUI iPhone app, shared protocol, tests, and Mac CLI |
| [`firmware/`](firmware/) | Portable C++ DSP, host simulator, and ESP32 adapter |
| [`protocol/ble-v2.md`](protocol/ble-v2.md) | Canonical binary BLE contract |
| [`docs/agent-audio-control.md`](docs/agent-audio-control.md) | Mac/iPhone agent-audio API |
| [`docs/board-integration.md`](docs/board-integration.md) | Board switches, codec, and I/O notes |
| [`docs/noise-investigation.md`](docs/noise-investigation.md) | ADC/DMA noise investigation and verified firmware fix |
| [`fastlane/`](fastlane/) | Credential-free App Store release automation and metadata |

## Run the iPhone app

Open [`ios/AudioControl.xcodeproj`](ios/AudioControl.xcodeproj) and run the
`AudioControl` scheme on an iPhone or simulator. Regenerate the checked-in
project after changing `ios/project.yml`:

```sh
cd ios
xcodegen generate
swift test
```

An iOS simulator verifies the UI, packet codec, configuration state machine,
and Mac-to-iPhone resource transfer. A physical iPhone is required to verify
BLE against the ESP32, the selected Bluetooth/A2DP output, and the final
built-in-microphone route.

## Use the agent-audio bridge

On the iPhone, open **Agent**, enable **Agent Control**, and approve the named
Mac. Then run from the `ios` directory:

```sh
swift run iphone-audio status
swift run iphone-audio play input.wav --gain-db -30
swift run iphone-audio record recording.wav --seconds 5
swift run iphone-audio capture input.wav recording.wav --gain-db -30 --tail 1
swift run iphone-audio stop
```

The CLI intentionally provides primitives instead of a hard-coded cabin sweep.
An agent can generate a conservative WAV with desktop tooling, query the actual
iPhone input/output routes, capture the response, and analyze it without
changing the App Store binary. The protocol, consent model, and command schema
are documented in [agent-audio-control.md](docs/agent-audio-control.md).

## Build and simulate the DSP on a Mac

```sh
cmake -S firmware -B firmware/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build firmware/build
ctest --test-dir firmware/build --output-on-failure

firmware/build/audiocontrol_sim \
  --seconds 3 \
  --input-frequency 50 \
  --delay-ms 100 \
  --cutoff-hz 80 \
  --trim-db -3 \
  --output firmware/build/audiocontrol-sim.wav
```

The simulator executes the same portable delay and filter code used by the
ESP32. It does not emulate the ES8388 analog path, I2S DMA timing, radio, or
vehicle electrical environment.

## Build and flash the ESP32

No global PlatformIO installation is required:

```sh
uvx --from platformio --with pip platformio run \
  -d firmware -e esp32_audio_kit

uvx --from platformio --with pip platformio run \
  -d firmware -e esp32_audio_kit -t upload
```

With the board connected and running, the non-audible BLE/configuration smoke
test is:

```sh
xcrun swiftc tools/ble_smoke.swift -o /tmp/audiocontrol_ble_smoke
/tmp/audiocontrol_ble_smoke
```

## Safety

Automatic DSP headroom prevents mathematical clipping inside the digital
pipeline. It cannot prevent the source, codec, amplifier, or speaker from
clipping or exceeding electrical, thermal, or excursion limits. Start test
signals quietly, set amplifier gain with the final DSP configuration active,
and treat low-frequency boost as additional amplifier and driver demand.

## App Store releases

Fastlane configuration, metadata, rating answers, and privacy declarations are
tracked; credentials are not. See [`fastlane/README.md`](fastlane/README.md).
The public support page is [`docs/index.html`](docs/index.html), and the public
privacy policy is [`docs/privacy.html`](docs/privacy.html).

## License

This repository is **source-available, not open source**. The source is licensed
under the [PolyForm Strict License 1.0.0](LICENSE): noncommercial use is
permitted, but modification and redistribution are not licensed. See [NOTICE](NOTICE).
Commercial licensing may be available separately.
