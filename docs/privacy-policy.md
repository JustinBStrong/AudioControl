# AudioControl privacy policy

Last updated: August 5, 2026

AudioControl does not collect, sell, or transmit personal data to the developer
or any third party. User-initiated cabin measurement files are stored locally
on the user's device until the user deletes or shares them.

## Bluetooth

AudioControl uses Bluetooth Low Energy to find and configure a nearby
AudioControl-compatible ESP32 audio processor. DSP settings and device status
are exchanged directly between the iPhone and the processor. They are not sent
to the developer or any third party.

## Audio and microphone

The test-tone feature generates audio locally on the iPhone and sends it only
to the audio output selected by the user. The cabin-measurement feature uses the
iPhone microphone only after the user taps the measurement button and grants
microphone permission. It records a short in-car frequency sweep and saves the
recording, a reference signal, and route metadata in the app's local Documents
directory. AudioControl does not upload these files. They leave the device only
when the user explicitly chooses a destination through the iOS share sheet.

## Networking and third parties

AudioControl does not connect to an internet service and contains no analytics,
advertising, tracking, account system, or third-party SDK.

## Data retention and deletion

Because AudioControl does not transmit personal data to our systems, there is
no personal data to retain or delete from us. DSP configuration is stored on
the user's ESP32 processor. Measurement files remain in the app's local storage
and can be removed by deleting the app and its data from the device.

## Changes

If AudioControl's data practices change, this policy and the App Store privacy
disclosure will be updated before the changed version is distributed.

## Contact

Support and privacy questions can be sent through the support contact listed on
AudioControl's App Store product page.
