# Input-noise investigation

This investigation used the physical ESP32 Audio Kit V2.2 A618 board with its
3.5 mm line input unplugged. Captures came directly from the ES8388 ADC at the
production 48 kHz sample rate. The goal was to remove firmware-created
interference without filtering, gating, attenuating, or otherwise changing the
wanted PCM signal.

## Root cause

There were two independent timing signatures:

1. The original 512-frame I2S transmit buffer was refilled 93.75 times per
   second (`48000 / 512`). A narrow 93.75 Hz line appeared in the ADC only when
   the firmware performed transmit writes; disabling the DAC analog output did
   not remove it. Changing the buffer size moved the line to exactly
   `48000 / buffer_size`, proving that DMA-service current was coupling into the
   analog input.
2. Default BLE advertising and connected traffic produced strong periodic
   interference, particularly on the left input. Disabling BLE returned the
   input to its baseline. Lengthening the advertising and connection interval
   to one second produced the same baseline while preserving phone control.

## Measured result

The most relevant measurements are below. Figures are dBFS; more negative is
quieter.

| Condition | Dominant transport line | 20–100 Hz result |
| --- | ---: | ---: |
| Input only, no output writes | 94 Hz at -89.1 | baseline |
| Full duplex, 512-frame DMA | 94 Hz at -71.2 | -73.0 |
| Full duplex, 8-frame DMA | 6 kHz at -76.4 | -82.0 |
| BLE off, 8-frame DMA, left | none in bass band | -74.9 median |
| Default BLE advertising, left | radio bursts | -59.5 |
| One-second BLE advertising, left | none in bass band | -75.6 median |
| Default connected BLE, left | radio bursts | -58.0 median |
| One-second connected BLE, left | none in bass band | -75.0 median |

The absolute baselines differ between the mono-average DMA sweep and later
per-channel stereo captures, so comparisons should be made within each test
group. In both groups, the deterministic firmware interference is removed from
the subwoofer band.

## Production fix

Production firmware now uses eight-frame I2S buffers. That moves the DMA refill
event from 93.75 Hz to 6 kHz and restores the 20–100 Hz input band to the
input-only floor. BLE advertises at a one-second interval, requests a one-second
connected interval, and sends telemetry once per second. The iPhone app remains
in its connecting state until BLE characteristic discovery is actually
complete.

These changes alter when identical PCM blocks and control packets are moved;
they do not alter the audio samples. There is no noise gate, denoiser, EQ,
high-pass filter, or compensating attenuation in this fix. An unplugged analog
input still has the ordinary codec/floating-input noise floor rather than
mathematical digital silence.

## Verification boundary

The board passed the production BLE read/write/acknowledgement/persistence smoke
test with zero audio underruns. A driven line-input-to-headphone-output bench
test remains useful for establishing real analog levels and listening under
signal, followed by the final in-car delay and crossover calibration.
