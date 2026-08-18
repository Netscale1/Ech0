using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Ech0.Windows;

internal delegate void AudioRecorderDataAvailableHandler(
    IAudioRecorder recorder,
    ReadOnlySpan<byte> buffer);

internal interface IAudioRecorder : IDisposable
{
    event AudioRecorderDataAvailableHandler? DataAvailable;
    event Action<IAudioRecorder, Exception?>? RecordingStopped;

    string DeviceName { get; }

    void StartRecording();
    void StopRecording();
}

internal interface IAudioRecorderFactory
{
    IAudioRecorder Create(string? inputDeviceId);
}

internal sealed class WasapiAudioRecorderFactory : IAudioRecorderFactory
{
    public IAudioRecorder Create(string? inputDeviceId)
    {
        using var enumerator = new MMDeviceEnumerator();
        var device = string.IsNullOrWhiteSpace(inputDeviceId)
            ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console)
            : enumerator.GetDevice(inputDeviceId);
        try
        {
            var recorder = new WasapiRecorderBuilder()
                .WithDevice(device)
                .WithSharedMode()
                .WithEventSync()
                .WithBufferLength(20)
                .WithFormat(new WaveFormat(48_000, 16, 1))
                .Build();
            return new WasapiAudioRecorder(recorder, device);
        }
        catch
        {
            device.Dispose();
            throw;
        }
    }
}

internal sealed class WasapiAudioRecorder : IAudioRecorder
{
    private readonly WasapiRecorder recorder;
    private readonly MMDevice device;
    private bool disposed;

    public WasapiAudioRecorder(WasapiRecorder recorder, MMDevice device)
    {
        this.recorder = recorder;
        this.device = device;
        recorder.DataAvailable += OnDataAvailable;
        recorder.RecordingStopped += OnRecordingStopped;
    }

    public event AudioRecorderDataAvailableHandler? DataAvailable;
    public event Action<IAudioRecorder, Exception?>? RecordingStopped;

    public string DeviceName => recorder.DeviceFriendlyName;

    public void StartRecording() => recorder.StartRecording();

    public void StopRecording() => recorder.StopRecording();

    private void OnDataAvailable(
        ReadOnlySpan<byte> buffer,
        AudioClientBufferFlags flags,
        long devicePosition,
        long qpcPosition)
        => DataAvailable?.Invoke(this, buffer);

    private void OnRecordingStopped(object? sender, StoppedEventArgs args)
        => RecordingStopped?.Invoke(this, args.Exception);

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        recorder.DataAvailable -= OnDataAvailable;
        recorder.RecordingStopped -= OnRecordingStopped;
        try
        {
            recorder.Dispose();
        }
        finally
        {
            device.Dispose();
        }
    }
}
