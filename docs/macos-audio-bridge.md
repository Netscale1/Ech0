# macOS audio bridge architecture and performance

This note records the validated macOS audio path, the performance work already
completed, and the safety rules for future changes. It is intentionally limited
to reproducible project facts and contains no machine-specific configuration.

## Validated architecture

The active path is:

```text
Windows microphone
  -> Ech0Windows
  -> authenticated local TCP session
  -> Ech0Mac receiver
  -> Ech0 Virtual Microphone
  -> requesting macOS application
```

`Ech0 Virtual Microphone` is an `AudioServerPlugIn` device with one input stream
and no output streams. It presents two `Float32` input channels at 48 kHz to
Core Audio. Ech0Windows continues to send the protocol-compatible 48 kHz mono
`Int16` frames; Ech0Mac passes those frames to the driver, which converts and
duplicates the mono samples for the input stream.

Ech0Mac discovers the device by its stable UID and writes PCM through the
private Core Audio custom property `e0wr`. The payload is `CFData`, a property
list type that the Core Audio host can marshal across its process boundary.
`BlackHole 2ch` remains an optional compatibility fallback when the dedicated
device is not available. It is not a startup prerequisite. If neither endpoint
exists, Ech0 reports that audio setup is required instead of opening the server
with no usable microphone route. The 48 kHz BlackHole configuration is applied
only after BlackHole is selected as the fallback.

## System-wide activation

Ech0Mac observes Core Audio process objects and activates Windows capture when
any process reports active input I/O on the exact device prepared by
`AudioOutputEngine`. The normal target is `Ech0 Virtual Microphone`; if the
dedicated driver is unavailable, the monitor follows the `BlackHole 2ch`
fallback instead.

This is device-level, not application-specific. Ech0Mac does not inspect Codex
controls, poll Accessibility, or monitor a global keyboard shortcut. An
application that opens the microphone for a live preview is therefore an active
consumer even before it starts saving a recording; Core Audio cannot expose an
application's private semantic distinction between preview and record.

The monitor uses asynchronous property-listener callbacks for the Core Audio
process list, per-process input-running state, and per-process device list.
Ech0 itself is excluded from the consumer set so the bridge cannot trigger
itself. Parsec is treated like every other process: its independent playback
route does not count, while a real request for the Ech0 input does.

Relevant implementation:

- `macos/Sources/Ech0Mac/VirtualMicrophoneWriter.swift`
- `macos/Sources/Ech0Mac/AudioOutputEngine.swift`
- `macos/Driver/Ech0VirtualMic/`
- `scripts/build-macos-virtual-mic.sh`

## Parsec isolation constraint

The dedicated device must remain input-only. Adding an output stream, routing
Ech0 PCM through a normal output device, or mirroring it into another output
endpoint can make the microphone signal capturable by screen/audio forwarding
software.

The route assumptions are deliberately conceptual:

- the requesting macOS application uses `Ech0 Virtual Microphone` as its input;
- the existing playback and system-output route is preserved independently;
- Parsec remains connected and continues to carry only the playback path it was
  already configured to carry;
- Ech0 does not change the default output, headphone route, Parsec settings, or
  the Windows capture endpoint while installing or testing the microphone.

An ordinary or hidden BlackHole output is not an isolation boundary. The proof
of isolation is the dedicated device topology—one input, zero outputs—combined
with a live check that Parsec does not rebroadcast the microphone.

## High-energy diagnosis and mitigation

### Original problem

The receiver handles one audio frame every 20 ms. The original UI path updated
published frame counters and level state for every frame. Each update invalidated
the observable SwiftUI model and caused view work at roughly 50 Hz, even though
the interface did not need frame-rate visual refreshes.

Live profiling attributed the unexpectedly high app cost to this per-frame
metrics and UI invalidation path, not to an algorithmically expensive audio
codec. During an active voice session, the pre-fix app measured approximately:

| Metric | Before mitigation |
| --- | ---: |
| Ech0 CPU | 39–42% |
| Activity Monitor Energy Impact | about 260 |

### Implemented 4 Hz metrics path

`AudioFrameMetricsAccumulator` now records frame count, sequence, and level data
without publishing UI state for every frame. `ReceiverViewModel` snapshots and
publishes those metrics every 250 ms, and only while the Ech0 window is visible.
The first-frame latency event remains once per capture demand rather than once
per frame.

This keeps the audio receive/write path at 20 ms while limiting visual metrics
updates to 4 Hz. The focused and full Swift suites, signed Release build, live
microphone delivery, route preservation, and Parsec isolation were verified.

Measured active-session results after the mitigation were:

| Metric | Before | After | Approximate reduction |
| --- | ---: | ---: | ---: |
| Ech0 CPU | 39–42% | about 7.6% | about 81% |
| Energy Impact | about 260 | 9.1–9.9 | about 96% |

These values are diagnostic snapshots, not cross-machine benchmarks. Compare
changes with an A/B on the same Mac, session, route, and speaking workload.

## Residual-cost audit

After UI throttling, a live sample still showed the receive queue repeatedly
entering `VirtualMicrophoneWriter.write`, then
`AudioObjectSetPropertyData`, Core Audio proxy code, and Mach IPC.

The remaining app-side work is:

1. decode each protocol frame;
2. scan its samples for the input-level metric;
3. wrap the mono samples in `CFData`;
4. perform one custom-property write to Core Audio per 20 ms frame.

The level scan is linear in the samples in one fixed-size frame and is small.
The generic Core Audio property call and its cross-process copying/scheduling
dominate the residual sampled app stack. Core Audio driver scheduling and
conversion are required system work, but one marshalled custom-property call
per frame is a property of the current transport, not an inherent requirement
of an `AudioServerPlugIn`.

## Rejected two-frame batching experiment

A controlled experiment combined two 20 ms protocol frames into one 40 ms
custom-property write. The protocol, driver property, input-only topology,
routes, and Parsec connection were unchanged. Temporary instrumentation
recorded setter latency plus ring fill, underrun, and overrun counters.

The five-minute active-voice A/B measured:

| Metric | 20 ms baseline | 40 ms batching |
| --- | ---: | ---: |
| Ech0 CPU mean | 3.104% | 2.462% |
| Energy Impact mean | about 3.06 | about 2.64 |
| Setter p50 mean | 2.236 ms | 2.303 ms |
| Setter p95 mean | 2.777 ms | 2.826 ms |
| Added batch wait p50 | 0 ms | 20.005 ms |
| Added batch wait p95 | 0 ms | 22.698 ms |

The experiment required at least 25% lower Energy Impact, no new
glitch/underrun concern, and no more than 20 ms added first-audio latency. It was
rejected because:

- Energy Impact improved only about 13.9%;
- CPU improved about 20.7%, also short of the energy gate;
- added p95 wait was 22.698 ms, over the latency gate;
- the batched run recorded two initial ring underruns, even though its
  steady-state underrun delta later remained zero;
- no overrun was observed, but that was insufficient to pass the gate.

The pre-experiment app and driver were restored and reverified. The final live
state uses the 20 ms write behavior, the input-only device, the preserved
playback route, and an unchanged Parsec connection. Experimental batching and
driver telemetry are not part of the installed runtime.

## Operator and reproduction checklist

Use this checklist for performance work or a local installation. Privileged
installation must remain separate from source validation.

### Before changing the installed system

1. Record the current input, playback output, and system-output roles.
2. Confirm Parsec is connected and record its expected playback behavior.
3. Confirm the Ech0 TCP sender is established.
4. Build without installing:

   ```sh
   ./scripts/macos-release.sh check
   ```

5. Verify the app and driver signatures intended for installation.
6. Run the driver smoke test and confirm one input stream, zero output streams,
   PCM handoff, conversion, and reset behavior.
7. Preserve recoverable copies of the currently installed app and driver.

### Controlled active-voice A/B

1. Keep the same sender, microphone, route, Parsec session, and speaking
   workload for both runs.
2. Allow a short warm-up, then collect at least five minutes per variant.
3. Sample Ech0 CPU, Core Audio CPU, and Activity Monitor Energy Impact.
4. Capture a process sample and confirm which app/driver path is active.
5. Record setter p50/p95 and, when instrumented, ring fill, underrun, overrun,
   and write-call counts.
6. Check first-audio latency separately from steady-state throughput.
7. Verify live microphone delivery, input-only topology, unchanged routes, and
   absence of microphone rebroadcast through Parsec.
8. Reject the change if any declared energy, latency, glitch, route, or
   isolation gate fails.

### Installation and rollback

1. Install only artifacts that passed local tests, smoke checks, and signature
   verification.
2. Require the operator to approve macOS administrator authentication; never
   automate credential entry.
3. Restart Core Audio only when replacing the HAL driver.
4. Immediately recheck signatures, device topology, routes, TCP connectivity,
   microphone delivery, and Parsec isolation.
5. On failure, restore the previous app and driver from the recoverable copies,
   restart Core Audio if the driver changed, and repeat the complete live check.

## Future work (proposed, not implemented)

The next useful experiment should remove property IPC from the per-frame
streaming path rather than batch protocol frames.

### Shared-memory audio transport

Evaluate a bounded shared-memory ring between Ech0Mac and the
`AudioServerPlugIn`. Ech0Mac would write 20 ms protocol frames into the ring,
and the driver I/O callback would consume samples directly. The design must
specify ownership, atomic read/write indices, memory ordering, overflow policy,
process restart recovery, versioning, and a fallback path before it is safe to
implement.

This could preserve protocol compatibility and latency while avoiding
`CFData` allocation and one generic property/Mach round trip per frame. It is a
hypothesis until measured with the same A/B gate.

### Telemetry and clock drift

Add low-overhead, fixed-size telemetry for:

- ring fill and high-water mark;
- underrun and overrun totals;
- producer/consumer clock drift;
- first-audio and steady-state latency histograms;
- write/callback rates and reset generation.

Counters should be atomic, read infrequently, and published to the UI no faster
than the existing 4 Hz metrics boundary. Telemetry must not recreate the
per-frame observable-state regression it is intended to diagnose.
