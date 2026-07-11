# Setup Notes

For the complete Windows-to-Mac Codex workflow, see [Windows → Mac Codex setup](windows-codex-setup.md).

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

## Windows

1. Run the self-contained `Ech0Windows.exe` on Windows 10 22H2 or Windows 11 x64.
2. Keep the Mac and PC on the same trusted LAN.
3. Use automatic discovery or enter the Mac address and port `48484`.
4. Enter the pairing code shown in Ech0Mac.
5. After trust is confirmed, Windows deletes the one-time code and reconnects using the saved receiver and sender identities.
6. Ech0 installs no driver and requires no administrator rights. When enabled, launch-at-login is registered for the current user under the standard Windows Run key.
7. The default Windows capture endpoint is opened only while a Mac app uses BlackHole. If the wireless headset is off, Ech0 waits instead of silently switching microphones.

## Networking

- Phone and Mac must be on the same Wi-Fi network.
- The default listening port is `48484/TCP`.
- Ech0Mac advertises `_ech0._tcp.local` for Windows DNS-SD discovery.
- If the host changes on the Mac, regenerate or rescan the QR payload.

## Known Constraints

- No remote/internet relay
- No multi-client mixing
- No recording mode
- `BlackHole 2ch` installation is manual in v1
- No transport encryption; use only on a trusted LAN
