# Ech0

Ech0 is a local-network microphone bridge. A Windows PC captures live voice audio and streams it to a macOS receiver, which prefers the input-only `Ech0 Virtual Microphone` and retains `BlackHole 2ch` as a compatibility fallback.

## Workspace Layout

- `macos/`: macOS receiver app built with SwiftUI, `Network.framework`, Core Audio, and a local jitter buffer.
- `windows/`: Windows x64 tray agent built with .NET 10, WinForms, NAudio, and WASAPI shared mode.
- `docs/protocol.md`: transport and control message specification shared by the Windows and macOS apps.
- `docs/setup.md`: installation and manual setup notes, especially for `BlackHole 2ch`.
- `docs/windows-codex-setup.md`: complete Windows-to-Mac microphone setup, permissions, pairing, updates, and verification.
- `docs/macos-audio-bridge.md`: input-only virtual microphone architecture, Parsec isolation, performance findings, and the operator checklist.
- `docs/macos-release.md`: self-contained macOS build, validation, signing, packaging, rollback, and notarization guide.
- `docs/release.md`: test-first build gates, CI, signed Windows releases, and updater integrity.
- `docs/review-findings.md`: prioritized engineering findings, acceptance evidence, and verification log.

## Scope

- One Windows sender at a time
- Authenticated and encrypted transport on the local LAN
- Pairing via Mac host and a copyable 128-bit security code
- Trusted reconnect after first pairing
- Remote microphone activation only while the Mac requests capture
- Voice-call optimized PCM audio path
- Manual `BlackHole 2ch` installation on the Mac

## Build Notes

Both build entry points run their platform tests before producing artifacts. The Windows project can be cross-published as an unsigned development `win-x64` executable with .NET 10; update packages are produced only by the signed Windows release path described in `docs/release.md`.

Use:

- Xcode 16+ or a Swift 6 toolchain on macOS for `macos/`
- .NET 10 SDK for building `windows/`; the published executable does not require .NET on the target PC

Run the complete credential-free macOS developer/CI gate with:

```sh
./scripts/macos-release.sh check
```

Local signing, development packaging, Developer ID packaging, and notarization
are separate fail-closed commands documented in `docs/macos-release.md`.

## First Run

1. Install `BlackHole 2ch` on the Mac.
2. Build and launch the macOS app from `macos/`.
3. Build `windows/Ech0Windows/Ech0Windows.csproj` or run `scripts/build-windows.sh`.
4. Copy the generated `Ech0Windows.exe` to the Windows PC and open it.
5. Let DNS-SD find Ech0Mac, or enter the Mac host manually.
6. Copy the security code shown by Ech0Mac into the Windows pairing window.
7. Keep “Start Ech0 with Windows” enabled if the agent should reconnect automatically.

The Windows agent stays connected while idle. It opens the selected Windows input in WASAPI shared mode only when a Mac application actively uses the input device prepared by Ech0Mac: normally `Ech0 Virtual Microphone`, with `BlackHole 2ch` as a compatibility fallback. Protocol v3 encrypts credentials, control traffic, and audio and pins the Mac identity after first pairing. Existing plaintext v2 associations intentionally require one new pairing after upgrade.
