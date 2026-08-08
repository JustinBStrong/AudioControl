# AudioControl

AudioControl is a software-first prototype for inserting an ESP32 Audio Kit
between a Bluetooth receiver and a subwoofer amplifier. The board adds an
adjustable delay, a steep low-pass crossover, a configurable deep-bass shelf,
and automatic digital headroom. A native iPhone app controls those settings over BLE, automatically
reserves digital headroom for bass-shelf boosts, and can generate a continuous
subwoofer test tone. Its Agent Control API lets an approved nearby Mac use the
iPhone's selected Bluetooth playback route and built-in microphone without
baking a particular measurement procedure into the app.

## Repository layout

- `ios/` — SwiftUI iPhone app and packet/control tests
- `firmware/` — portable C++ DSP, Apple Silicon simulator, and ESP32 adapter
- `protocol/ble-v2.md` — shared binary BLE contract
- `docs/board-integration.md` — ESP32 Audio Kit V2.2/ES8388 wiring notes
- `docs/noise-investigation.md` — measured DMA/BLE noise cause and verified fix
- `docs/agent-audio-control.md` — Mac/iPhone Agent Control protocol and CLI

The phone app and firmware are independent build targets. The app launches and
generates its tone without an ESP32 connected; BLE controls become available
when the physical processor is powered nearby. Agent Control is separately
armed by the user and does not require the ESP32 control link.

## Run the iPhone app

Open `ios/AudioControl.xcodeproj` in Xcode and run the `AudioControl` scheme on
an iPhone or iOS Simulator. If `ios/project.yml` changes, regenerate the project
with:

```sh
cd ios
xcodegen generate
```

Run the portable Swift tests on Apple Silicon with:

```sh
cd ios
swift test
```

The simulator can validate the UI and control logic. A physical iPhone is
required to verify BLE against the board, Bluetooth/A2DP routing, and the final
microphone capture path. See `docs/agent-audio-control.md` for the Mac CLI.

## Build and simulate the DSP on Apple Silicon

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

This executes the same portable delay/filter code used by the ESP32 and
writes a 48 kHz, 16-bit stereo WAV. It does not emulate the ES8388 codec, I2S,
BLE radio, or real-time scheduling.

## Build the ESP32 firmware

No global PlatformIO installation is required:

```sh
uvx --from platformio --with pip platformio run \
  -d firmware -e esp32_audio_kit
```

Once the board is connected by USB, flash it with:

```sh
uvx --from platformio --with pip platformio run \
  -d firmware -e esp32_audio_kit -t upload
```

Run the non-audible physical-board BLE/configuration smoke test with:

```sh
xcrun swiftc tools/ble_smoke.swift -o /tmp/audiocontrol_ble_smoke
/tmp/audiocontrol_ble_smoke
```

The physical-board smoke test verifies ES8388 discovery, active I2S processing,
BLE control/telemetry, deferred flash persistence, and reboot recovery. Analog
levels and end-to-end audible delay/filter behavior still require a connected
line-level source and output load.
