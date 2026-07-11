using System.Buffers.Binary;
using Xunit;

namespace Ech0.Windows.Tests;

public sealed class ProtocolTests
{
    [Fact]
    public void AudioPacketHasExpectedWireShape()
    {
        var packet = Ech0Protocol.EncodeAudio(7, 99, new byte[Ech0Protocol.PcmBytesPerFrame]);

        Assert.Equal(5 + Ech0Protocol.AudioPayloadSize, packet.Length);
        Assert.Equal(Ech0Protocol.AudioType, packet[0]);
        Assert.Equal(Ech0Protocol.AudioPayloadSize, BinaryPrimitives.ReadInt32BigEndian(packet.AsSpan(1, 4)));
        Assert.Equal((ulong)7, BinaryPrimitives.ReadUInt64BigEndian(packet.AsSpan(5, 8)));
    }

    [Fact]
    public void AudioPacketRejectsWrongFrameSize()
    {
        Assert.Throws<InvalidDataException>(() => Ech0Protocol.EncodeAudio(0, 0, new byte[10]));
    }

    [Fact]
    public void CaptureStatusEncodesExpectedKind()
    {
        var packet = Ech0Protocol.EncodeControl(new CaptureStatus("captureStatus", 4, "capturing", null));
        var payload = packet.AsSpan(5);
        Assert.Equal("captureStatus", Ech0Protocol.ReadKind(payload));
    }

    [Fact]
    public void AccumulatorProducesOnlyCompleteFrames()
    {
        var accumulator = new PcmFrameAccumulator();
        var first = accumulator.Append(new byte[1_000]);
        var second = accumulator.Append(new byte[2_000]);

        Assert.Empty(first);
        Assert.Single(second);
        Assert.Equal(Ech0Protocol.PcmBytesPerFrame, second[0].Length);
    }
}
