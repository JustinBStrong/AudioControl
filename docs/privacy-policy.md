# AudioControl privacy policy

Last updated: August 5, 2026

AudioControl does not collect, sell, or transmit personal data to the developer
or any third party. If the user enables Agent Control and approves a nearby Mac,
the app can send microphone recordings directly to that Mac at the user's
request. The developer does not receive those recordings.

## Bluetooth

AudioControl uses Bluetooth Low Energy to find and configure a nearby
AudioControl-compatible ESP32 audio processor. DSP settings and device status
are exchanged directly between the iPhone and the processor. They are not sent
to the developer or any third party.

## Audio and microphone

The test-tone feature generates audio locally on the iPhone and sends it only
to the audio output selected by the user. Agent Control is disabled by default.
After the user enables it and approves a named nearby Mac, that Mac can ask the
app to play an audio file, record the built-in microphone, or do both. Active
playback or recording is visible in the Agent tab and can be stopped there.
Microphone permission is still controlled by the normal iOS permission prompt.

Agent recordings are transferred directly to the approved Mac. Temporary audio
files on the iPhone are removed after transfer, disconnection, cancellation, or
failure. AudioControl does not upload them to the developer or an internet
service.

## Networking and third parties

AudioControl uses Apple's Multipeer Connectivity framework to discover and
communicate with a user-approved nearby Mac over local or peer-to-peer
connectivity. It does not connect to a developer-operated internet service and
contains no analytics, advertising, tracking, account system, or third-party
SDK.

## Data retention and deletion

Because AudioControl does not transmit personal data to our systems, there is
no personal data to retain or delete from us. DSP configuration is stored on
the user's ESP32 processor. Agent audio is temporary on the iPhone; recordings
saved by the Mac tool are controlled and deleted by the Mac user.

## Changes

If AudioControl's data practices change, this policy and the App Store privacy
disclosure will be updated before the changed version is distributed.

## Contact

Support and privacy questions can be sent through the support contact listed on
AudioControl's App Store product page.
