# Ech0 release gates

Release artifacts must be produced only after the repository tests pass. CI and both local build entry points enforce this ordering.

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request with read-only repository permissions:

- macOS 15 runs the strict-concurrency Swift suite, builds the Release app bundle, verifies its code signature, and lints `Info.plist`;
- Windows installs .NET 10, runs the complete C# suite, publishes the self-contained x64 application, and verifies the unsigned development artifact hash path.

Third-party actions are pinned to immutable commit SHAs. CI deliberately does not receive a release signing certificate.

## macOS build

```sh
./scripts/macos-release.sh check
```

The credential-free gate runs the strict Swift suite, builds an ad-hoc app,
builds and smoke-tests the unsigned input-only HAL driver, and validates both
bundle structures. CI uses the same command and does not inspect the worker
keychain.

Local signing, recoverable installation, Developer ID Application/Installer
packaging, and notarization are deliberately separate fail-closed steps. See
[macOS developer and release pipeline](macos-release.md) for prerequisites,
commands, environment variables, validation, and rollback.

## Windows development build

From macOS or another environment with .NET 10:

```sh
./scripts/build-windows.sh
```

This runs all C# tests before publish and creates an unsigned first-install artifact. It does not create an update ZIP, because an unsigned self-updater would provide a misleading integrity boundary.

## Signed Windows release

Run on Windows with .NET 10, `signtool.exe`, and a trusted Authenticode certificate in `Cert:\CurrentUser\My`:

```powershell
$env:ECH0_WINDOWS_CERT_THUMBPRINT = "<certificate thumbprint>"
$env:ECH0_TIMESTAMP_URL = "<RFC 3161 timestamp URL>"
./scripts/release-windows.ps1
```

The script:

1. runs the full Release test suite;
2. publishes the self-contained x64 executable;
3. signs and verifies `Ech0Windows.exe` with SHA-256 and an RFC 3161 timestamp;
4. embeds the same certificate thumbprint in a copy of `Update-Ech0.ps1`;
5. Authenticode-signs and verifies that updater script;
6. verifies the update artifact through the updater's read-only `-VerifyOnly` path;
7. creates the install and update ZIPs plus `SHA256SUMS`.

The repository does not contain a signing private key or certificate. Until those external release credentials are provisioned, only development artifacts can be built and no production update ZIP should be distributed.

## Updater security boundary

The signed updater rejects an executable unless all of these checks pass:

- the adjacent manifest is exactly one SHA-256 value and matches the file;
- the Authenticode signature is valid;
- the signer certificate thumbprint matches the publisher embedded by the release pipeline.

It enumerates `Ech0Windows` processes but stops only a process whose full executable path equals `%LOCALAPPDATA%\Ech0\Ech0Windows.exe`. It copies to a unique temporary file, re-verifies that copy, replaces the installed executable with a backup-assisted file operation, cleans temporary files, and then restarts only the fixed target path.

`Update-Ech0.cmd` invokes the signed PowerShell script with `AllSigned`. A first run may ask the user to trust the publisher. The `-AllowUnsignedDevelopment` switch exists only for the CI/read-only verification path and is never used by the packaged launcher.
