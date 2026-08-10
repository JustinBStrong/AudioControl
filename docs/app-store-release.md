# AudioControl App Store release checklist

## Prepared in the project

- iPhone-only application target with bundle ID `com.justinstrong.AudioControl`
- marketing version `1.0`, build `1`
- automatic signing for Apple Developer team `3TKP8A48MF`
- opaque 1024 x 1024 App Store icon in the `AppIcon` asset catalog
- Bluetooth, microphone, and local-network purpose strings explaining ESP32
  control and explicitly approved nearby-Mac Agent Control
- valid privacy manifest declaring no tracking, collected data, or required-reason API use
- export-compliance key declaring no non-exempt encryption
- launch-screen configuration and light appearance
- no analytics, ads, accounts, third-party SDKs, or network collection
- credential-safe Fastlane lanes for testing, archiving, TestFlight, metadata,
  screenshots, and App Review submission
- three current 6.9-inch iPhone screenshots in `fastlane/screenshots/en-US`
- App Store listing copy, age-rating answers, privacy declaration, and review
  notes under `fastlane/`
- public privacy and support pages published from `docs/`

## Prepared in Apple Developer and GitHub

- registered Apple bundle identifier `com.justinstrong.AudioControl`
- public source-available repository at
  `https://github.com/JustinBStrong/AudioControl`
- public privacy policy at
  `https://justinbstrong.github.io/AudioControl/privacy.html`
- public support page at `https://justinbstrong.github.io/AudioControl/`
- App Store Connect record `6799782013`, with storefront name
  `AudioControl DSP` and editable iOS version `1.0`
- listing metadata, categories, 4+ age-rating answers, copyright, and all three
  screenshots uploaded successfully with Fastlane 2.237.0; precheck passes
  without warnings
- App Privacy published as “Data Not Collected”
- content rights declared as no third-party content
- free pricing configured in 175 countries and regions
- availability configured for iPhone in all 175 countries and regions; Apple
  Silicon Mac and Apple Vision Pro availability are disabled
- Digital Services Act status declared as non-trader and active for all 27 EU
  countries
- Apple-signed Xcode 26.3 (`17C529`) installed side by side at
  `/Applications/Xcode-26.3.app`
- signed App Store archive built with the iOS 26.2 SDK and exported as version
  `1.0` build `1`
- build `1` uploaded, processed by Apple, and distributed to the internal
  TestFlight group
- version `1.0` submitted to App Review; Apple reports both the App Store and
  version states as `WAITING_FOR_REVIEW`
- release type configured as automatic after approval

## App Store Connect metadata draft

- **Name:** AudioControl DSP
- **Subtitle:** Tune your ESP32 subwoofer
- **Primary category:** Utilities
- **Secondary category:** Music
- **Age rating:** 4+; no restricted content or social-media capabilities
- **App privacy:** Published as “Data Not Collected”
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

  The app controls a separate ESP32 Audio Kit peripheral over BLE.
  The hardware is not required to review the local test-tone or Agent Control
  interface. Without a peripheral, the Tune screen remains visible and reports
  that no processor is connected. Agent Control is off by default, advertises
  only after the user enables it, and requires the user to approve the named Mac
  before any playback or microphone command is accepted. Active remote audio is
  visible in the app with a Stop control. A demonstration device and Mac CLI can
  be supplied if App Review requests them.

## Release verification

- portable Swift tests: 28 of 28 passed
- Xcode iPhone 17 Pro simulator tests: 28 of 28 passed
- signed archive, App Store export, upload, Apple processing, and internal
  TestFlight distribution completed successfully
- App Store Connect API readback confirms version `1.0`, build `1`, review type
  `APP_STORE`, and state `WAITING_FOR_REVIEW`

## Remaining release work

No developer action is currently required. Apple must review the submission.
If it is approved, the app is configured to release automatically; if App
Review asks for hardware access or clarification, respond through App Store
Connect and submit an updated build only if necessary.
