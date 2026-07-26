# Ech0 Review Findings

This file is the engineering backlog for the repository-wide review started on 2026-07-16. A finding is closed only when its code change, regression coverage, and platform-specific verification are recorded here.

Status values: `open`, `in progress`, `verified`, `deferred with constraint`.

| ID | Priority | Area | Status | Completion evidence |
| --- | --- | --- | --- | --- |
| ECH-001 | P1 | Remove Android and its protocol/UI compatibility paths | verified | `android/` and its build/configuration paths are absent; source and product docs describe only Windows-to-Mac operation; macOS 66 tests and Windows 24 tests pass after the final tranches |
| ECH-002 | P0 | Authenticate and encrypt Windows-to-Mac transport; pin receiver identity; rate-limit pairing | verified | Protocol v3 uses ephemeral P-256 ECDH, persistent receiver signing identity, pairing proof or pinned trusted reconnect, HKDF-SHA256, and directional AES-256-GCM records; unit, adversarial, deterministic cross-runtime vector, and live cross-host pairing/reconnect tests pass |
| ECH-003 | P1 | Serialize Windows worker lifecycle and preserve pause across replacement | verified | Lifecycle gate, source-aware events, initial-pause regression, and isolated Windows Release build/test passed |
| ECH-004 | P1 | Cancel and join every per-connection task before reconnect or disposal | verified | Structured task-group regression proved sibling cleanup completes before failure propagation; isolated Windows Release build/test passed |
| ECH-005 | P1 | Give macOS `AudioOutputEngine` lifecycle one owner | verified | Network callbacks only enqueue frames; lifecycle state is lock-confined; conditional AudioUnit cleanup added; Swift strict-concurrency tests and Release app build passed |
| ECH-006 | P1 | Allow manual Codex capture fallback only while Accessibility state is unavailable | verified | Pure policy covers unavailable, permission-required, inactive, active, paused, and independent-consumer states; Swift tests and Release app build passed |
| ECH-007 | P1 | Confine Core Audio and Accessibility monitor state to their queues | verified | Retry and repeated start/stop regressions pass; clean strict-concurrency build and 51-test suite complete with zero warnings |
| ECH-008 | P2 | Make listener callbacks identity-aware and send terminal controls before closing | verified | Stale-generation and completion-sequencing regressions pass; terminal close now follows processed sends with a timeout fallback |
| ECH-009 | P1 | Report persistence failure and acknowledge trust only after durable storage | verified | Mac trust/forget rollback, identity-failure, no-false-ack tests and Windows concurrent atomic-write test pass |
| ECH-010 | P2 | Reset remote capture state per connection and report unexpected WASAPI stop | verified | Presentation reset and stale/paused capture-stop gate regressions pass; Windows Release build/test verifies event wiring |
| ECH-011 | P2 | Close conditional Core Audio/COM resources and remove unsafe CFString access | verified | AudioUnit failure cleanup, retained CFString ownership, and explicit MMDevice disposal are implemented; a real BlackHole harness completed 110 fresh-engine plus 100 reuse cycles with stable file descriptors and `leaks` reporting 0 bytes leaked |
| ECH-012 | P2 | Remove allocations and avoidable copies from real-time audio paths | verified | macOS render consumes into caller-owned Core Audio buffers, uses a non-blocking render lock, and has an identical checksum with ~38% lower median benchmark time; Windows span accumulator is 5.68–6.53x faster with ~49.6% fewer allocated bytes |
| ECH-013 | P2 | Add test-first release gates, CI, signing/integrity checks, and safe updater targeting | deferred with constraint | Local macOS release gate and remote Windows unsigned development gate pass; updater hash/publisher/full-path protections and pinned CI actions are verified. A real Authenticode/timestamp run and hosted CI run require external certificate credentials and an authorized push |
| ECH-014 | P2 | Cancel Windows settings/discovery/pairing continuations when the form closes | verified | Form-lifetime cancellation, linked pairing timeout, disposal guards, and serialized UI transitions compile cleanly; the connected-PC Release gate passes 24/24 tests with 0 warnings and errors |
| ECH-015 | P3 | Bound sustained multi-source unauthenticated handshake-slot exhaustion | deferred with constraint | Five-second handshake timeout and pairing-attempt limits bound individual work, but the single-active-sender product model does not fully absorb a distributed connection-slot DoS; keep the receiver off untrusted/Internet-facing networks or add a network-layer allowlist before such exposure |
| ECH-016 | P1 | Protect persisted receiver identity and trust metadata before writing secrets | verified | The containing directory is set to `0700` before atomic writes and both identity/trust files are set to `0600`; existing trust files fail closed if permissions cannot be hardened; regression tests assert both modes |
| ECH-017 | P3 | Remove deprecated xUnit v2 test dependencies | verified | Migrated to stable `xunit.v3` 3.2.2 with runner 3.1.5; 24/24 tests pass and connected-PC NuGet audits report no vulnerable or deprecated direct/transitive packages |
| ECH-018 | P2 | Make Windows release restore independent of machine-local NuGet configuration | verified | A fresh connected-PC gate first reproduced `NU1100`; both build paths now restore explicitly from NuGet.org and the no-source machine completes restore, tests, publish, and updater verification |
| ECH-019 | P2 | Keep local logging failures and network metadata out of the connection lifecycle | verified | Expected filesystem/ACL logging failures are best-effort, the connected event no longer persists the Mac host address, the regression passes, and the complete Windows gate is green |
| ECH-020 | P3 | Profile worst-case Accessibility full-tree scans before further optimization | verified | Baseline duty 3.779% fell to 0.636% (-83.2%), CPU fell 72.9%, and median nodes fell 99.1%; live Codex AX captures verified inactive/active controls and recovery transitions, while lifecycle, leak, strict Release, bundle, signing, and plist gates pass |

## Current constraints

- Preserve unrelated user changes already present in the working tree.
- Do not alter Windows pairing, configuration, installed application, or microphone state during remote verification unless explicitly authorized.
- Existing protocol-v2 associations require one new pairing so Windows can pin the receiver signing identity; there is no plaintext compatibility fallback.
- Production Windows release proof requires an available Authenticode certificate and trusted timestamp service; hosted CI proof requires an authorized repository push.
- The protocol protects content and credentials in transit, not compromised endpoints, traffic-volume metadata, or sustained distributed denial of service.

## Verification log

### 2026-07-16 — Windows lifecycle tranche

- Snapshot SHA-256: `80319cac3ec43b0d56114d59358b743a1571492fb51918f892dda833990d0b3d`.
- Verified in a temporary directory on the connected Windows PC with .NET SDK `10.0.301`.
- Restore and Release build passed with 0 errors.
- 13/13 tests passed, including `ConnectionWorkerStartsWithProvidedPauseState` and `ConnectionTaskGroupJoinsSiblingCleanupBeforePropagatingFailure`.
- Only warning: `NU1510` for the likely-unnecessary explicit `System.Security.Cryptography.ProtectedData` package reference.
- No publish, updater, executable launch, pairing/configuration mutation, or microphone activation occurred; the temporary directory was removed.

### 2026-07-16 — macOS capture ownership and fallback tranche

- The network receive callback no longer starts or stops Core Audio; it only enqueues into the thread-safe jitter buffer.
- `AudioOutputEngine` lifecycle state is protected by one lock, and partially-created AudioUnits are disposed on every configuration failure.
- Manual Codex capture is rejected whenever Accessibility has resolved either `.inactive` or `.active`; independent non-Codex consumers remain unaffected.
- 41/41 Swift tests passed, including three new capture-policy regressions.
- Strict-concurrency build/tests passed.
- Release app build, strict code-sign verification, and `Info.plist` validation passed.
- Remaining compiler warnings are tracked by ECH-011 and ECH-013.

### 2026-07-16 — persistence, state, listener, and resource tranche

- Trusted-device additions/removals roll back in-memory changes when atomic persistence fails; the server rejects pairing instead of claiming `trustEstablished`.
- Receiver identity creation now fails closed instead of returning an ephemeral UUID.
- Windows settings writes are serialized, atomic, and use unique temporary files.
- Audio/Accessibility/shortcut monitors and the network listener confine lifecycle state to their serial queues; stale listener callbacks are rejected by generation.
- Terminal controls are sent sequentially and disconnect only after their completion, with a one-second failure timeout.
- Disconnect and handshaking presentation states reset stale Windows capture state; unexpected WASAPI stops publish an error for the current session/generation.
- Core Audio CFString properties now use their retained ownership contract; partially configured AudioUnits and NAudio MMDevice wrappers are disposed explicitly.
- Clean macOS strict-concurrency build: 0 warnings. Full strict suite: 51/51 tests passed, 0 warnings.
- macOS Release app build, strict code-sign verification, and `Info.plist` validation passed.
- Windows snapshot SHA-256 `9d2aa53585d4d3a246ffe34023235618d379db02464321a85c576b03a62b7aff`: restore/build Release passed with 0 errors and 0 warnings; 15/15 tests passed on the connected PC.
- The explicit ProtectedData package was removed; `NU1510` is gone while DPAPI calls still compile against .NET 10.

### 2026-07-16 — real-time audio performance tranche

- macOS `JitterBuffer` now fills caller-owned memory, tracks queued samples incrementally, and the Core Audio callback expands mono directly into its destination buffers. The callback no longer creates an intermediate `[Int16]`.
- Five 500,000-callback Release benchmark runs produced identical checksums. Final median elapsed time fell from 61.192 ms to 37.954 ms (about 38%); frame ordering, zero-fill, adaptive buffering, overrun accounting, underrun behavior, and concurrent producer/consumer access are covered by the final strict-concurrency Swift suite.
- Windows `PcmFrameAccumulator` now uses one fixed partial-frame buffer and span copies instead of byte-wise `List<byte>` growth plus `GetRange`/`RemoveRange` copies.
- On the connected Windows PC, two deterministic 19.2 MB scenarios each produced the same 10,000 frames and checksum as the baseline. Median speedup was 6.53x for aligned chunks and 5.68x for variable fragmentation; allocated bytes fell by 49.6% and 49.7% respectively.
- Corrected snapshot SHA-256 `9cd20a52ebe22ef98680e5a055718dc6d8f678b93b38ead283eb446d14e1552e`: restore/build Release passed with 0 warnings and 0 errors; 17/17 tests passed, including fragmented ordering and partial-frame reset.
- No Windows product executable, publish, updater, microphone, pairing, configuration, registry, or installed application was touched; the remote temporary directory was removed and its original checkout remained clean at `1819502b3459bc3b241ad6620d90fed71dd0eda5`.

### 2026-07-16 — authenticated transport v3

- Protocol v2 and plaintext client hello are rejected. Pairing uses a 128-bit Base32 code, an ephemeral P-256 ECDH exchange, a persistent P-256 receiver signing key, and an HMAC proof bound to the complete transcript.
- Trusted reconnect verifies both the receiver UUID and the SHA-256 hash of its signing public key. Authentication modes cannot be mixed or downgraded.
- HKDF-SHA256 derives independent client-to-server and server-to-client AES-256-GCM keys. Every record authenticates its protocol version, direction, type, and monotonic sequence; tampering, replay, wrong-direction use, and sequence exhaustion fail closed.
- Credentials and sender identity first appear inside the encrypted client hello. A plaintext-wire regression confirms that neither the pairing code nor trusted secret appears in the key exchange or ciphertext.
- Pairing attempts are limited to 5 per peer and 20 globally per 60 seconds; the pre-authentication handshake has a five-second deadline.
- macOS cryptographic/adversarial coverage passed inside the 66-test strict-concurrency suite. Windows Release coverage passed inside its final 24-test suite with 0 warnings and errors.
- A deterministic CryptoKit/.NET vector produced byte-identical transcript, ECDH secret, HKDF keys, and AES-GCM record on both platforms.
- A live temporary network test between this Mac and the connected Windows PC completed first pairing and trusted reconnect. Both sessions agreed on the same receiver ID and pinned key hash; encrypted stop control was observed on the Mac. Result: `INTEROP_RESULT=PASS`.
- The test used temporary identities/settings only. It did not launch or modify the installed application, pairing/configuration, registry, microphone, or capture state; the remote checkout remained clean.

### 2026-07-16 — runtime resource verification

- A real `BlackHole 2ch` harness completed 110 newly-created `AudioOutputEngine` lifecycles plus 100 repeated start/stop cycles on reused instances.
- File descriptors remained stable after warm-up: `fdBefore=5`, `fdAfterWarmup=5`, `fdAfter=5`.
- Apple `leaks --atExit` reported `0 leaks for 0 total leaked bytes`.
- The already-running `/Applications/Ech0Mac.app` process was not touched.

### 2026-07-16 — release and updater gate

- `scripts/build-macos-app.sh` now runs the complete strict-concurrency test suite before its Release build, validates the app signature, and lints `Info.plist`.
- The Windows production release script tests before publish, requires Authenticode signing for both the application and updater, checks the expected certificate thumbprint, and creates an update package only from signed output.
- The updater verifies the manifest hash and embedded publisher identity, targets only the exact installed executable path, and re-verifies its isolated temporary copy before replacement. The legacy broad `taskkill` behavior is absent.
- On the connected PC, PowerShell parsing passed, all tests ran before self-contained publish, and the unsigned first-install development package was produced with no update archive. Positive verification passed; a tampered executable failed with the expected SHA-256 mismatch and exit code 1.
- The macOS workflow uses `macos-15`; the Windows workflow installs .NET 10. GitHub actions are pinned to immutable commit SHAs and workflow permissions are read-only.
- Actual Authenticode/timestamp validation is intentionally not claimed because signing credentials were unavailable. Actual hosted CI execution is intentionally not claimed because no push was authorized.

### 2026-07-16 — persisted-secret permission hardening

- The receiver-identity directory is changed to `0700` before the signing private key is written; the identity file is then set to `0600`.
- Trusted-device metadata follows the same ordering. Existing identity/trust files are re-hardened on load, and trust loading fails closed if permissions cannot be applied.
- Regression setup deliberately widened the directory to `0755` and files to `0644`; reload restored `0700`/`0600`.
- Final strict-concurrency macOS suite: 66/66 tests passed with 0 warnings. Release build, local signature verification, and `Info.plist` validation passed.

### 2026-07-16 — final Windows dependency and release gate

- A first fresh xUnit v3 snapshot reproduced `NU1100` on the connected PC because its machine-level NuGet configuration had no sources. Release/build scripts now restore explicitly from `https://api.nuget.org/v3/index.json` and run tests/publish with `--no-restore`.
- The next isolated gate exposed `NETSDK1151`: the executable xUnit v3 test project referenced a self-contained executable while not self-contained itself. Matching `SelfContained=true` fixed that SDK contract.
- Final snapshot SHA-256: `4290f9e2c3af7004a02136e4b62e043e2f184d3b0c6557b526d816b0e73631e0`.
- Observed order: explicit restore, 24/24 Release tests, self-contained publish, updater `VerifyOnly`, artifact creation. Compilation produced 0 warnings and 0 errors.
- `Ech0Windows-win-x64.zip` and `SHA256SUMS` were present; the unsigned development path correctly omitted `Ech0Windows-update.zip`.
- Direct/transitive NuGet audits found no vulnerable or deprecated packages. Resolved test versions were `xunit.v3` 3.2.2, `xunit.runner.visualstudio` 3.1.5, and `Microsoft.NET.Test.Sdk` 18.0.1.
- Logging I/O failure coverage passed; the connected log event no longer records the receiver host address.
- No product executable or updater install mode ran. The installed app, pairing, configuration, registry, and microphone were untouched; the temporary snapshot was removed and the original Windows checkout remained clean at `1819502b3459bc3b241ad6620d90fed71dd0eda5`.

### 2026-07-16 — final static and complexity audit

- Source, tests, product documentation, build scripts, and CI contain no Android/Gradle/Kotlin/QR compatibility residue. Ignored NuGet `obj` metadata may name compatibility target frameworks but is generated, untracked, and not an Ech0 Android build path.
- The complexity scan's SwiftUI-builder and callback-loop matches were syntax false positives. Core Audio process enumeration is event-driven and OS-bounded; Base32 normalization is fixed at 26 characters; asset-generation pixel loops are offline build work.
- `JitterBuffer` still uses `Array.removeFirst`, but the 120 ms cap bounds the queue to roughly six 20 ms frames; its final benchmark and concurrent stress regression are green. Replacing it with a custom deque would add complexity without measured benefit.
- Accessibility full-tree traversal was the only measurement-dependent watch item. ECH-020 is now closed with a measured bounded-subtree remediation, retained root fallbacks, and no observed main-thread, overlap, lifecycle, or memory regression.

### 2026-07-16 — ECH-020 predeclared profiling threshold

- Primary steady-state threshold: aggregate Accessibility-monitor duty cycle above 1% of one CPU core (`sum of measured monitor durations / scenario wall time`) or more than 2 percentage points of process CPU above the control scenario.
- Responsiveness threshold: any attributable main-thread stall above 16.7 ms. The monitor's AX work is expected to remain on its dedicated serial queue.
- Lifecycle threshold: any overlapping full scans, or more than 1% redundant full scans outside the explicitly scheduled priority retries.
- Memory threshold: more than 5 MiB resident growth after warm-up during the prolonged scenario, or a positive leak result.
- Distribution investigation triggers: full-scan p95 above 50 ms, p99 above 100 ms, or maximum above 250 ms. These do not alone justify an optimization unless frequency and aggregate impact also cross a threshold.
- Rationale: at the current five-second fallback interval, a 50 ms full scan already consumes 1% of one core. Transition bursts are evaluated separately over ten-second windows, with 5% duty cycle as the intervention threshold.

### 2026-07-16 — ECH-020 Accessibility profiling and remediation

#### Methodology

- Host: Apple M4, 16 GiB RAM, macOS 27.0 build `26A5378n`, Xcode 26.3, Swift 6.2.4. Results are not assumed to transfer unchanged to another macOS or Codex build.
- A temporary optimized (`-O -g`) harness compiled the production `CodexDictationAccessibilityMonitor.swift` directly with strict concurrency and warnings as errors. It reserved recorder storage before measurement and emitted JSON only after the monitor stopped.
- Optional `ContinuousClock` callbacks recorded poll and scan duration, reason, scope, nodes, matches, AX read failures, node-limit hits, overlap, state, and main-thread execution. Production construction supplies no callback. An `OSSignposter` interval named `AXScan` remains available with no formatted logging or measured-path string allocation.
- Process CPU came from `proc_pidinfo` task time with Mach timebase conversion. RSS was sampled once per second; growth is reported from the post-warm-up sample, not process launch.
- Time Profiler was attached to an already trusted harness. Its Hangs instrument used the 250 ms threshold. The custom signpost category was not enabled by that template, so JSON timing is authoritative while the trace is used for stacks and hang/thread validation.
- A signed temporary AppKit target exercised app absence, start, stop, restart, `SIGSTOP`, `SIGCONT`, and final termination without restarting Codex. A second temporary target forced a focused-subtree miss to verify the adaptive root fallback.
- A clean 600-second baseline and final 600-second run measured a live, changing Codex task. A paired 120-second A/B reduced tree-size drift. The installed Ech0 app, Windows agent, protocol, updater, and release pipeline were not touched.

#### Measured results

| Metric | 600 s baseline | 600 s final | Change |
| --- | ---: | ---: | ---: |
| Poll frequency | 10.001 Hz | 5.001 Hz | restored 200 ms cadence |
| Scheduled scan frequency | 0.198 Hz | 0.197 Hz | effectively unchanged |
| Scan count | 119 | 118 | — |
| Scan mean | 130.848 ms | 10.744 ms | -91.8% |
| Scan median | 131.445 ms | 12.571 ms | -90.4% |
| Scan p95 | 138.947 ms | 14.841 ms | -89.3% |
| Scan p99 | 144.430 ms | 19.099 ms | -86.8% |
| Scan maximum | 147.792 ms | 84.364 ms | final maximum is the one initial application-root scan |
| Nodes, mean | 3,204.9 | 41.1 | -98.7% |
| Nodes, median | 3,205 | 28 | -99.1% |
| Nodes, p95 / p99 / max | 3,205 / 3,206 / 3,207 | 28 / 28 / 1,577 | root maximum retained |
| Full-scan duty | 2.595% | 0.211% | -91.9% |
| Total monitor duty | 3.779% | 0.636% | -83.2%; below 1% threshold |
| Process CPU, one core | 1.134% | 0.308% | -72.9% |
| RSS growth after warm-up | -656 KiB | -768 KiB | no growth |
| AX read failures / node-limit hits | 0 / 0 | 0 / 0 | no regression |
| Overlap / main-thread scans | 0 / 0 | 0 / 0 | invariant preserved |

- The 120-second paired current-tree baseline measured 2.592% total duty, 0.811% CPU, 79.024 ms median, and 1,600 median nodes. The final 120-second run measured 0.763% duty, 0.319% CPU, 11.459 ms median, and 27 median nodes.
- With the target bundle absent for 120 seconds, the monitor performed no tree scan: 10.008 polls/s, 0.038 ms poll median, 0.089 ms p99, 0.052% duty, 0.178% CPU, and +96 KiB RSS after warm-up.
- Six priority requests over 60 seconds produced the declared immediate, +250 ms, and +750 ms retries: 18 priority scans, 5 interval scans, 1 target-change scan, 4.465% burst duty, zero overlap, and zero main-thread work. The retries are intentional rather than duplicate concurrent scans.
- The final 90-second lifecycle run reacquired both PIDs and recovered after `SIGCONT`. A stopped target produced a 3.007 s AX scan and a 6.013 s maximum poll, but all blocking remained on the serial monitor queue; state recovered from unavailable to inactive and no overlap occurred.
- The forced-subtree-miss target alternated exactly six bounded focused attempts and six root audits in 60 seconds, proving that the ten-second application fallback does not suppress the cached state. This synthetic tree is a branch test, not a Codex performance result.
- The final attached Time Profiler run measured 0.718% duty and 0.310% CPU. `potential-hangs` contained no rows. AX, LaunchServices, Mach/XPC waits, and Swift/CF bridging appeared only on worker threads; the main thread remained in its run loop.
- `leaks` on a trusted MallocStackLogging run reported `0 leaks for 0 total leaked bytes`. `heap` reported 3,055 live allocations / 392,016 bytes; its largest Swift buffers were the harness's pre-reserved poll (48 KiB) and scan (8 KiB) recorder arrays. The clean production-shaped 600-second RSS result is therefore used for growth assessment.

#### Live Codex manual evidence (2026-07-17)

- Read-only AX inventories, with no synthetic click or AX action, observed the real inactive composer as one `AXButton` described `Dictate` in a 1,022-node tree. With dictation open, a 1,379-node tree exposed the two expected `AXButton` controls, `Stop dictation` and `Transcribe and send`.
- A ten-second baseline capture started while the real composer remained active. Its initial application-root scan found both controls in 65.178 ms over 1,424 nodes, published `active`, and the following 100 polls all used the cached-active path. It recorded zero overlap and zero main-thread scans.
- A 75-second final capture against the live Codex UI recorded `inactive -> active -> inactive -> active` at offsets 0.086, 45.039, 60.676, and 70.869 seconds. Its 19 scans measured 12.576 ms mean, 5.011 ms median, 54.246 ms p95/p99/maximum, 28 median nodes, 0.894% total duty, and 0.432% process CPU; 15 scans used focused ancestry and four used the application root. It recorded zero overlap and zero main-thread scans.
- A short inactive paired check on the same live tree measured the periodic scan at 42.513 ms / 1,091 nodes for the baseline and 2.438 ms / 28 nodes for the final implementation. Because each five-second interval contributed only one periodic sample, this check corroborates scope selection but is not used as a distribution or as the primary performance decision.
- Codex does not expose composer gestures while the agent turn that owns the trusted harness is running, and sending a reply from an open dictation session closes that session. Runs whose planned gesture windows therefore recorded only `inactive` were rejected as invalid interactive evidence and are not included in the before/after result. The manually requested window/task switch changed the live application tree, but no independent event marker permits attribution of one exact scan to that gesture.

#### Technical decision and changes

- The measured remediation satisfies closure case B: the baseline exceeded the predeclared aggregate threshold, the actual cause was repeated full-application traversal, and the repeated final profiling shows a measurable improvement below threshold without main-thread, overlap, memory, or lifecycle regression. Live read-only Codex captures additionally verified both UI states and recovery transitions, so ECH-020 is `verified`.
- Cached controls are now validated and resolved from one description read per poll. The focused element is queried only when no cached control is valid.
- The timer returns to the repository's original 200 ms cadence. Priority scans remain immediate and the five-second scheduled scan cadence is preserved.
- Initial, target-change, cache-invalidated, multi-window, empty-cache, and multi-control scans still use the complete application tree. With exactly one window and one valid cached control, interval and priority scans first search at most eight focused ancestors with a 256-node bound per subtree.
- A focused miss keeps the valid cached state and audits the full application at most every ten seconds for ordinary interval scans. Priority, cache-recovery, and PID transitions always bypass that backoff.
- No new persistent AX reference or unbounded cache was introduced. Existing cached controls are cleared on failed validation, permission/app loss, PID change, stop, and restart; discovering a second control forces the next scheduled scan back to the application root.

#### Regression and profiling limitations

- Pure regressions cover inactive/active resolution and precedence, unavailable fallback policy, repeated start/stop/restart, scan-reason/reset behavior, application-fallback backoff, safe scope selection, multi-window/multi-control fallback, overlap detection, and PID loss/restart recovery.
- Focused strict-concurrency coverage passed 18/18 tests. A clean full build with strict concurrency and every warning promoted to an error passed 71/71 tests with zero warnings.
- The repository bundle gate repeated 71/71 tests, built the Release binary and asset catalog, and produced `dist/macos/Ech0Mac.app`. Apple Development signing with hardened runtime passed `codesign --verify --deep --strict`; `Info.plist` passed `plutil -lint` and retained identifier `net.ech0.mac`, version `0.2.0` build `2`, minimum macOS 13, and `LSUIElement=true`.
- Real lifecycle and error recovery are additionally covered by the temporary AX target. The node cap was instrumented but not reached by Codex; correctness for an application tree above 20,000 nodes remains unmeasured.
- The Allocations template could not attach under host security restrictions and its trace is excluded. RSS, `heap`, and `leaks` provide the memory evidence instead.
- The stopped-process failure was induced on a temporary AppKit target, not by killing the active Codex process. A physical Codex quit/relaunch would terminate the task and remains unmeasured; PID loss/reacquisition, AX failure, `SIGSTOP`/`SIGCONT`, termination, and restart recovery are instead covered by the temporary target and regressions.
- Automated UI control is prohibited for Codex in this environment. Live controls and state transitions were captured read-only, but exact gesture timestamps could not be injected into the trusted harness. No synthetic click or AX action was used as a substitute, and invalidly timed manual runs were explicitly excluded.
