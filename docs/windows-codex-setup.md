# Ech0 Windows-to-Mac setup

This guide configures the following path:

`Windows microphone -> Ech0Windows -> trusted LAN -> Ech0Mac -> Ech0 Virtual Microphone -> macOS application`

Ech0Windows stays connected while idle, but opens the Windows microphone only
when Core Audio reports that a macOS process is actively capturing from the
input endpoint selected by Ech0Mac. This is system-level detection and does not
contain application-specific logic.

## Requirements

- An Apple Silicon Mac running macOS 13 or later.
- An x64 PC running Windows 10 22H2 or Windows 11.
- Both computers on the same private, trusted LAN.
- `Ech0 Virtual Microphone` installed on the Mac or, as an optional fallback,
  `BlackHole 2ch`.
- The target macOS application configured to use the input endpoint shown by
  Ech0Mac.
- The .NET 10 SDK only on the machine that builds Ech0Windows. The destination
  PC does not need a separate .NET installation because release builds are
  self-contained.

Protocol v3 authenticates the Mac and protects pairing credentials, control
messages, and audio with directional AES-256-GCM keys. Windows also pins the
Mac receiver signing key after pairing. Do not expose `48484/TCP` directly to
the Internet: Ech0 is designed and tested for a trusted local network.

## 1. Prepare the Mac

Install the `Ech0 Virtual Microphone` driver included in the macOS package. If
the dedicated driver cannot be used, you may install
[BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) as a fallback.
Ech0 automatically prefers its dedicated input-only driver and requires at
least one of these two endpoints.

To build and validate both the app and the driver from source, run this from the
repository root:

```sh
./scripts/macos-release.sh check
```

This produces ad-hoc-signed development artifacts in `dist/macos` and does
not install or load them. Follow the
[macOS release and installation guide](macos-release.md) for local installation,
community packaging, signing, and rollback instructions.

At first launch:

1. Open **Pairing**, then copy the Base32 security code for a new device and the
   Mac host address shown by Ech0Mac.
2. Enable **Launch at login** if Ech0Mac should start with macOS.
3. In the target macOS application, select the endpoint shown by Ech0Mac as its
   input and grant that application **Microphone** permission.

Ech0Mac does not require Accessibility permission and does not persist audio.

## 2. Prepare Windows

For a self-contained x64 community build:

```sh
./scripts/build-windows.sh
```

The script runs the complete C# test suite before publishing and produces:

- `dist/windows/Ech0Windows-win-x64.zip`: unsigned first-install package;
- `dist/windows/SHA256SUMS`: SHA-256 hashes for the published artifacts.

The unsigned ZIP may be published only as a **community build — unsigned** and
may trigger a SmartScreen warning. It has no automatic updater: download and
replace the executable manually for each new version.

A signed `Ech0Windows-update.zip` must instead be produced on Windows with
`scripts/release-windows.ps1`, a trusted Authenticode certificate, and a
configured timestamp server. See [the release gates](release.md) for details.

On the Windows PC:

1. Extract `Ech0Windows-win-x64.zip` to a local directory.
2. Start `Ech0Windows.exe` from the interactive user session.
3. Keep automatic discovery enabled, or enter the Mac host address and port
   `48484` manually.
4. Choose a specific Windows microphone if Ech0 must never follow changes to
   the Windows default input. Otherwise leave **Windows default input**
   selected.
5. Enter the security code shown by Ech0Mac.
6. Enable **Start Ech0 with Windows** if wanted.

When launch at login is enabled, Ech0 copies the executable to
`%LOCALAPPDATA%\Ech0` and registers it for the current user under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. Ech0Windows installs
no driver and does not require UAC or administrator privileges.

For a signed release, extract only the update ZIP produced by the signed release
pipeline and run `Update-Ech0.cmd`. The updater verifies the SHA-256 hash,
Authenticode signature, and expected publisher. It stops only the process
running from `%LOCALAPPDATA%\Ech0`, replaces that executable, and restarts it.
For an unsigned community build, verify the published hash and replace the
executable manually.

## 3. Discovery and pairing

Ech0Mac publishes the DNS-SD service `_ech0._tcp.local`. Ech0Windows first
tries native Windows discovery and always allows manual configuration with:

- the Mac host address or hostname;
- port `48484`;
- the Base32 security code shown by Ech0Mac.

After pairing, Windows stores the `receiverId`, the SHA-256 pin of the Mac
signing key, a `senderId`, and a random secret. The secret and any pending
pairing code are stored only in fields protected with DPAPI `CurrentUser`.
The Mac stores only the hash of the Windows secret, and its receiver private key
is owner-only. Windows deletes the one-time code after trust is confirmed.

A trusted session accepts only the saved receiver ID and signing-key pin. A
legacy v2 association without a pin intentionally requires one new pairing.

In Windows settings, a paired Mac appears as `Connected · Trusted` or
`Trusted · not reachable`. The code field appears only when pairing is
required. **Change Mac** preserves the existing association until the new Mac
confirms trust. **Reset pairing** immediately removes the local association.

If the Mac forgets a paired Windows device, it closes that session immediately.
Windows stops capture and reconnect attempts, shows `Pairing required` in the
tray, and displays a notification. Open settings and enter the Mac's current
code to establish new credentials.

Windows sends a heartbeat every second. If a crash, sleep transition, or network
change leaves an incomplete socket, Ech0Mac releases the sender slot after five
seconds so the next connection can proceed.

## 4. Automatic activation

Ech0Mac monitors public Core Audio process objects. Demand becomes active when
at least one process simultaneously reports running input I/O and the device ID
selected by Ech0Mac. Endpoint priority is:

1. `Ech0 Virtual Microphone`, the recommended input-only route;
2. `BlackHole 2ch`, an optional fallback when the dedicated driver is absent.

If BlackHole is selected, Ech0 configures it to 48 kHz because that is the
protocol sample rate. Ech0 does not change BlackHole when the dedicated driver
is active.

When demand becomes active, Ech0Mac sends `captureDemand`. Ech0Windows opens
the microphone selected in its settings through WASAPI shared, event-driven
capture. If **Windows default input** is selected, it resolves the current
default console capture endpoint when capture starts. Audio is transported as
PCM16 mono at 48 kHz in 20 ms frames.

If the selected endpoint is unavailable, Ech0 reports that it is waiting and
retries every two seconds while demand remains active. An explicitly selected
device ID is preserved across retries; the default-input option may follow a
new Windows default device.

When the last macOS consumer closes the input, Ech0Mac applies a short debounce,
Ech0Windows closes WASAPI, and the Mac clears its audio buffer.

The signal represents real audio I/O, not a private application UI state. For
example, a recorder that opens the microphone for a level preview is already a
consumer before the user presses Record. A manual capture control is available
only when Core Audio process monitoring is unavailable.

## 5. End-to-end verification

With Ech0Mac connected to Windows:

1. With no consumer, Ech0Mac should show `Automatic` and Windows capture
   should remain closed.
2. Open the Ech0 input in QuickTime Player, Codex, or another macOS application.
   Ech0Mac should show `Streaming`, and the received-frame counter should
   increase.
3. Speak and verify both the Ech0Mac level meter and reception in the target
   application.
4. Close capture. Within a few seconds Ech0Mac should return to idle with a
   `0 ms` buffer.
5. Open the same Ech0 input in two applications. Capture should stay active
   until the last consumer closes it.
6. Select a different macOS input in the target application. Ech0 should not
   start Windows capture.
7. Select a specific wireless Windows microphone in Ech0Windows, start capture,
   and disconnect that device. Ech0Windows should wait and retry the same
   endpoint instead of silently selecting another microphone. This invariant
   does not apply when **Windows default input** is selected.

Repository checks:

```sh
./scripts/macos-release.sh check
./scripts/build-windows.sh
```

For the authoritative Windows runtime check, run the C# suite on Windows with
the supported SDK:

```powershell
dotnet test windows/Ech0Windows.Tests/Ech0Windows.Tests.csproj -c Release
```

## Troubleshooting

### Ech0 detects a consumer but Windows does not capture

Confirm that Windows is running the current build and that the selected
microphone is connected. The tray reports a waiting state while Ech0 retries an
unavailable endpoint. For a signed release use `Ech0Windows-update.zip` and
`Update-Ech0.cmd`; for an unsigned community build, verify the published hash
and replace the executable manually.

### You hear your own voice in the headphones

This return path is normally produced by the Parsec audio route, not by Core
Audio demand monitoring. Disable host-audio return in Parsec and leave Ech0
responsible only for the microphone path.

### The macOS application does not receive audio

Confirm that the application uses the endpoint shown by Ech0Mac, normally
`Ech0 Virtual Microphone`, and has Microphone permission. Ech0Mac should show
received frames and a moving level meter while you speak.

### Windows discovery finds no Mac

Confirm that both computers are on the same LAN, allow Ech0Windows through the
Windows private-network firewall, or enter the Mac host address and port `48484`
manually.

### Windows asks for a code after the device was already trusted

After successful pairing, Windows should not retain or display the one-time
code. If it shows `Pairing required`, enter the current code visible on the
Mac. Do not manually copy or synchronize codes for a device that already
appears as `Trusted`.

## Intentional limitations

- One active sender at a time.
- No Internet relay or cloud fallback.
- No local audio recording.
- No changes to the Windows default microphone, volume, mute state, or exclusive
  mode.
- The TCP port is for the trusted local network, not direct Internet exposure.
