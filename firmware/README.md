# AudioControl firmware

This directory contains one portable C++17 DSP engine and two ways to run it:

- `host/` builds on Apple Silicon and processes generated stereo audio into a
  WAV file. It exercises the same DSP code used by the board.
- `esp32/` is the PlatformIO adapter for the ESP32 Audio Kit, ES8388 codec,
  duplex I2S, BLE GATT, and NVS persistence.

The host build is a deterministic functional simulation of the audio engine.
It does not emulate ESP32 timing, DMA, the ES8388 analog stages, Bluetooth
radio behavior, or FreeRTOS scheduling.

## Implemented DSP

- 48 kHz stereo floating-point block processing
- 0-250 ms delay with one-sample resolution and a 20 ms dual-tap transition
- 4th-order Linkwitz-Riley low-pass crossover, adjustable from 40-160 Hz
- Configurable low-shelf bass lift, 20-100 Hz transition and -6 to +6 dB
- -36 to 0 dB internal output attenuation for automatic shelf headroom and sub level
- 20 ms transitions for filter changes, output trim, delay enable, and DSP
  bypass
- Per-block input/output peaks, latched clipping, and underrun telemetry
- Strict, versioned BLE configuration codec with CRC-16/CCITT-FALSE

Defaults match `../protocol/ble-v2.md`: delay off, 80 Hz low-pass on, 0 dB
trim, and a disabled 40 Hz low shelf.

The iPhone app calculates the maximum of the complete shelf/crossover response,
adds a 0.5 dB safety margin, and sends the required negative output gain. This
prevents arithmetic clipping inside the DSP; it does not limit amplifier power
or protect the loudspeaker from thermal or excursion limits.

The filters and gain stages run in floating point. The delay ring stores
codec-resolution 16-bit stereo PCM, requiring about 48 KiB at the 250 ms
maximum instead of 96 KiB of scarce internal RAM.

## Native Apple Silicon build

```sh
cmake -S firmware -B firmware/build -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build firmware/build
ctest --test-dir firmware/build --output-on-failure
```

Run the offline simulator from the repository root:

```sh
firmware/build/audiocontrol_sim \
  --seconds 3 \
  --input-frequency 50 \
  --delay-ms 100 \
  --cutoff-hz 80 \
  --shelf-transition-hz 40 \
  --shelf-gain-db 2 \
  --trim-db -3 \
  --output firmware/build/audiocontrol-sim.wav
```

The output is 16-bit stereo PCM at 48 kHz. A delay above zero is enabled unless
`--delay-disabled` is supplied, and a nonzero shelf gain enables the shelf
unless `--shelf-disabled` is supplied. Run with `--help` for all bypass options.
This makes it easy to inspect the result in an editor or feed it to analysis
tools without having the board connected.

## ESP32 build

PlatformIO is run ephemerally so it does not need a global installation. The
extra `pip` package is required while PlatformIO installs its current esptool
dependencies:

```sh
uvx --from platformio --with pip platformio run \
  -d firmware -e esp32_audio_kit
```

To flash after the board is attached:

```sh
uvx --from platformio --with pip platformio run \
  -d firmware -e esp32_audio_kit -t upload
```

The `min_spiffs.csv` partition layout provides two 1.875 MiB application slots,
so this BLE-enabled build fits while retaining an OTA-capable partition layout.
An OTA transport is not implemented yet.

## Board profile

The board uses the ESP32-A1S module and ES8388 codec at 7-bit I2C address
`0x10`. The official Ai-Thinker Audio Kit wiring is:

| Function | GPIO |
| --- | ---: |
| I2C SDA | 33 |
| I2C SCL | 32 |
| I2S MCLK | 0 |
| I2S BCLK | 27 |
| I2S word select | 25 |
| ESP32 audio data out / codec data in | 26 |
| Codec audio data out / ESP32 data in | 35 |
| Speaker amplifier enable | 21 |

The embedded adapter probes `0x10` first on SDA33/SCL32 and selects
`AudioKitEs8388V1`. If that fails, it probes the known clone profile on
SDA18/SCL23 and selects `AudioKitEs8388V2`. The library's `V1`/`V2` names are
wiring profiles and are unrelated to the `ESP32-Audio-Kit_V2.2` PCB revision.

The ES8388 is configured for stereo `ADC_INPUT_LINE2`, 48 kHz/16-bit I2S, and
`DAC_OUTPUT_LINE1` for the headphone output. The on-board speaker amplifier is
disabled.

## Embedded behavior

The adapter in `esp32/main.cpp` is real, compile-checked implementation code:

- initializes the codec and full-duplex I2S stream;
- processes fixed 8-frame stereo blocks with no audio-loop allocation;
- queues BLE writes and applies them between audio blocks;
- exposes the service and three characteristics documented in
  `../protocol/ble-v2.md`;
- advertises and maintains BLE connections at a one-second cadence and sends
  telemetry every second, keeping radio-current bursts out of the bass input;
- saves a CRC-protected configuration to NVS after two quiet seconds or on an
  explicit save command;
- continues audio processing without an iPhone connection.

The production firmware has been flashed and exercised on the delivered V2.2
A618 board. Testing verified:

- the official SDA33/SCL32 ES8388 profile and LINE2 input routing;
- sustained full-duplex I2S with zero reported underruns;
- BLE configuration read/write, acknowledgement, telemetry, and NVS
  persistence while audio remains active;
- native 48 kHz capture of DMA and BLE interference, followed by repeatable
  verification of the timing fix described in `../docs/noise-investigation.md`.

The remaining integration test is a driven line-level source through the
headphone output and amplifier. That test establishes analog levels, audible
noise under signal, and the final in-car delay/crossover settings; it is not
something a host simulator can reproduce.

## Source layout

```text
include/audiocontrol/  Portable public interfaces and BLE wire definitions
src/                   Portable DSP and protocol implementation
tests/                 Native deterministic tests
host/                  Offline WAV simulator
esp32/                 Arduino/PlatformIO hardware adapter
```

The upstream audio libraries are pinned to exact Git commits in
`platformio.ini` so a future library release cannot silently change the board
profile or I2S API used by this spike.
