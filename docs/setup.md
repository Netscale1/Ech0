# Setup Notes

For the complete Windows-to-Mac microphone workflow, see [Windows → Mac setup](windows-codex-setup.md).

## macOS

Ech0 supports two audio endpoints, in this order:

1. **Recommended:** the bundled, input-only `Ech0 Virtual Microphone` driver.
2. **Optional fallback:** an existing `BlackHole 2ch` installation from the
   [upstream BlackHole project](https://github.com/ExistentialAudio/BlackHole).

BlackHole is not required when the Ech0 driver is available. At startup Ech0
selects the dedicated driver first, otherwise it selects BlackHole. Startup
fails with a clear setup error only when neither device exists. Ech0 changes
BlackHole to the protocol's 48 kHz rate only when BlackHole was actually chosen;
it does not modify BlackHole when using the dedicated driver.

Build both the app and dedicated driver:

```sh
./scripts/macos-release.sh check
```

Follow [the macOS release and installation guide](macos-release.md) to install
the driver. Then run Ech0Mac and use its button to make the selected endpoint
the system input when needed.

BlackHole may independently be part of a screen-sharing or remote-desktop audio
route. Removing it from Ech0's requirements does not mean it is safe to
uninstall from the Mac; inspect that route separately.

## Windows

1. Run the self-contained `Ech0Windows.exe` on Windows 10 22H2 or Windows 11 x64.
2. Keep the Mac and PC on the same trusted LAN.
3. Use automatic discovery or enter the Mac address and port `48484`.
4. Enter the pairing code shown in Ech0Mac.
5. After trust is confirmed, Windows deletes the one-time code and reconnects using the saved receiver and sender identities.
6. Ech0 installs no driver and requires no administrator rights. When enabled, launch-at-login is registered for the current user under the standard Windows Run key.
7. The selected Windows capture endpoint is opened only while a Mac app actively acquires from the input device prepared by Ech0Mac. If that endpoint is unavailable, Ech0 waits instead of silently switching microphones.

## Networking

- The Windows PC and Mac must be on the same trusted local network.
- The default listening port is `48484/TCP`.
- Ech0Mac advertises `_ech0._tcp.local` for Windows DNS-SD discovery.
- If a manually configured Mac address changes, update it in Ech0Windows settings.

## Known Constraints

- No remote/internet relay; use the encrypted local protocol on a trusted LAN
- No multi-client mixing
- No recording mode
- Apple Silicon only for version 0.2.0
- Community macOS builds are not notarized
