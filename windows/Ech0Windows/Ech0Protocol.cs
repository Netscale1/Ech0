using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ech0.Windows;

internal static class Ech0Protocol
{
    public const byte ControlType = 0x01;
    public const byte AudioType = 0x02;
    public const int MaximumControlPayloadSize = 16 * 1024;
    public const int MaximumPayloadSize = 64 * 1024;
    public const int SamplesPerFrame = 960;
    public const int PcmBytesPerFrame = SamplesPerFrame * 2;
    public const int AudioPayloadSize = 20 + PcmBytesPerFrame;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static byte[] EncodeControl<T>(T value)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        if (payload.Length > MaximumControlPayloadSize)
        {
            throw new InvalidDataException("Control payload is too large.");
        }
        return EncodePacket(ControlType, payload);
    }

    public static byte[] EncodeAudio(ulong sequence, ulong timestampMs, ReadOnlySpan<byte> pcm)
    {
        if (pcm.Length != PcmBytesPerFrame)
        {
            throw new InvalidDataException("Audio frame must contain exactly 20 ms of PCM16 mono audio.");
        }

        var payload = new byte[AudioPayloadSize];
        BinaryPrimitives.WriteUInt64BigEndian(payload.AsSpan(0, 8), sequence);
        BinaryPrimitives.WriteUInt64BigEndian(payload.AsSpan(8, 8), timestampMs);
        BinaryPrimitives.WriteUInt32BigEndian(payload.AsSpan(16, 4), 0);
        pcm.CopyTo(payload.AsSpan(20));
        return EncodePacket(AudioType, payload);
    }

    public static async Task<Packet> ReadPacketAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[5];
        await ReadExactlyAsync(stream, header, cancellationToken);
        var type = header[0];
        var length = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(1));
        if (length > MaximumPayloadSize || (type == ControlType && length > MaximumControlPayloadSize))
        {
            throw new InvalidDataException("Remote packet exceeds the allowed size.");
        }
        var payload = new byte[length];
        await ReadExactlyAsync(stream, payload, cancellationToken);
        return new Packet(type, payload);
    }

    public static T DecodeControl<T>(ReadOnlySpan<byte> payload) where T : class
        => JsonSerializer.Deserialize<T>(payload, JsonOptions)
            ?? throw new InvalidDataException("Invalid JSON control message.");

    public static string ReadKind(ReadOnlySpan<byte> payload)
    {
        using var document = JsonDocument.Parse(payload.ToArray());
        return document.RootElement.GetProperty("kind").GetString()
            ?? throw new InvalidDataException("Control message has no kind.");
    }

    private static byte[] EncodePacket(byte type, ReadOnlySpan<byte> payload)
    {
        var packet = new byte[5 + payload.Length];
        packet[0] = type;
        BinaryPrimitives.WriteUInt32BigEndian(packet.AsSpan(1, 4), (uint)payload.Length);
        payload.CopyTo(packet.AsSpan(5));
        return packet;
    }

    private static async Task ReadExactlyAsync(Stream stream, Memory<byte> destination, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var read = await stream.ReadAsync(destination[offset..], cancellationToken);
            if (read == 0)
            {
                throw new EndOfStreamException("Ech0 connection closed.");
            }
            offset += read;
        }
    }
}

internal sealed record Packet(byte Type, byte[] Payload);

internal sealed record ClientHello(
    string Kind,
    int ProtocolVersion,
    string Token,
    string DeviceName,
    string SenderId,
    string TrustedSecret,
    string[] Capabilities,
    int SampleRate,
    int Channels,
    int FrameMs);

internal sealed record KeyExchangeClientHello(
    string Kind,
    int ProtocolVersion,
    string AuthMode,
    string ClientEphemeralPublicKey,
    string ClientNonce,
    string? ExpectedReceiverId,
    string? ExpectedReceiverKeyHash);

internal sealed record KeyExchangeServerHello(
    string Kind,
    bool Accepted,
    string? Reason,
    string? ReceiverId,
    string? ServerSigningPublicKey,
    string? ServerEphemeralPublicKey,
    string? ServerNonce,
    string? Signature,
    string? PairingProof);

internal sealed record ServerHello(
    string Kind,
    bool Accepted,
    string? Reason,
    int TargetBufferMs,
    int? NegotiatedProtocolVersion,
    string[]? Capabilities,
    string? ReceiverId,
    string? ReceiverName,
    string? ReceiverKeyHash,
    string? Authentication,
    bool? TrustEstablished);

internal sealed record CaptureDemand(string Kind, bool Active, ulong Generation);
internal sealed record CaptureStatus(string Kind, ulong Generation, string State, string? ErrorCode);
internal sealed record PingMessage(string Kind, ulong MonotonicMs, int? RoundTripMs);
internal sealed record PongMessage(string Kind, ulong MonotonicMs);
internal sealed record StopMessage(string Kind, string Reason);
