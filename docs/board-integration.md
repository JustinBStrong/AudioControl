# ESP32 Audio Kit integration

This project targets the Ai-Thinker `ESP32-Audio-Kit_V2.2` board populated with
the ESP32-A1S module and ES8388 codec described by the product listing.

## Audio connectors

The official V2.2 schematic identifies these 3.5 mm jacks:

- `J1 LINEIN`: stereo line input. Left and right are AC-coupled through C12 and
  C13 to the module `LINEINL` and `LINEINR` pins.
- On the measured V2.2 A618/ES8388 board, that jack is selected through
  `ADC_INPUT_LINE2`. The ESP32-A1S ES8388 module family is documented to share
  or mix some onboard microphone wiring with this ADC pair; `ADC_INPUT_LINE1`
  removes the microphone signal but does not receive the external jack.
- `J2 EARPHONES`: stereo codec headphone output, connected to module `HPOUTR`
  and `HPOUTL`. Its insertion detect signal is GPIO 39.
- `J3` and `J4`: outputs of the two external speaker power amplifiers. They are
  not used by AudioControl.

GPIO 21 is the external speaker-amplifier shutdown/control net. Firmware should
leave those amplifiers disabled because the application uses the headphone
output.

## Five-position DIP switch

The `S1` switch bank routes the shared GPIO13 and GPIO15 signals to optional
onboard peripherals. Moving a numbered switch toward `ON` closes that route:

| Switch | Route enabled |
| ---: | --- |
| 1 | GPIO13 to the onboard `KEY1` button |
| 2 | GPIO13 to microSD `DATA3` |
| 3 | GPIO15 to microSD `CMD` |
| 4 | GPIO13 to the JTAG `MTCK` header route |
| 5 | GPIO15 to the JTAG `MTDO` header route |

Positions 1, 2, and 4 therefore compete for GPIO13, while positions 3 and 5
compete for GPIO15. They are routing selectors rather than five unrelated
features. AudioControl does not use the microSD slot, onboard key, or JTAG, so
the switch bank does not affect its ES8388/I2S audio path and can remain in its
factory position.

Sources:

- [Ai-Thinker ESP32 Audio Kit V2.2 schematic](https://docs.ai-thinker.com/_media/esp32-audio-kit_v2.2_sch.pdf)
- [Ai-Thinker ESP32-A1S AudioKit repository](https://github.com/Ai-Thinker-Open/ESP32-A1S-AudioKit)

## Correct ES8388 profile

The official Ai-Thinker ES8388 instructions specify this wiring:

| Signal | ESP32 GPIO |
| --- | ---: |
| I2C SDA | 33 |
| I2C SCL | 32 |
| I2S BCLK | 27 |
| I2S word select / LRCLK | 25 |
| I2S data out (ESP32 to codec) | 26 |
| I2S data in (codec to ESP32) | 35 |
| I2S MCLK | 0 |

The ES8388 uses 7-bit I2C address `0x10`. Some data sheets express this as the
8-bit write/read values `0x20` and `0x21`; Arduino and ESP-IDF APIs require the
7-bit value.

The current `arduino-audio-driver` library calls the official wiring
`AudioKitEs8388V1`. Its `AudioKitEs8388V2` name means an alternate pin layout
(SCL 23, SDA 18, BCLK 5); it does **not** mean Ai-Thinker PCB revision V2.2.
Default to the V1 library profile even though the board says V2.2.

Bring-up should probe address `0x10` on SDA 33/SCL 32 before starting I2S. A
missing acknowledgement is a useful, explicit codec/profile error. Trying the
alternate profile after that failure is acceptable, but the selected profile
must be logged rather than hidden.

Sources:

- [Official Ai-Thinker ES8388 pin instructions](https://github.com/Ai-Thinker-Open/ESP32-A1S-AudioKit#step-5-adapter-esp-a1s-module)
- [`AudioKitEs8388V1` board definition](https://github.com/pschatzmann/arduino-audio-driver/blob/main/src/AudioBoards/AudioKitEs8388v1.h)
- [`AudioKitEs8388V2` alternate definition](https://github.com/pschatzmann/arduino-audio-driver/blob/main/src/AudioBoards/AudioKitEs8388v2.h)
- [ES8388 driver address definition](https://github.com/pschatzmann/arduino-audio-driver/blob/main/src/Codecs/es8388/ES8388.h)

## Software choice

Use PlatformIO with the Arduino ESP32 framework for the first hardware spike.
It gives us straightforward BLE and serial bring-up while still permitting
direct use of ESP-IDF I2S/FreeRTOS APIs where deterministic buffering matters.

Use `pschatzmann/arduino-audio-driver` for ES8388 register initialization and
the `AudioKitEs8388V1` pin definition. Keep AudioControl's delay, crossover, EQ,
configuration, and wire protocol in portable C++ owned by this repository.
`arduino-audio-tools` is useful as a reference and for quick passthrough
experiments, but the product does not need to depend on its streaming/DSP
abstractions.

Both libraries use GPL-3.0 licensing. That is compatible with the stated plan
to publish the firmware source, but it is a real distribution requirement.

## What can run on Apple Silicon

There are three distinct validation layers:

1. Build and run portable DSP/protocol code as native arm64 macOS tests. This
   validates delay math, filter response, packet encoding, validation, CRC, and
   state transitions using deterministic PCM files or generated samples.
2. Cross-compile the complete PlatformIO target for Xtensa ESP32 on the Mac.
   This validates the real Arduino, BLE, codec-driver, I2S, and firmware APIs at
   compile/link time, but the resulting binary cannot execute natively.
3. Flash the real board for codec, I2S timing, analog I/O, and BLE radio tests.

Espressif provides arm64 macOS builds of its ESP32 QEMU fork, but the emulator
does not implement Bluetooth, I2C, or I2S. It can boot selected ESP-IDF images
and exercise CPU/flash/FreeRTOS logic, but it cannot simulate this product's
codec or phone connection. For AudioControl, host-native tests plus a real-board
smoke test provide substantially more useful coverage than a QEMU hardware
facsimile.

Sources:

- [ESP-IDF QEMU guide](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/tools/qemu.html)
- [Espressif QEMU supported-feature table](https://github.com/espressif/esp-toolchain-docs/blob/main/qemu/README.md#supported-features)

## Physical-board BLE smoke test

With the flashed board powered over USB, compile and run the macOS CoreBluetooth
smoke client:

```sh
xcrun swiftc tools/ble_smoke.swift -o /tmp/audiocontrol_ble_smoke
/tmp/audiocontrol_ble_smoke
```

It reads the current configuration, writes the identical DSP settings with a
new revision, verifies the firmware acknowledgement and authoritative
configuration notification, waits for deferred flash persistence, and checks
that codec-ready, audio-running, and zero-underrun telemetry remain healthy.
