# Ech0

Ech0 is a local-network microphone bridge: an Android phone captures live voice audio and streams it to a macOS receiver, which plays the stream into `BlackHole 2ch` so conferencing apps on the Mac can use it as a microphone input.

## Workspace Layout

- `android/`: Android sender app built with Kotlin, Jetpack Compose, `AudioRecord`, and a foreground service.
- `macos/`: macOS receiver app built with SwiftUI, `Network.framework`, Core Audio, and a local jitter buffer.
- `docs/protocol.md`: transport and control message specification shared by both apps.
- `docs/setup.md`: installation and manual setup notes, especially for `BlackHole 2ch`.

## MVP Scope

- One Android sender at a time
- Local Wi-Fi only
- Pairing via QR code or manual `IP + code`
- Voice-call optimized audio path
- Manual `BlackHole 2ch` installation on the Mac

## Build Notes

This repository was created from an empty workspace. The source tree is implementation-ready, but this environment does not have the Android or Swift toolchains installed, so I could not run `gradle`, Android Studio sync, `swift build`, or `xcodebuild` here.

Use:

- Android Studio Ladybug+ or a compatible Gradle/AGP toolchain for `android/`
- Xcode 16+ or Swift 6 toolchain on macOS for `macos/`

## First Run

1. Install `BlackHole 2ch` on the Mac.
2. Build and launch the macOS app from `macos/`.
3. Build and install the Android app from `android/`.
4. In the macOS app, note the QR code or the displayed host/code.
5. In the Android app, scan the QR or enter the host/code manually.
6. Start streaming on Android.
7. In Zoom/Meet/Discord on the Mac, select `BlackHole 2ch` as the microphone input.

