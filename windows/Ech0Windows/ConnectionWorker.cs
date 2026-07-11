using System.Diagnostics;
using System.Net.Sockets;

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

internal sealed class ConnectionWorker : IAsyncDisposable
{
    private readonly Ech0Settings settings;
    private readonly AudioCaptureService capture = new();
    private readonly SemaphoreSlim writeGate = new(1, 1);
    private readonly SemaphoreSlim captureGate = new(1, 1);
    private readonly CancellationTokenSource stop = new();
    private NetworkStream? stream;
    private volatile bool paused;
    private volatile bool demandActive;
    private ulong demandGeneration;
    private long lastPongTimestamp;
    private ulong sequence;
    private Task? runTask;
    private int lastLoggedAudioSession;

    public event Action<AgentState, string?>? StateChanged;
    public string? CurrentDeviceName => capture.DeviceName;

    public ConnectionWorker(Ech0Settings settings)
    {
        this.settings = settings;
    }

    public Task RunAsync() => runTask ??= RunReconnectLoopAsync(stop.Token);

    public void SetPaused(bool value)
    {
        paused = value;
        _ = ApplyDemandAsync(stop.Token);
    }

    private async Task RunReconnectLoopAsync(CancellationToken cancellationToken)
    {
        var backoffSeconds = 1;
        while (!cancellationToken.IsCancellationRequested)
        {
            StateChanged?.Invoke(AgentState.Connecting, null);
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
                StateChanged?.Invoke(AgentState.PairingRequired, null);
                return;
            }
            catch (Exception exception)
            {
                Log.Write("connection_failed", exception.GetType().Name);
                StateChanged?.Invoke(AgentState.Disconnected, exception.GetType().Name);
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
        stream = client.GetStream();
        lastPongTimestamp = Stopwatch.GetTimestamp();

        var hello = await ConnectionHandshake.ConnectAndAuthenticateAsync(stream, settings, cancellationToken);
        if (settings.TryCompleteTrust(hello))
        {
            SettingsStore.Save(settings);
            Log.Write("trust_confirmed", hello.Authentication ?? "unknown");
        }

        Log.Write("connected", settings.Host);
        StateChanged?.Invoke(AgentState.Idle, null);

        using var connectionStop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var tasks = new[]
        {
            ReadLoopAsync(connectionStop.Token),
            PingLoopAsync(connectionStop.Token),
            AudioPumpAsync(connectionStop.Token),
            CaptureRetryLoopAsync(connectionStop.Token),
        };
        var completed = await Task.WhenAny(tasks);
        connectionStop.Cancel();
        await completed;
        try
        {
            await Task.WhenAll(tasks);
        }
        catch (OperationCanceledException) when (connectionStop.IsCancellationRequested)
        {
        }
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
            await WriteControlAsync(
                new PingMessage("ping", AudioCaptureService.MonotonicMilliseconds()),
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
            if (!capture.IsCapturing || paused || !demandActive)
            {
                continue;
            }
            var packet = Ech0Protocol.EncodeAudio(
                sequence++,
                AudioCaptureService.MonotonicMilliseconds(),
                pcm);
            await WritePacketAsync(packet, cancellationToken);
            if (capture.SessionId != lastLoggedAudioSession)
            {
                lastLoggedAudioSession = capture.SessionId;
                var elapsedMs = (long)Stopwatch.GetElapsedTime(capture.StartTimestamp).TotalMilliseconds;
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

    private async Task ApplyDemandAsync(CancellationToken cancellationToken)
    {
        await captureGate.WaitAsync(cancellationToken);
        try
        {
            if (!demandActive)
            {
                capture.Stop();
                StateChanged?.Invoke(AgentState.Idle, null);
                await SendCaptureStatusAsync("idle", null, cancellationToken);
                return;
            }
            if (paused)
            {
                capture.Stop();
                StateChanged?.Invoke(AgentState.Paused, null);
                await SendCaptureStatusAsync("paused", null, cancellationToken);
                return;
            }
            if (capture.IsCapturing)
            {
                return;
            }

            await SendCaptureStatusAsync("starting", null, cancellationToken);
            try
            {
                capture.Start(settings.InputDeviceId);
                StateChanged?.Invoke(AgentState.Capturing, capture.DeviceName);
                await SendCaptureStatusAsync("capturing", null, cancellationToken);
                Log.Write("capture_started", capture.DeviceName);
            }
            catch (Exception exception)
            {
                capture.Stop();
                var errorCode = exception.GetType().Name;
                StateChanged?.Invoke(AgentState.DemandWaitingForDevice, errorCode);
                await SendCaptureStatusAsync("error", errorCode, cancellationToken);
                Log.Write("capture_unavailable", errorCode);
            }
        }
        finally
        {
            captureGate.Release();
        }
    }

    private Task SendCaptureStatusAsync(string state, string? errorCode, CancellationToken cancellationToken)
        => WriteControlAsync(
            new CaptureStatus("captureStatus", demandGeneration, state, errorCode),
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
        capture.Dispose();
        writeGate.Dispose();
        captureGate.Dispose();
        stop.Dispose();
    }
}
