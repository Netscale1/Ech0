using System.Buffers.Binary;
using System.Text.Json;
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
    public void ServerHelloDecodesTrustedReceiverIdentity()
    {
        var json = """{"kind":"serverHello","accepted":true,"reason":null,"targetBufferMs":60,"negotiatedProtocolVersion":2,"capabilities":["remoteCaptureControl"],"receiverId":"receiver-1","receiverName":"Mac mini","authentication":"trusted","trustEstablished":true}"""u8;

        var hello = Ech0Protocol.DecodeControl<ServerHello>(json);

        Assert.Equal("receiver-1", hello.ReceiverId);
        Assert.Equal("trusted", hello.Authentication);
        Assert.True(hello.TrustEstablished);
    }

    [Fact]
    public void LegacyServerHelloLeavesNewFieldsEmpty()
    {
        var json = """{"kind":"serverHello","accepted":true,"reason":null,"targetBufferMs":60,"negotiatedProtocolVersion":2,"capabilities":["remoteCaptureControl"]}"""u8;

        var hello = Ech0Protocol.DecodeControl<ServerHello>(json);

        Assert.Null(hello.ReceiverId);
        Assert.Null(hello.TrustEstablished);
    }

    [Fact]
    public void TrustConfirmationMigratesLegacySettingsAndClearsToken()
    {
        var settings = new Ech0Settings
        {
            Host = "mac.local",
            ProtectedPairingToken = "legacy-token",
        };
        var hello = new ServerHello(
            "serverHello", true, null, 60, 2, ["remoteCaptureControl"],
            "receiver-1", "Mac mini", "trusted", true);

        Assert.True(settings.TryCompleteTrust(hello));
        Assert.Equal(PairingState.Trusted, settings.PairingState);
        Assert.Equal("Mac mini", settings.ReceiverName);
        Assert.Empty(settings.ProtectedPairingToken);
    }

    [Fact]
    public void LegacyHelloDoesNotClearPairingToken()
    {
        var settings = new Ech0Settings
        {
            Host = "mac.local",
            ProtectedPairingToken = "legacy-token",
        };
        var hello = new ServerHello(
            "serverHello", true, null, 60, 2, ["remoteCaptureControl"],
            null, null, null, null);

        Assert.False(settings.TryCompleteTrust(hello));
        Assert.Equal(PairingState.PairingPending, settings.PairingState);
        Assert.Equal("legacy-token", settings.ProtectedPairingToken);
    }

    [Fact]
    public void PairingRequiredInvalidatesTrustWithoutErasingReceiverDetails()
    {
        var settings = new Ech0Settings
        {
            Host = "mac.local",
            ReceiverId = "receiver-1",
            ReceiverName = "Mac mini",
            TrustConfirmed = true,
        };

        settings.MarkPairingRequired();

        Assert.Equal(PairingState.Unpaired, settings.PairingState);
        Assert.Equal("receiver-1", settings.ReceiverId);
        Assert.Equal("Mac mini", settings.ReceiverName);
    }

    [Fact]
    public void SettingsJsonNeverSerializesPlaintextCredentialProperties()
    {
        var settings = new Ech0Settings
        {
            ProtectedTrustedSecret = "dpapi-secret",
            ProtectedPairingToken = "dpapi-token",
        };

        using var document = JsonDocument.Parse(JsonSerializer.Serialize(settings));
        var propertyNames = document.RootElement.EnumerateObject().Select(property => property.Name).ToArray();

        Assert.DoesNotContain("TrustedSecret", propertyNames);
        Assert.DoesNotContain("PairingToken", propertyNames);
        Assert.Contains("ProtectedTrustedSecret", propertyNames);
        Assert.Contains("ProtectedPairingToken", propertyNames);
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
