# Ech0 Virtual Microphone

This directory contains the input-only Core Audio HAL plug-in for Ech0. It is
based on Apple's permissively licensed “Creating an Audio Server Driver
Plug-in” sample. The original license is in
`LICENSE-APPLE-SAMPLE.txt`.

The driver is intentionally separate from the Windows/macOS transport
protocol. Ech0 sends the same 48 kHz mono `Int16` frames to the device through
the private Core Audio property `e0wr`. Each frame is wrapped in `CFData`, which
is one of the property-list types the Audio Server host can marshal. The driver
publishes one input stream and no output streams.

Build without installing:

```sh
./scripts/build-macos-virtual-mic.sh
```

The resulting bundle is `dist/macos/Ech0VirtualMic.driver`. The build also runs
deterministic smoke tests for the input-only 48 kHz topology, PCM handoff,
conversion and overflow, plus a dedicated ThreadSanitizer test for concurrent
write, clear and read. The driver bundle is neither signed nor installed.

Runtime validation requires signing the bundle with a macOS code-signing
identity, installing it in `/Library/Audio/Plug-Ins/HAL`, and restarting macOS
(Apple's sample requires a reboot). Installation requires administrator
authorization. Those steps are deliberately not performed by the build script.
