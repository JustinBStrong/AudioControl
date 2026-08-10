fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios create_app_record

```sh
[bundle exec] fastlane ios create_app_record
```

Create the first App Store Connect record (interactive Apple Account authentication)

### ios test

```sh
[bundle exec] fastlane ios test
```

Run the portable Swift test suite

### ios build

```sh
[bundle exec] fastlane ios build
```

Build a signed App Store IPA without uploading it

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload to TestFlight without submitting for review

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload editable App Store metadata and screenshots

### ios release

```sh
[bundle exec] fastlane ios release
```

Build, upload, and submit version 1.0 for automatic release

### ios submit_existing

```sh
[bundle exec] fastlane ios submit_existing
```

Submit the already-uploaded App Store build without rebuilding it

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
