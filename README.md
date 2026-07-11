# Ech0

Ech0 is a local-network microphone bridge. A Windows PC or Android phone captures live voice audio and streams it to a macOS receiver, which writes the stream into `BlackHole 2ch` so Mac apps can use it as a microphone input.

## Workspace Layout

- `android/`: Android sender app built with Kotlin, Jetpack Compose, `AudioRecord`, and a foreground service.
- `macos/`: macOS receiver app built with SwiftUI, `Network.framework`, Core Audio, and a local jitter buffer.
- `windows/`: Windows x64 tray agent built with .NET 10, WinForms, NAudio, and WASAPI shared mode.
- `docs/protocol.md`: transport and control message specification shared by both apps.
- `docs/setup.md`: installation and manual setup notes, especially for `BlackHole 2ch`.
- `docs/windows-codex-setup.md`: complete Windows-to-Mac Codex setup, permissions, pairing, updates, and verification.

## MVP Scope

- One Android sender at a time
- One Windows or Android sender at a time
- Local Wi-Fi only
- Pairing via QR code or manual `IP + code`
- Voice-call optimized audio path
- Manual `BlackHole 2ch` installation on the Mac

## Build Notes

The macOS package is verified with `swift test --package-path macos`. The Windows project can be cross-published as a self-contained `win-x64` executable with .NET 10 and then tested on Windows 10 22H2 or Windows 11.

Use:

- Android Studio Ladybug+ or a compatible Gradle/AGP toolchain for `android/`
- Xcode 16+ or Swift 6 toolchain on macOS for `macos/`
- .NET 10 SDK for building `windows/`; the published executable does not require .NET on the target PC

## First Run

1. Install `BlackHole 2ch` on the Mac.
2. Build and launch the macOS app from `macos/`.
3. Build and install the Android app from `android/`.
4. In the macOS app, note the QR code or the displayed host/code.
5. In the Android app, scan the QR or enter the host/code manually.
6. Start streaming on Android.
7. In Zoom/Meet/Discord on the Mac, select `BlackHole 2ch` as the microphone input.

## Windows Agent

1. Build with `scripts/build-windows.sh`, or publish `windows/Ech0Windows/Ech0Windows.csproj` for `win-x64`.
2. Copy the generated `Ech0Windows.exe` to the Windows PC and open it.
3. Let DNS-SD find Ech0Mac, or enter the Mac IP manually.
4. Enter the six-digit pairing code shown by Ech0Mac.
5. Keep “Start Ech0 with Windows” enabled.

The agent stays connected while idle. It opens the default Windows input in WASAPI shared mode only when a Mac application actively uses `BlackHole 2ch`. Audio and credentials are not encrypted; use Ech0 only on a trusted LAN.
