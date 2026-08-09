# Fastlane release workflow

The release configuration is public; credentials are deliberately external.
Set these variables before invoking a lane:

```sh
export ASC_API_KEY_JSON=/absolute/path/to/api_key.json
export APP_REVIEW_INFO_DIR=/absolute/path/to/review_information
```

`ASC_API_KEY_JSON` uses the schema in `api_key.json.example`. Its `.p8` path is
resolved beside the JSON file. `APP_REVIEW_INFO_DIR` must contain
`first_name.txt`, `last_name.txt`, `phone_number.txt`, and `email_address.txt`.
None of those files belong in this repository.

The first App Store Connect record requires interactive Apple Account
authentication:

```sh
APPLE_ID=you@example.com fastlane ios create_app_record
```

After the record exists:

```sh
fastlane ios test
fastlane ios build
fastlane ios beta
fastlane ios metadata
fastlane ios release
```

The `release` lane requires a clean Git tree, creates a signed App Store IPA,
uploads it, waits for processing, uploads metadata and screenshots, and submits
version 1.0.0 for automatic release after approval.
