# Setup Notes

## macOS

1. Install `BlackHole 2ch` from the upstream project: [BlackHole](https://github.com/ExistentialAudio/BlackHole)
2. Open Audio MIDI Setup and confirm `BlackHole 2ch` appears as an input/output device.
3. Build and run the app in `macos/`.
4. Use the app button to set `BlackHole 2ch` as the current system input device when needed.

## Android

1. Open `android/` in Android Studio.
2. Let Gradle sync the project and install any requested SDK components.
3. Install the app on a physical Android phone running Android 10 or newer.
4. Grant microphone access; grant camera access if using QR pairing.

## Networking

- Phone and Mac must be on the same Wi-Fi network.
- The default listening port is `48484/TCP`.
- If the host changes on the Mac, regenerate or rescan the QR payload.

## Known Constraints

- No remote/internet relay
- No multi-client mixing
- No recording mode
- `BlackHole 2ch` installation is manual in v1
