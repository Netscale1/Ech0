using Xunit;

namespace Ech0.Windows.Tests;

public sealed class AudioCaptureServiceTests
{
    [Fact]
    public void StartUsesRequestedDeviceAndDoesNotCreateDuplicateRecorder()
    {
        var recorder = new FakeAudioRecorder("USB microphone");
        var factory = new FakeAudioRecorderFactory(recorder);
        using var service = new AudioCaptureService(factory);

        service.Start("device-1", 7);
        service.Start("device-1", 7);

        Assert.Equal(["device-1"], factory.RequestedDeviceIds);
        Assert.Equal(1, recorder.StartCount);
        Assert.True(service.IsCapturing);
        Assert.Equal("USB microphone", service.DeviceName);
        Assert.Equal(1, service.SessionId);
        Assert.Equal((ulong)7, service.Generation);
    }

    [Fact]
    public void StartFailureReleasesRecorderAndAllowsRetry()
    {
        var failedRecorder = new FakeAudioRecorder("unavailable")
        {
            StartException = new InvalidOperationException("device unavailable"),
        };
        var workingRecorder = new FakeAudioRecorder("working");
        var factory = new FakeAudioRecorderFactory(failedRecorder, workingRecorder);
        using var service = new AudioCaptureService(factory);

        Assert.Throws<InvalidOperationException>(() => service.Start("device-1", 3));
        Assert.True(failedRecorder.Disposed);
        Assert.False(service.IsCapturing);
        Assert.Null(service.DeviceName);

        service.Start("device-2", 4);

        Assert.True(service.IsCapturing);
        Assert.Equal("working", service.DeviceName);
        Assert.Equal(2, service.SessionId);
        Assert.Equal((ulong)4, service.Generation);
    }

    [Fact]
    public void ZeroCopyCallbackIsCopiedIntoOwnedCompleteFrame()
    {
        var recorder = new FakeAudioRecorder("microphone");
        using var service = new AudioCaptureService(new FakeAudioRecorderFactory(recorder));
        service.Start(null, 9);
        var callbackBuffer = Enumerable.Repeat((byte)0x5a, Ech0Protocol.PcmBytesPerFrame).ToArray();

        recorder.RaiseData(callbackBuffer);
        Array.Fill(callbackBuffer, (byte)0);

        Assert.True(service.Frames.TryRead(out var frame));
        Assert.Equal(1, frame.SessionId);
        Assert.Equal((ulong)9, frame.Generation);
        Assert.All(frame.Pcm, value => Assert.Equal((byte)0x5a, value));
    }

    [Fact]
    public void StopClearsPartialFrameBeforeNextSession()
    {
        var firstRecorder = new FakeAudioRecorder("first");
        var secondRecorder = new FakeAudioRecorder("second");
        using var service = new AudioCaptureService(
            new FakeAudioRecorderFactory(firstRecorder, secondRecorder));
        service.Start(null, 1);
        firstRecorder.RaiseData(Enumerable.Repeat((byte)0x11, 123).ToArray());

        service.Stop();
        service.Start(null, 2);
        secondRecorder.RaiseData(
            Enumerable.Repeat((byte)0x22, Ech0Protocol.PcmBytesPerFrame).ToArray());

        Assert.True(firstRecorder.Disposed);
        Assert.True(service.Frames.TryRead(out var frame));
        Assert.Equal(2, frame.SessionId);
        Assert.Equal((ulong)2, frame.Generation);
        Assert.All(frame.Pcm, value => Assert.Equal((byte)0x22, value));
    }

    [Fact]
    public void UnexpectedStopReportsSessionAndDisposesOutsideCallback()
    {
        var recorder = new FakeAudioRecorder("microphone");
        var replacement = new FakeAudioRecorder("replacement");
        using var service = new AudioCaptureService(
            new FakeAudioRecorderFactory(recorder, replacement));
        UnexpectedCaptureStop? observed = null;
        service.StoppedUnexpectedly += stopped => observed = stopped;
        service.Start(null, 12);

        recorder.RaiseStopped(new IOException("device removed"));

        Assert.NotNull(observed);
        Assert.Equal(1, observed.SessionId);
        Assert.Equal((ulong)12, observed.Generation);
        Assert.Equal(nameof(IOException), observed.ErrorCode);
        Assert.False(service.IsCapturing);
        Assert.Null(service.DeviceName);
        Assert.True(SpinWait.SpinUntil(() => recorder.Disposed, TimeSpan.FromSeconds(2)));
        Assert.NotEqual(recorder.RecordingStoppedThreadId, recorder.DisposeThreadId);

        service.Start(null, 13);

        Assert.True(service.IsCapturing);
        Assert.Equal("replacement", service.DeviceName);
        Assert.Equal(2, service.SessionId);
        Assert.Equal((ulong)13, service.Generation);
    }

    [Fact]
    public void ManualStopDoesNotReportUnexpectedStop()
    {
        var recorder = new FakeAudioRecorder("microphone")
        {
            RaiseStoppedWhenStopRequested = true,
        };
        using var service = new AudioCaptureService(new FakeAudioRecorderFactory(recorder));
        var unexpectedStopCount = 0;
        service.StoppedUnexpectedly += _ => unexpectedStopCount++;
        service.Start(null, 5);

        service.Stop();

        Assert.Equal(1, recorder.StopCount);
        Assert.True(recorder.Disposed);
        Assert.Equal(0, unexpectedStopCount);
        Assert.False(service.IsCapturing);
    }

    private sealed class FakeAudioRecorderFactory(params FakeAudioRecorder[] recorders)
        : IAudioRecorderFactory
    {
        private readonly Queue<FakeAudioRecorder> remaining = new(recorders);

        public List<string?> RequestedDeviceIds { get; } = [];

        public IAudioRecorder Create(string? inputDeviceId)
        {
            RequestedDeviceIds.Add(inputDeviceId);
            return remaining.Dequeue();
        }
    }

    private sealed class FakeAudioRecorder(string deviceName) : IAudioRecorder
    {
        private int disposed;

        public event AudioRecorderDataAvailableHandler? DataAvailable;
        public event Action<IAudioRecorder, Exception?>? RecordingStopped;

        public string DeviceName { get; } = deviceName;
        public Exception? StartException { get; init; }
        public bool RaiseStoppedWhenStopRequested { get; init; }
        public int StartCount { get; private set; }
        public int StopCount { get; private set; }
        public bool Disposed => Volatile.Read(ref disposed) == 1;
        public int? RecordingStoppedThreadId { get; private set; }
        public int? DisposeThreadId { get; private set; }

        public void StartRecording()
        {
            StartCount++;
            if (StartException is not null)
            {
                throw StartException;
            }
        }

        public void StopRecording()
        {
            StopCount++;
            if (RaiseStoppedWhenStopRequested)
            {
                RaiseStopped(null);
            }
        }

        public void RaiseData(byte[] buffer) => DataAvailable?.Invoke(this, buffer);

        public void RaiseStopped(Exception? exception)
        {
            RecordingStoppedThreadId = Environment.CurrentManagedThreadId;
            RecordingStopped?.Invoke(this, exception);
        }

        public void Dispose()
        {
            DisposeThreadId = Environment.CurrentManagedThreadId;
            Volatile.Write(ref disposed, 1);
        }
    }
}
