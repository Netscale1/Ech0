using System.Diagnostics;
using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Ech0.Windows;

internal sealed class AudioCaptureService : IDisposable
{
    private readonly Channel<byte[]> frames = Channel.CreateBounded<byte[]>(
        new BoundedChannelOptions(8)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = true,
        });
    private readonly PcmFrameAccumulator accumulator = new();
    private WasapiCapture? capture;
    private long startTimestamp;
    private bool loggedFirstDataAvailable;

    public ChannelReader<byte[]> Frames => frames.Reader;
    public string? DeviceName { get; private set; }
    public bool IsCapturing => capture is not null;
    public long StartTimestamp => startTimestamp;
    public int SessionId { get; private set; }

    public void Start(string? inputDeviceId = null)
    {
        if (capture is not null)
        {
            return;
        }

        using var enumerator = new MMDeviceEnumerator();
        var device = string.IsNullOrWhiteSpace(inputDeviceId)
            ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console)
            : enumerator.GetDevice(inputDeviceId);
        var nextCapture = new WasapiCapture(device, true, 20)
        {
            WaveFormat = new WaveFormat(48_000, 16, 1),
        };
        nextCapture.DataAvailable += OnDataAvailable;
        nextCapture.RecordingStopped += OnRecordingStopped;
        DeviceName = device.FriendlyName;
        accumulator.Clear();
        startTimestamp = Stopwatch.GetTimestamp();
        loggedFirstDataAvailable = false;
        SessionId++;
        nextCapture.StartRecording();
        capture = nextCapture;
    }

    public void Stop()
    {
        var current = capture;
        capture = null;
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
            DeviceName = null;
            accumulator.Clear();
        }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs args)
    {
        if (!loggedFirstDataAvailable)
        {
            loggedFirstDataAvailable = true;
            var elapsedMs = (long)Stopwatch.GetElapsedTime(startTimestamp).TotalMilliseconds;
            ThreadPool.QueueUserWorkItem(_ => Log.Write("capture_first_data", $"{elapsedMs}ms"));
        }
        foreach (var frame in accumulator.Append(args.Buffer.AsSpan(0, args.BytesRecorded)))
        {
            frames.Writer.TryWrite(frame);
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs args)
    {
        if (args.Exception is not null)
        {
            Log.Write("audio_capture_stopped", args.Exception.GetType().Name);
        }
    }

    public void Dispose()
    {
        Stop();
        frames.Writer.TryComplete();
    }

    public static ulong MonotonicMilliseconds()
        => (ulong)(Stopwatch.GetTimestamp() * 1000L / Stopwatch.Frequency);
}

internal sealed class PcmFrameAccumulator
{
    private readonly List<byte> pending = new(Ech0Protocol.PcmBytesPerFrame * 2);

    public IReadOnlyList<byte[]> Append(ReadOnlySpan<byte> bytes)
    {
        for (var index = 0; index < bytes.Length; index++)
        {
            pending.Add(bytes[index]);
        }
        var frames = new List<byte[]>();
        while (pending.Count >= Ech0Protocol.PcmBytesPerFrame)
        {
            frames.Add(pending.GetRange(0, Ech0Protocol.PcmBytesPerFrame).ToArray());
            pending.RemoveRange(0, Ech0Protocol.PcmBytesPerFrame);
        }
        return frames;
    }

    public void Clear() => pending.Clear();
}
