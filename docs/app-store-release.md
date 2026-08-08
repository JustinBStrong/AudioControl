# AudioControl App Store release checklist

## Prepared in the project

- iPhone-only application target with bundle ID `com.justinstrong.AudioControl`
- marketing version `1.0.0`, build `1`
- automatic signing for Apple Developer team `3TKP8A48MF`
- opaque 1024 x 1024 App Store icon in the `AppIcon` asset catalog
- Bluetooth, microphone, and local-network purpose strings explaining ESP32
  control and explicitly approved nearby-Mac Agent Control
- valid privacy manifest declaring no tracking, collected data, or required-reason API use
- export-compliance key declaring no non-exempt encryption
- launch-screen configuration and light appearance
- no analytics, ads, accounts, third-party SDKs, or network collection

## App Store Connect metadata draft

- **Name:** AudioControl
- **Subtitle:** Tune your ESP32 subwoofer
- **Primary category:** Utilities
- **Secondary category:** Music
- **Age rating:** Complete the current questionnaire truthfully; the app contains no restricted content
- **App privacy:** Select “No, we do not collect data from this app”
- **Description:**

  AudioControl configures a compatible ESP32 Audio Kit installed between a
  line-level audio source and a subwoofer amplifier. Adjust subwoofer delay,
  choose a low-pass cutoff, shape deep bass with a simple low shelf, and monitor
  DSP clipping and headroom over Bluetooth Low Energy. A continuous test-tone
  generator helps set gain. An optional Agent Control interface lets the user
  approve a nearby Mac to play arbitrary test audio over the selected output,
  capture the built-in microphone, and return the recording for analysis.

- **Keywords:** subwoofer,audio,DSP,delay,crossover,ESP32,test tone,bass
- **Review note:**

  The app controls a separate open-source ESP32 Audio Kit peripheral over BLE.
  The hardware is not required to review the local test-tone or Agent Control
  interface. Without a peripheral, the Tune screen remains visible and reports
  that no processor is connected. Agent Control is off by default, advertises
  only after the user enables it, and requires the user to approve the named Mac
  before any playback or microphone command is accepted. Active remote audio is
  visible in the app with a Stop control. A demonstration device and Mac CLI can
  be supplied if App Review requests them.

## Still required outside the source tree

1. Host `docs/privacy-policy.md` at a public HTTPS URL; App Store Connect
   requires a privacy-policy URL for iOS apps.
2. Provide a public support URL and support contact.
3. Create or select the matching App Store Connect app record and confirm the
   bundle ID before the first upload; the bundle ID cannot be changed afterward.
4. Capture one to ten current iPhone screenshots without transparency.
5. Complete the updated age-rating, availability, pricing, content-rights, and
   EU Digital Services Act declarations in App Store Connect.
6. Build the upload archive with Xcode 26 or later. Since April 28, 2026, Apple
   requires iOS submissions to use the iOS 26 SDK or later.
7. Validate the archive, upload it to TestFlight, test on a physical iPhone, and
   then explicitly submit the selected build for App Review.
