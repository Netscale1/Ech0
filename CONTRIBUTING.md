# Contributing to Ech0

Thanks for helping improve Ech0. Contributions are accepted under the Apache
License 2.0; by submitting a contribution, you agree that it may be distributed
under that license.

## Before opening a pull request

1. Open an issue for behavior changes that affect the network protocol, audio
   routing, pairing, or package format.
2. Keep changes focused. Do not include generated build output from `dist/`,
   local credentials, signing material, machine names, or audio-route details.
3. Preserve protocol compatibility unless the issue explicitly approves a
   coordinated Windows and macOS version change.
4. Update user-facing documentation when requirements or behavior change.

## Validation

On macOS, run:

```sh
./scripts/macos-release.sh check
```

On Windows, run:

```powershell
dotnet test windows/Ech0Windows.Tests/Ech0Windows.Tests.csproj -c Release
./scripts/release-windows.ps1 -AllowUnsignedDevelopment
```

The macOS gate does not install the HAL driver, restart Core Audio, or change
audio routes. Live audio testing must preserve unrelated playback and remote
desktop routes and must document the exact endpoint used.

## Pull requests

Describe the problem, the smallest implemented solution, and the verification
performed. Security vulnerabilities should not be filed as public issues; see
[SECURITY.md](SECURITY.md).
