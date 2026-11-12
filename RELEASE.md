# Releasing YouRec to TestFlight

Use this workflow to distribute an iOS build to the **YouRec Beta** external
tester group. Its review and distribution steps are for TestFlight only.

## Publish a new build

1. On the release Mac, check out the revision you want testers to receive. For
   camera changes, complete the [physical-camera checks](docs/CAMERA-QA.md).
2. Set `CURRENT_PROJECT_VERSION` to the next build number in the YouRec target's
   Debug and Release configurations in `YouRec.xcodeproj/project.pbxproj`.
   Use the existing `MARKETING_VERSION` for another beta of the same app version.
3. Write the English *What to Test* notes in a text file. Describe what changed
   since the previous **external beta**, including any intervening device builds.
4. Run the release command from the repository root. Include
   `--exempt-encryption` only when the build qualifies for that declaration.

```sh
./scripts/testflight.py --exempt-encryption ~/Desktop/YouRec-beta-notes.txt
```

The script prints the archive path, signs the Release build locally, uploads it,
and waits for Apple to process it. It then sets the notes, assigns the external
group, enables tester notifications, and requests Beta App Review when needed.
Keep the archive path and notes until distribution is confirmed.

Read the final status line and App Store Connect link. **`IN_BETA_TESTING`**
means testers in YouRec Beta can install the build. **`WAITING_FOR_BETA_REVIEW`**
and **`IN_BETA_REVIEW`** mean Apple has the submission and approval is pending.

## Continue an interrupted release

Use the archive path printed by the original run. Choose the command based on
whether Apple accepted the upload.

```sh
archive="/path/to/YouRec.xcarchive"
notes=~/Desktop/YouRec-beta-notes.txt

# Signing or upload failed before Apple accepted the binary.
./scripts/testflight.py --archive "$archive" --exempt-encryption "$notes"

# Apple already has the binary. Finish processing, notes, or distribution.
./scripts/testflight.py --archive "$archive" --resume --exempt-encryption "$notes"
```

If the first command finds the build on Apple, it stops and directs you to
`--resume`. A change to the app itself requires a fresh archive and build number.

## Signing on the release Mac

The [release script](scripts/testflight.py) uses Xcode, Python 3, and the `asc`
CLI. On a fresh checkout, generate the [VoiceFixer weights](ThirdParty/VoiceFixer/PROVENANCE.md)
before archiving.

| Purpose | What the script uses |
| --- | --- |
| Authenticate to App Store Connect | The `asc` App Manager profile `yourec-testflight`. Check it with `asc --profile yourec-testflight auth status`. |
| Sign YouRec locally | `distribution.p12` and `YouRec.mobileprovision` in `~/Library/Application Support/YouRec/TestFlightSigning/`. The profile must cover `com.antirez.yourec` and contain the certificate from the signing identity. |
| Open the signing identity | The PKCS#12 password in the macOS login Keychain, under service `com.antirez.yourec.testflight.signing` and account `yourec-testflight`. |

The script imports the identity into a temporary signing keychain for export
and removes it before upload. Keep credentials and signing assets outside Git.

For renewal, use the same API profile to issue an Apple Distribution certificate
from a local certificate signing request (CSR). Use the returned certificate ID
and Apple's bundle resource ID for `com.antirez.yourec` to create its profile.

```sh
asc --profile yourec-testflight certificates create \
  --certificate-type DISTRIBUTION --csr /path/to/distribution.csr
asc --profile yourec-testflight profiles create --profile-type IOS_APP_STORE \
  --bundle "$bundle_resource_id" --certificate "$certificate_id" --name "$profile_name"
```

Package the issued certificate with the CSR's private key as `distribution.p12`.
Place it and the matching `YouRec.mobileprovision` in the signing directory.
If the PKCS#12 password changes, update its login Keychain entry.
