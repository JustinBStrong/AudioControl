# AudioControl agent guide

This repository contains three coupled implementations:

1. `firmware/` owns the real-time DSP and ESP32/ES8388 integration.
2. `protocol/ble-v2.md` is the canonical BLE wire contract.
3. `ios/` owns the human controller and the consent-gated agent-audio bridge.

## Invariants

- Never mix either onboard microphone into the line-input DSP path.
- Do not add arbitrary code execution to the iPhone app or ESP32 firmware.
- The iPhone agent interface exposes playback, recording, route status, and
  stop primitives; measurement strategy belongs on the Mac.
- Agent Control remains off by default, foreground-only, visibly active, and
  gated by approval of the named Mac.
- DSP edits remain drafts until an explicit save. The UI may call a setting
  saved only after the firmware acknowledgement, authoritative readback, and
  persisted revision agree.
- Any positive EQ gain must participate in automatic digital-headroom
  calculation. Headroom protects the digital pipeline, not the amplifier or
  driver.
- If the BLE packet layout changes, update the protocol document, Swift codec,
  C++ codec, golden vectors, and both test suites in one change.

## Required verification

Run portable iPhone tests:

```sh
cd ios && swift test
```

Run portable firmware tests:

```sh
cmake -S firmware -B firmware/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build firmware/build
ctest --test-dir firmware/build --output-on-failure
```

For iOS UI or audio-session changes, also run the Xcode simulator test target.
For codec, I2S, BLE, or persistence changes, build the PlatformIO target and
state explicitly whether a physical ESP32 Audio Kit V2.2 A618 was tested.

## Release and secrets

Keep Fastlane source and metadata tracked. Never commit `.p8` files,
`fastlane/api_key.json`, `.env` files, App Review contact files, provisioning
profiles, IPAs, archives, or session cookies. Before a public push, scan both
the current tree and every reachable Git object for credentials.

The repository uses PolyForm Strict 1.0.0. Do not accept or solicit pull
requests without the licensor first choosing a contribution and relicensing
policy.
