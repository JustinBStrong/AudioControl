# AudioControl BLE protocol v2

All multibyte integers are little-endian. Signed fields use two's-complement.
Reserved bits must be zero. The firmware rejects malformed packets rather than
silently clamping them.

## GATT service

| Item | UUID | Properties |
| --- | --- | --- |
| AudioControl service | `7C1C0001-7A4D-4E6B-9D2A-5E4143554449` | primary service |
| Configuration | `7C1C0002-7A4D-4E6B-9D2A-5E4143554449` | read, write with response, notify |
| Telemetry | `7C1C0003-7A4D-4E6B-9D2A-5E4143554449` | read, notify |
| Command/status | `7C1C0004-7A4D-4E6B-9D2A-5E4143554449` | write with response, notify |

## Configuration packet (22 bytes)

A write changes the live audio configuration. On success, firmware notifies
the authoritative configuration and emits an OK status whose `request_id`
equals `revision`.

| Offset | Type | Field | Meaning |
| ---: | --- | --- | --- |
| 0 | `u8` | `version` | `2` |
| 1 | `u8` | `flags` | bits below |
| 2 | `u16` | `size` | `22` |
| 4 | `u32` | `revision` | client sequence/config revision |
| 8 | `u32` | `delay_us` | `0...250000` |
| 12 | `u16` | `cutoff_deci_hz` | `400...1600` (40.0-160.0 Hz) |
| 14 | `i16` | `output_trim_centi_db` | `-3600...0` (-36.00-0.00 dB) |
| 16 | `u16` | `shelf_transition_deci_hz` | `200...1000` (20.0-100.0 Hz) |
| 18 | `i16` | `shelf_gain_centi_db` | `-600...600` (-6.00-+6.00 dB) |
| 20 | `u16` | `crc16` | CRC-16/CCITT-FALSE over bytes 0-19 |

Configuration flags:

| Bit | Meaning |
| ---: | --- |
| 0 | delay enabled |
| 1 | low-pass crossover enabled |
| 2 | bypass all DSP |
| 3 | bass shelf enabled |
| 4-7 | reserved, zero |

The shelf uses a fixed standard low-shelf shape. Its transition field is the
frequency where half the selected dB change remains. Below the transition the
response approaches the full selected gain; above it the response approaches
0 dB. This shelf is the protocol's only tone-shaping stage.

CRC parameters are polynomial `0x1021`, initial value `0xFFFF`, no reflection,
and final XOR `0x0000` (CRC-16/CCITT-FALSE).

Canonical codec test vector: protocol 2, low-pass enabled, revision 1, zero
delay, 80.0 Hz cutoff, 0.00 dB trim, and a disabled 40 Hz shelf with zero gain
produces CRC `0x39BB` and this complete packet:

```text
02 02 16 00 01 00 00 00 00 00 00 00 20 03 00 00
90 01 00 00 bb 39
```

`revision` is monotonic for the current device configuration. The app starts
from the revision it read and increments it for each write. Firmware rejects a
stale revision and returns status 6. Slider changes remain a local draft until
the user explicitly sends the complete configuration.

## Telemetry packet (20 bytes)

Production firmware notifies telemetry once per second. The lower duty cycle
reduces BLE radio coupling into the compact board's analog input path.

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u8` | version = 2 |
| 1 | `u8` | telemetry flags |
| 2 | `u16` | size = 20 |
| 4 | `u32` | active configuration revision |
| 8 | `i16` | input left peak, centi-dBFS |
| 10 | `i16` | input right peak, centi-dBFS |
| 12 | `i16` | output left peak, centi-dBFS |
| 14 | `i16` | output right peak, centi-dBFS |
| 16 | `u32` | cumulative audio underrun count |

Telemetry flags:

| Bit | Meaning |
| ---: | --- |
| 0 | codec ready |
| 1 | audio engine running |
| 2 | input clip latched |
| 3 | output clip latched |
| 4 | underrun occurred since clear |
| 5 | live settings not yet persisted |
| 6-7 | reserved, zero |

Use `-32768` for an unavailable peak. Otherwise peak fields use centi-dBFS with
0 as full scale and negative values below full scale.

## Command and status packets (8 bytes)

App-to-device command write:

| Offset | Type | Field |
| ---: | --- | --- |
| 0 | `u8` | version = 2 |
| 1 | `u8` | opcode |
| 2 | `u16` | size = 8 |
| 4 | `u32` | app-generated request ID |

Opcodes are `1` save settings now, `2` restore defaults, `3` reboot, and `4`
clear latched clip/underrun indicators. Device-to-app status notifications use
the same shape, with byte 1 containing a status:

| Status | Meaning |
| ---: | --- |
| 0 | OK |
| 1 | unsupported protocol version |
| 2 | invalid packet length |
| 3 | CRC mismatch |
| 4 | field outside its allowed range |
| 5 | reserved field was nonzero |
| 6 | stale configuration revision |
| 7 | operation currently unavailable |
| 8 | internal error |

## Persistence and reconnect behavior

Configuration writes take effect immediately. Firmware persists the complete
22-byte packet after a two-second quiet period. The app does not label a draft
as saved until it receives a successful GATT write response, the matching OK
status, the matching authoritative configuration notification, and telemetry
for that revision with the dirty flag cleared. Command opcode 1 forces
persistence.

On reconnect, the app reads the configuration characteristic and treats that
packet as authoritative. Audio continues unchanged when the app disconnects.
The iPhone test-tone generator is app-local audio and is not part of BLE.
