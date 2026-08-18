using System.Diagnostics;
using System.Threading.Channels;

namespace Ech0.Windows;

internal sealed class AudioCaptureService : IDisposable
{
    private readonly Channel<CapturedPcmFrame> frames = Channel.CreateBounded<CapturedPcmFrame>(
        new BoundedChannelOptions(8)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = true,
        });
    private readonly PcmFrameAccumulator accumulator = new();
    private readonly object captureSync = new();
    private readonly IAudioRecorderFactory recorderFactory;
    private IAudioRecorder? capture;
    private long startTimestamp;
    private bool loggedFirstDataAvailable;

    public AudioCaptureService()
        : this(new WasapiAudioRecorderFactory())
    {
    }

    internal AudioCaptureService(IAudioRecorderFactory recorderFactory)
    {
        this.recorderFactory = recorderFactory;
    }

    public event Action<UnexpectedCaptureStop>? StoppedUnexpectedly;
    public ChannelReader<CapturedPcmFrame> Frames => frames.Reader;
    public string? DeviceName { get; private set; }
    public bool IsCapturing
    {
        get
        {
            lock (captureSync)
            {
                return capture is not null;
            }
        }
    }
    public long StartTimestamp => startTimestamp;
    public int SessionId { get; private set; }
    public ulong Generation { get; private set; }

    public void Start(string? inputDeviceId, ulong generation)
    {
        lock (captureSync)
        {
            if (capture is not null)
            {
                return;
            }
        }

        var nextCapture = recorderFactory.Create(inputDeviceId);
        nextCapture.DataAvailable += OnDataAvailable;
        nextCapture.RecordingStopped += OnRecordingStopped;
        lock (captureSync)
        {
            if (capture is not null)
            {
                nextCapture.DataAvailable -= OnDataAvailable;
                nextCapture.RecordingStopped -= OnRecordingStopped;
                nextCapture.Dispose();
                return;
            }
            DeviceName = nextCapture.DeviceName;
            accumulator.Clear();
            startTimestamp = Stopwatch.GetTimestamp();
            loggedFirstDataAvailable = false;
            SessionId++;
            Generation = generation;
            capture = nextCapture;
        }
        try
        {
            nextCapture.StartRecording();
        }
        catch
        {
            if (DetachCapture(nextCapture, out _, out _))
            {
                nextCapture.Dispose();
            }
            throw;
        }
    }

    public void Stop()
    {
        IAudioRecorder? current;
        lock (captureSync)
        {
            current = capture;
            capture = null;
            DeviceName = null;
            accumulator.Clear();
        }
        if (current is null)
        {
            return;
        }
        current.DataAvailable -= OnDataAvailable;
        current.RecordingStopped -= OnRecordingStopped;
        try
        {
            current.StopRecording();
        }
        finally
        {
            current.Dispose();
        }
    }

    private void OnDataAvailable(IAudioRecorder sender, ReadOnlySpan<byte> buffer)
    {
        int sessionId;
        ulong generation;
        long? firstDataElapsedMs = null;
        IReadOnlyList<byte[]> completeFrames;
        lock (captureSync)
        {
            if (!ReferenceEquals(capture, sender))
            {
                return;
            }
            sessionId = SessionId;
            generation = Generation;
            if (!loggedFirstDataAvailable)
            {
                loggedFirstDataAvailable = true;
                firstDataElapsedMs = (long)Stopwatch.GetElapsedTime(startTimestamp).TotalMilliseconds;
            }
            completeFrames = accumulator.Append(buffer);
        }
        if (firstDataElapsedMs is long elapsedMs)
        {
            ThreadPool.QueueUserWorkItem(_ => Log.Write("capture_first_data", $"{elapsedMs}ms"));
        }
        foreach (var frame in completeFrames)
        {
            frames.Writer.TryWrite(new CapturedPcmFrame(sessionId, generation, frame));
        }
    }

    private void OnRecordingStopped(IAudioRecorder stoppedCapture, Exception? exception)
    {
        if (!DetachCapture(stoppedCapture, out var sessionId, out var generation))
        {
            return;
        }
        ThreadPool.QueueUserWorkItem(
            static recorder => DisposeStoppedRecorder((IAudioRecorder)recorder!),
            stoppedCapture);
        var errorCode = exception?.GetType().Name ?? "captureStopped";
        Log.Write(
            "audio_capture_stopped",
            errorCode);
        StoppedUnexpectedly?.Invoke(new UnexpectedCaptureStop(sessionId, generation, errorCode));
    }

    private static void DisposeStoppedRecorder(IAudioRecorder recorder)
    {
        try
        {
            recorder.Dispose();
        }
        catch (Exception exception)
        {
            Log.Write("audio_capture_dispose_failed", exception.GetType().Name);
        }
    }

    private bool DetachCapture(
        IAudioRecorder stoppedCapture,
        out int sessionId,
        out ulong generation)
    {
        lock (captureSync)
        {
            if (!ReferenceEquals(capture, stoppedCapture))
            {
                sessionId = 0;
                generation = 0;
                return false;
            }
            sessionId = SessionId;
            generation = Generation;
            capture = null;
            DeviceName = null;
            accumulator.Clear();
        }
        stoppedCapture.DataAvailable -= OnDataAvailable;
        stoppedCapture.RecordingStopped -= OnRecordingStopped;
        return true;
    }

    public void Dispose()
    {
        Stop();
        frames.Writer.TryComplete();
    }

    public static ulong MonotonicMilliseconds()
        => (ulong)(Stopwatch.GetTimestamp() * 1000L / Stopwatch.Frequency);
}

internal sealed record CapturedPcmFrame(int SessionId, ulong Generation, byte[] Pcm);
internal sealed record UnexpectedCaptureStop(int SessionId, ulong Generation, string ErrorCode);

internal sealed class PcmFrameAccumulator
{
    private readonly byte[] pending = new byte[Ech0Protocol.PcmBytesPerFrame];
    private int pendingCount;

    public IReadOnlyList<byte[]> Append(ReadOnlySpan<byte> bytes)
    {
        List<byte[]>? frames = null;
        while (!bytes.IsEmpty)
        {
            if (pendingCount == 0 && bytes.Length >= Ech0Protocol.PcmBytesPerFrame)
            {
                frames ??= [];
                frames.Add(bytes[..Ech0Protocol.PcmBytesPerFrame].ToArray());
                bytes = bytes[Ech0Protocol.PcmBytesPerFrame..];
                continue;
            }

            var copyLength = Math.Min(
                bytes.Length,
                Ech0Protocol.PcmBytesPerFrame - pendingCount);
            bytes[..copyLength].CopyTo(pending.AsSpan(pendingCount));
            pendingCount += copyLength;
            bytes = bytes[copyLength..];

            if (pendingCount == Ech0Protocol.PcmBytesPerFrame)
            {
                frames ??= [];
                frames.Add((byte[])pending.Clone());
                pendingCount = 0;
            }
        }
        return frames is null ? Array.Empty<byte[]>() : frames;
    }

    public void Clear() => pendingCount = 0;
}
