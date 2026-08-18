using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.ExceptionServices;

namespace Ech0.Windows;

internal enum AgentState
{
    Disconnected,
    PairingRequired,
    Connecting,
    Idle,
    DemandWaitingForDevice,
    Capturing,
    Paused,
}

internal static class RoundTripTime
{
    public static int Measure(ulong sentAtMs, ulong receivedAtMs)
    {
        var elapsedMs = receivedAtMs >= sentAtMs ? receivedAtMs - sentAtMs : 0;
        return (int)Math.Min(elapsedMs, (ulong)int.MaxValue);
    }
}

internal sealed class ConnectionWorker : IAsyncDisposable
{
    private readonly Ech0Settings settings;
    private readonly AudioCaptureService capture = new();
    private readonly SemaphoreSlim writeGate = new(1, 1);
    private readonly SemaphoreSlim captureGate = new(1, 1);
    private readonly CancellationTokenSource stop = new();
    private Stream? stream;
    private volatile bool paused;
    private volatile bool demandActive;
    private ulong demandGeneration;
    private long lastPongTimestamp;
    private int lastRoundTripMs = -1;
    private ulong sequence;
    private Task? runTask;
    private int lastLoggedAudioSession;

    public event Action<ConnectionWorker, AgentState, string?>? StateChanged;
    public string? CurrentDeviceName => capture.DeviceName;
    internal bool IsPaused => paused;

    public ConnectionWorker(Ech0Settings settings, bool initiallyPaused)
    {
        this.settings = settings;
        paused = initiallyPaused;
        capture.StoppedUnexpectedly += OnCaptureStoppedUnexpectedly;
    }

    public Task RunAsync() => runTask ??= RunReconnectLoopAsync(stop.Token);

    public void SetPaused(bool value)
    {
        paused = value;
        _ = ApplyPauseChangeAsync();
    }

    private async Task ApplyPauseChangeAsync()
    {
        try
        {
            await ApplyDemandAsync(stop.Token);
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            capture.Stop();
            Log.Write("pause_apply_failed", exception.GetType().Name);
        }
    }

    private async Task RunReconnectLoopAsync(CancellationToken cancellationToken)
    {
        var backoffSeconds = 1;
        while (!cancellationToken.IsCancellationRequested)
        {
            StateChanged?.Invoke(this, AgentState.Connecting, null);
            try
            {
                await RunConnectionAsync(cancellationToken);
                backoffSeconds = 1;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (PairingRequiredException exception)
            {
                Log.Write("pairing_required", exception.Message);
                settings.MarkPairingRequired();
                SettingsStore.Save(settings);
                StateChanged?.Invoke(this, AgentState.PairingRequired, null);
                return;
            }
            catch (Exception exception)
            {
                Log.Write("connection_failed", exception.GetType().Name);
                StateChanged?.Invoke(this, AgentState.Disconnected, exception.GetType().Name);
            }
            finally
            {
                capture.Stop();
                stream?.Dispose();
                stream = null;
                demandActive = false;
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(backoffSeconds), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            backoffSeconds = Math.Min(backoffSeconds * 2, 8);
        }
    }

    private async Task RunConnectionAsync(CancellationToken cancellationToken)
    {
        demandGeneration = 0;
        demandActive = false;
        using var client = new TcpClient { NoDelay = true };
        await client.ConnectAsync(settings.Host, settings.Port, cancellationToken);
        var authenticated = await ConnectionHandshake.ConnectAndAuthenticateAsync(
            client.GetStream(),
            settings,
            cancellationToken);
        stream = authenticated.Stream;
        lastPongTimestamp = Stopwatch.GetTimestamp();
        Volatile.Write(ref lastRoundTripMs, -1);

        var hello = authenticated.Hello;
        if (settings.TryCompleteTrust(hello))
        {
            SettingsStore.Save(settings);
            Log.Write("trust_confirmed", Log.SafeAuthentication(hello.Authentication));
        }

        Log.Write("connected");
        StateChanged?.Invoke(this, paused ? AgentState.Paused : AgentState.Idle, null);

        await ConnectionTaskGroup.RunUntilFirstCompletionAsync(
            [
                ReadLoopAsync,
                PingLoopAsync,
                AudioPumpAsync,
                CaptureRetryLoopAsync,
            ],
            cancellationToken);
    }

    private async Task ReadLoopAsync(CancellationToken cancellationToken)
    {
        var activeStream = stream ?? throw new InvalidOperationException("Not connected.");
        while (!cancellationToken.IsCancellationRequested)
        {
            var packet = await Ech0Protocol.ReadPacketAsync(activeStream, cancellationToken);
            if (packet.Type != Ech0Protocol.ControlType)
            {
                continue;
            }
            switch (Ech0Protocol.ReadKind(packet.Payload))
            {
                case "captureDemand":
                    var demand = Ech0Protocol.DecodeControl<CaptureDemand>(packet.Payload);
                    if (demand.Generation < demandGeneration)
                    {
                        break;
                    }
                    demandGeneration = demand.Generation;
                    demandActive = demand.Active;
                    Log.Write("capture_demand", demand.Active ? "active" : "inactive");
                    await ApplyDemandAsync(cancellationToken);
                    break;
                case "pong":
                    var pong = Ech0Protocol.DecodeControl<PongMessage>(packet.Payload);
                    var receivedAtMs = AudioCaptureService.MonotonicMilliseconds();
                    Volatile.Write(
                        ref lastRoundTripMs,
                        RoundTripTime.Measure(pong.MonotonicMs, receivedAtMs));
                    lastPongTimestamp = Stopwatch.GetTimestamp();
                    break;
                case "stop":
                    var stopMessage = Ech0Protocol.DecodeControl<StopMessage>(packet.Payload);
                    if (stopMessage.Reason is "trustRevoked" or "pairingRequired")
                    {
                        throw new PairingRequiredException(stopMessage.Reason);
                    }
                    throw new InvalidOperationException($"Mac stopped the session: {stopMessage.Reason}");
            }
        }
    }

    private async Task PingLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var roundTripMs = Volatile.Read(ref lastRoundTripMs);
            await WriteControlAsync(
                new PingMessage(
                    "ping",
                    AudioCaptureService.MonotonicMilliseconds(),
                    roundTripMs >= 0 ? roundTripMs : null),
                cancellationToken);
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
            var elapsed = Stopwatch.GetElapsedTime(lastPongTimestamp);
            if (elapsed > TimeSpan.FromSeconds(5))
            {
                throw new TimeoutException("Mac heartbeat timed out.");
            }
        }
    }

    private async Task AudioPumpAsync(CancellationToken cancellationToken)
    {
        await foreach (var pcm in capture.Frames.ReadAllAsync(cancellationToken))
        {
            if (!CaptureFrameGate.ShouldSend(
                frameSessionId: pcm.SessionId,
                frameGeneration: pcm.Generation,
                currentSessionId: capture.SessionId,
                currentGeneration: demandGeneration,
                isCapturing: capture.IsCapturing,
                paused: paused,
                demandActive: demandActive))
            {
                continue;
            }
            var packet = Ech0Protocol.EncodeAudio(
                sequence++,
                AudioCaptureService.MonotonicMilliseconds(),
                pcm.Pcm);
            await WritePacketAsync(packet, cancellationToken);
            if (pcm.SessionId != lastLoggedAudioSession
                && CaptureFrameGate.ShouldSend(
                    frameSessionId: pcm.SessionId,
                    frameGeneration: pcm.Generation,
                    currentSessionId: capture.SessionId,
                    currentGeneration: demandGeneration,
                    isCapturing: capture.IsCapturing,
                    paused: paused,
                    demandActive: demandActive))
            {
                lastLoggedAudioSession = pcm.SessionId;
                var elapsedMs = (long)Stopwatch.GetElapsedTime(capture.StartTimestamp).TotalMilliseconds;
                StateChanged?.Invoke(this, AgentState.Capturing, capture.DeviceName);
                await SendCaptureStatusAsync(
                    "capturing", null, cancellationToken, pcm.Generation);
                Log.Write("capture_first_frame_sent", $"{elapsedMs}ms");
            }
        }
    }

    private async Task CaptureRetryLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            if (demandActive && !paused && !capture.IsCapturing)
            {
                await ApplyDemandAsync(cancellationToken);
            }
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
        }
    }

    private void OnCaptureStoppedUnexpectedly(UnexpectedCaptureStop stoppedCapture)
    {
        _ = ReportUnexpectedCaptureStopAsync(stoppedCapture);
    }

    private async Task ReportUnexpectedCaptureStopAsync(UnexpectedCaptureStop stoppedCapture)
    {
        if (!CaptureDemandGate.ShouldReportUnexpectedStop(
            stoppedSessionId: stoppedCapture.SessionId,
            stoppedGeneration: stoppedCapture.Generation,
            currentSessionId: capture.SessionId,
            currentGeneration: demandGeneration,
            demandActive: demandActive,
            paused: paused))
        {
            return;
        }

        StateChanged?.Invoke(this, AgentState.DemandWaitingForDevice, stoppedCapture.ErrorCode);
        try
        {
            await SendCaptureStatusAsync(
                "error",
                stoppedCapture.ErrorCode,
                stop.Token,
                stoppedCapture.Generation);
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            Log.Write("capture_stop_status_failed", exception.GetType().Name);
        }
    }

    private async Task ApplyDemandAsync(CancellationToken cancellationToken)
    {
        await captureGate.WaitAsync(cancellationToken);
        try
        {
            if (!demandActive)
            {
                capture.Stop();
                StateChanged?.Invoke(this, AgentState.Idle, null);
                await SendCaptureStatusAsync("idle", null, cancellationToken);
                return;
            }
            if (paused)
            {
                capture.Stop();
                StateChanged?.Invoke(this, AgentState.Paused, null);
                await SendCaptureStatusAsync("paused", null, cancellationToken);
                return;
            }
            if (capture.IsCapturing)
            {
                return;
            }

            await SendCaptureStatusAsync("starting", null, cancellationToken);
            if (!CaptureDemandGate.ShouldStart(
                demandActive: demandActive,
                paused: paused,
                isCapturing: capture.IsCapturing))
            {
                return;
            }
            try
            {
                capture.Start(settings.InputDeviceId, demandGeneration);
                Log.Write("capture_started", "requested");
            }
            catch (Exception exception)
            {
                capture.Stop();
                var errorCode = exception.GetType().Name;
                StateChanged?.Invoke(this, AgentState.DemandWaitingForDevice, errorCode);
                await SendCaptureStatusAsync("error", errorCode, cancellationToken);
                Log.Write("capture_unavailable", errorCode);
            }
        }
        finally
        {
            captureGate.Release();
        }
    }

    private Task SendCaptureStatusAsync(
        string state,
        string? errorCode,
        CancellationToken cancellationToken,
        ulong? generation = null)
        => WriteControlAsync(
            new CaptureStatus("captureStatus", generation ?? demandGeneration, state, errorCode),
            cancellationToken);

    private Task WriteControlAsync<T>(T value, CancellationToken cancellationToken)
        => WritePacketAsync(Ech0Protocol.EncodeControl(value), cancellationToken);

    private async Task WritePacketAsync(byte[] packet, CancellationToken cancellationToken)
    {
        var activeStream = stream ?? throw new EndOfStreamException("Not connected.");
        await writeGate.WaitAsync(cancellationToken);
        try
        {
            await activeStream.WriteAsync(packet, cancellationToken);
            await activeStream.FlushAsync(cancellationToken);
        }
        finally
        {
            writeGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        stop.Cancel();
        capture.Stop();
        stream?.Dispose();
        if (runTask is not null)
        {
            try
            {
                await runTask;
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception exception)
            {
                Log.Write("shutdown_error", exception.GetType().Name);
            }
        }
        capture.StoppedUnexpectedly -= OnCaptureStoppedUnexpectedly;
        capture.Dispose();
        writeGate.Dispose();
        captureGate.Dispose();
        stop.Dispose();
    }
}

internal static class CaptureDemandGate
{
    public static bool ShouldStart(bool demandActive, bool paused, bool isCapturing)
        => demandActive && !paused && !isCapturing;

    public static bool ShouldReportUnexpectedStop(
        int stoppedSessionId,
        ulong stoppedGeneration,
        int currentSessionId,
        ulong currentGeneration,
        bool demandActive,
        bool paused)
        => demandActive
            && !paused
            && stoppedSessionId == currentSessionId
            && stoppedGeneration == currentGeneration;
}

internal static class ConnectionTaskGroup
{
    public static async Task RunUntilFirstCompletionAsync(
        IReadOnlyList<Func<CancellationToken, Task>> operations,
        CancellationToken cancellationToken)
    {
        if (operations.Count == 0)
        {
            throw new ArgumentException("At least one connection operation is required.", nameof(operations));
        }

        using var connectionStop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var tasks = operations.Select(operation => operation(connectionStop.Token)).ToArray();
        var completed = await Task.WhenAny(tasks);
        ExceptionDispatchInfo? primaryFailure = null;
        try
        {
            await completed;
        }
        catch (Exception exception)
        {
            primaryFailure = ExceptionDispatchInfo.Capture(exception);
        }

        connectionStop.Cancel();
        try
        {
            await Task.WhenAll(tasks);
        }
        catch (OperationCanceledException) when (connectionStop.IsCancellationRequested && primaryFailure is null)
        {
        }
        catch when (primaryFailure is not null)
        {
        }

        primaryFailure?.Throw();
    }
}

internal static class CaptureFrameGate
{
    public static bool ShouldSend(
        int frameSessionId,
        ulong frameGeneration,
        int currentSessionId,
        ulong currentGeneration,
        bool isCapturing,
        bool paused,
        bool demandActive)
        => isCapturing
            && !paused
            && demandActive
            && frameSessionId == currentSessionId
            && frameGeneration == currentGeneration;
}
