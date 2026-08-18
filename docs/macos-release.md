# macOS developer and release pipeline

This guide is the reproducible entry point for building, validating, signing,
and packaging the Ech0 macOS app and input-only HAL driver. The repository does
not contain signing certificates, Apple IDs, App Store Connect keys, passwords,
or notarization credentials.

The pipeline deliberately separates:

- CI/community checks, which use ad-hoc app and driver signatures;
- local testing signatures, supplied by the developer;
- official Developer ID packaging;
- notarization, which uses credentials provisioned outside the repository.

No pipeline command installs an app or driver, restarts Core Audio, changes an
audio route, or publishes a release.

## Prerequisites

Use a Mac with:

- macOS 13 or later;
- Xcode Command Line Tools or Xcode with a Swift 6-compatible toolchain;
- `swift`, `xcrun`, `clang`, `codesign`, `plutil`, `file`, and `ditto`;
- `pkgbuild`, `pkgutil`, and `spctl` for an official installer;
- `xcrun notarytool` and `xcrun stapler` for notarization;
- an Apple Development identity for optional local signing;
- Developer ID Application and Developer ID Installer identities for an
  official package;
- an App Store Connect API key stored outside the repository for notarization.

Confirm the active developer directory and tools:

```sh
xcode-select -p
swift --version
xcrun --find clang
xcrun --find notarytool
xcrun --find stapler
```

Signing identities available in the current login keychain can be listed
without exposing private keys:

```sh
security find-identity -v
```

## Command overview

Run all commands from the repository root:

```sh
./scripts/macos-release.sh help
```

The supported commands are:

| Command | Credentials | Result |
| --- | --- | --- |
| `check` | none | strict tests, ad-hoc app and driver, smoke and structure checks |
| `sign-local` | local signing identity | locally signed app and driver |
| `package-community` | none beyond `check` | unnotarized ZIP with hashes and notices |
| `package-official` | Developer ID Application and Installer identities | signed installer package, not yet notarized |
| `notarize` | external notary keychain profile | submitted, stapled, Gatekeeper-validated installer |

Commands that sign or notarize fail before modifying artifacts if their
required environment variables or keychain identities are absent.

## Development and CI check

Run:

```sh
./scripts/macos-release.sh check
```

This command:

1. forces an ad-hoc signature for the app, even if the developer keychain
   contains a signing identity;
2. runs the complete Swift suite with strict concurrency diagnostics;
3. builds the Release app bundle into `dist/macos/Ech0Mac.app`;
4. builds and ad-hoc signs the HAL bundle into `dist/macos/Ech0VirtualMic.driver`;
5. compiles and runs the driver smoke executable;
6. validates both property lists, identifiers, bundle structure, executable
   types, architecture, and the app's ad-hoc signature;
7. prints SHA-256 diagnostics for the two binaries.

The ad-hoc signature verifies bundle integrity but does not identify a trusted
publisher. The smoke test verifies the driver's input-only topology, PCM
handoff, conversion, and reset path without installing it.

This is the command CI should run on a macOS worker. It requires no secrets and
does not inspect or depend on the worker's signing keychain.

The pipeline fixes locale, timezone, and archive-date environment inputs and
the build scripts reconstruct the output bundles from a fixed file set. This
makes the build procedure and bundle composition deterministic. Signed and
notarized artifacts are not byte-for-byte reproducible because Apple signatures
and secure timestamps contain external metadata.

## Local signing

Run `check` first. Then provide an identity already present in the login
keychain:

```sh
export ECH0_MACOS_SIGNING_IDENTITY='Apple Development: Example Developer (TEAMID)'
./scripts/macos-release.sh sign-local
```

The script refuses to guess an identity. It verifies the supplied value with
`security find-identity`, signs the app and driver with hardened runtime and no
network timestamp, and then runs strict `codesign` verification on both
bundles.

An Apple Development signature is suitable for local testing and stable macOS
permissions. It is not a public release signature and is not notarized.

To inspect the result:

```sh
codesign --verify --deep --strict --verbose=2 dist/macos/Ech0Mac.app
codesign --verify --deep --strict --verbose=2 dist/macos/Ech0VirtualMic.driver
codesign -dv --verbose=4 dist/macos/Ech0Mac.app
codesign -dv --verbose=4 dist/macos/Ech0VirtualMic.driver
```

## Community package without a paid Apple account

The repository can be built and shared without Apple Developer Program
membership. After `check`, create the community package:

```sh
./scripts/macos-release.sh package-community
```

The result is:

```text
dist/macos/Ech0Mac-<version>-community.zip
```

It contains the app, driver, hashes, licenses, notices, and this guide. Both
bundles are ad-hoc signed. The archive may be published only with the explicit
label **community build — not notarized**. macOS cannot verify its publisher;
users may need to approve the app in Privacy & Security and install the driver
manually with administrator authorization.

This is the free alternative, not an equivalent replacement for Developer ID.
Do not describe the archive as Apple-notarized, Gatekeeper-validated, or signed
by NetScale 1. Users who require a fully trusted chain should build from source
or wait for a notarized release from a maintainer with the required credentials.

### Installing a community build

After extracting the ZIP, verify the files from inside its directory:

```sh
shasum -a 256 -c SHA256SUMS
codesign --verify --deep --strict Ech0Mac.app
codesign --verify --strict Ech0VirtualMic.driver
```

Then:

1. close any running copy of Ech0Mac;
2. move `Ech0Mac.app` to `/Applications`;
3. copy `Ech0VirtualMic.driver` to
   `/Library/Audio/Plug-Ins/HAL/` with administrator authorization;
4. reboot the Mac at a convenient time so Core Audio loads the driver;
5. if macOS blocks the unnotarized app, use the per-app **Open Anyway** control
   in System Settings → Privacy & Security after verifying the hash;
6. confirm in Audio MIDI Setup that `Ech0 Virtual Microphone` has two input
   channels and no output channels.

Do not globally disable Gatekeeper and do not remove quarantine recursively
from unrelated files.

### Upgrade from a pre-public build

Version 0.2.0 changes the app and driver identifiers from `net.ech0.*` to
`io.github.netscale1.ech0.*`. Replace the app and driver together; mixing the
old app with the new driver leaves the dedicated endpoint undiscoverable.
Trusted-device and receiver identity files remain under
`~/Library/Application Support/Ech0Mac`, so replacing both bundles does not by
itself erase pairing. Launch at login may need to be enabled again because
macOS sees the new app identifier.

## Recoverable local installation

Installation is intentionally manual because the HAL destination is privileged
and restarting Core Audio can interrupt an active session.

Before installing:

1. record the current input, playback output, and system-output roles;
2. confirm the sender and Parsec connection are healthy;
3. verify the candidate signatures and input-only smoke test;
4. copy the installed app and driver to uniquely named, recoverable backup
   locations outside their active directories;
5. stop only Ech0Mac before replacing the app.

The active destinations are:

```text
/Applications/Ech0Mac.app
/Library/Audio/Plug-Ins/HAL/Ech0VirtualMic.driver
```

Driver installation requires administrator authorization. The operator must
enter the macOS password or approve Touch ID; automation must not capture or
enter credentials. Preserve root ownership and normal read/execute permissions
on the installed driver.

After replacing a HAL driver, restart Core Audio or reboot at an operator-chosen
time. Then verify:

- both installed signatures;
- `Ech0 Virtual Microphone` exposes one input and zero outputs;
- the requesting app receives live microphone audio;
- the previous playback and system-output routes are unchanged;
- Parsec remains connected and does not rebroadcast the microphone;
- Ech0 reconnects to its sender.

If any check fails, restore both backups, restart Core Audio if the driver
changed, and repeat the full validation. Do not delete the backups until the
new installation has passed a sustained live session.

## Official Developer ID package

An official package requires two identities in the keychain. Run `check`, then
set both identities explicitly:

```sh
export ECH0_DEVELOPER_ID_APPLICATION='Developer ID Application: Example Organization (TEAMID)'
export ECH0_DEVELOPER_ID_INSTALLER='Developer ID Installer: Example Organization (TEAMID)'
./scripts/macos-release.sh package-official
```

The script:

1. rejects identities that are not of the expected Developer ID type;
2. verifies both identities exist;
3. signs the app and driver with hardened runtime and Apple's secure timestamp;
4. strictly verifies both bundle signatures and structures;
5. stages the app under `/Applications` and the driver under the HAL directory;
6. creates and verifies:

   ```text
   dist/macos/Ech0Mac-<version>.pkg
   ```

The package is signed but not yet an official distributable artifact. It must
pass notarization and stapling.

The installer deliberately has no post-install script. It does not restart
Core Audio, alter routes, or launch applications. Release notes must tell the
operator that a reboot or deliberate Core Audio restart is required after a
driver update.

## Notarization handoff

Prefer an App Store Connect API key. Keep the `.p8` key outside the repository
and supply its path and identifiers through the environment when provisioning a
Keychain profile:

```sh
export ECH0_NOTARY_KEYCHAIN_PROFILE='ech0-notary'
export ECH0_NOTARY_KEY_PATH='/secure/external/location/AuthKey_KEYID.p8'
export ECH0_NOTARY_KEY_ID='KEYID'
export ECH0_NOTARY_ISSUER='ISSUER-UUID'

xcrun notarytool store-credentials "$ECH0_NOTARY_KEYCHAIN_PROFILE" \
  --key "$ECH0_NOTARY_KEY_PATH" \
  --key-id "$ECH0_NOTARY_KEY_ID" \
  --issuer "$ECH0_NOTARY_ISSUER"
```

Do not commit any of those values or the key. CI should inject them only in a
protected release environment.

With the signed package already built:

```sh
export ECH0_NOTARY_KEYCHAIN_PROFILE='ech0-notary'
./scripts/macos-release.sh notarize
```

The command submits with `notarytool --wait`, staples the ticket to the
installer, validates the ticket, and runs Gatekeeper assessment. Any failed
submission, staple, or assessment stops the command with a non-zero exit.

Before publishing, also record:

```sh
shasum -a 256 dist/macos/Ech0Mac-<version>.pkg
pkgutil --check-signature dist/macos/Ech0Mac-<version>.pkg
spctl --assess --verbose=2 --type install dist/macos/Ech0Mac-<version>.pkg
```

Publishing a GitHub release, uploading artifacts, and managing release notes
remain separate human-authorized actions.

## Troubleshooting

### Signing input is missing

`sign-local`, `package-official`, and `notarize` never fall back to ad-hoc
signing. Set the variable named in the error and confirm the referenced
identity/profile exists.

### A signing identity is not found

Check:

```sh
security find-identity -v
```

Import the certificate and its private key into the current user's keychain, or
correct the environment variable. Do not weaken the script to accept an
unverified name.

### The driver builds but cannot be selected

`check` does not install or load the driver. Confirm that the signed bundle was
installed in the HAL directory with the correct ownership, then restart Core
Audio or reboot. Re-run the topology and live isolation checks before changing
any route.

### Notarization fails

Use the submission identifier printed by `notarytool` to retrieve the log:

```sh
xcrun notarytool log <submission-id> \
  --keychain-profile "$ECH0_NOTARY_KEYCHAIN_PROFILE"
```

Fix the reported bundle/signature issue, rebuild from `check`, re-sign, and
create a new package. Never reuse or relabel a rejected package.
