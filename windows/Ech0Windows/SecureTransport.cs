using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace Ech0.Windows;

internal static class PairingCode
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    public const int NormalizedLength = 26;

    public static string? Normalize(string value)
    {
        var normalized = new string(value
            .Where(character => character != '-' && !char.IsWhiteSpace(character))
            .Select(char.ToUpperInvariant)
            .ToArray());
        return normalized.Length == NormalizedLength
            && normalized.All(character => Alphabet.Contains(character))
                ? normalized
                : null;
    }

    public static bool IsValid(string value) => Normalize(value) is not null;
}

internal sealed record SecureSessionKeyMaterial(
    byte[] ClientWriteKey,
    byte[] ServerWriteKey,
    byte[] ClientNoncePrefix,
    byte[] ServerNoncePrefix)
{
    public static SecureSessionKeyMaterial Derive(
        ReadOnlySpan<byte> sharedSecret,
        ReadOnlySpan<byte> transcript,
        ReadOnlySpan<byte> clientNonce,
        ReadOnlySpan<byte> serverNonce)
    {
        var saltInput = new byte[clientNonce.Length + serverNonce.Length];
        clientNonce.CopyTo(saltInput);
        serverNonce.CopyTo(saltInput.AsSpan(clientNonce.Length));
        var salt = SHA256.HashData(saltInput);
        var transcriptHash = SHA256.HashData(transcript);
        var label = "Ech0-v3-session"u8;
        var info = new byte[label.Length + transcriptHash.Length];
        label.CopyTo(info);
        transcriptHash.CopyTo(info.AsSpan(label.Length));
        var output = HKDF.DeriveKey(
            HashAlgorithmName.SHA256,
            sharedSecret.ToArray(),
            72,
            salt,
            info);
        return new SecureSessionKeyMaterial(
            output[..32],
            output[32..64],
            output[64..68],
            output[68..72]);
    }
}

internal sealed class SecureRecordSession : IDisposable
{
    public const int HeaderLength = 16;
    public const int TagLength = 16;
    public const int MaximumPlaintextSize = Ech0Protocol.MaximumPayloadSize + 5;

    private static readonly byte[] AadPrefix = "Ech0-v3-record"u8.ToArray();
    private readonly AesGcm sendCipher;
    private readonly AesGcm receiveCipher;
    private readonly byte[] sendNoncePrefix;
    private readonly byte[] receiveNoncePrefix;
    private readonly byte sendDirection;
    private readonly byte receiveDirection;
    private ulong sendSequence;
    private ulong receiveSequence;

    public SecureRecordSession(bool isClient, SecureSessionKeyMaterial keyMaterial)
    {
        var sendKey = isClient ? keyMaterial.ClientWriteKey : keyMaterial.ServerWriteKey;
        var receiveKey = isClient ? keyMaterial.ServerWriteKey : keyMaterial.ClientWriteKey;
        sendCipher = new AesGcm(sendKey, TagLength);
        receiveCipher = new AesGcm(receiveKey, TagLength);
        sendNoncePrefix = isClient ? keyMaterial.ClientNoncePrefix : keyMaterial.ServerNoncePrefix;
        receiveNoncePrefix = isClient ? keyMaterial.ServerNoncePrefix : keyMaterial.ClientNoncePrefix;
        sendDirection = isClient ? (byte)1 : (byte)2;
        receiveDirection = isClient ? (byte)2 : (byte)1;
    }

    public byte[] Seal(ReadOnlySpan<byte> plaintext)
    {
        if (plaintext.Length > MaximumPlaintextSize)
        {
            throw new InvalidDataException("Encrypted record is too large.");
        }
        if (sendSequence == ulong.MaxValue)
        {
            throw new CryptographicException("Encrypted record sequence is exhausted.");
        }

        var record = new byte[HeaderLength + plaintext.Length + TagLength];
        var header = record.AsSpan(0, HeaderLength);
        WriteHeader(header, sendDirection, sendSequence, plaintext.Length);
        Span<byte> nonce = stackalloc byte[12];
        WriteNonce(nonce, sendNoncePrefix, sendSequence);
        var aad = BuildAad(header);
        sendCipher.Encrypt(
            nonce,
            plaintext,
            record.AsSpan(HeaderLength, plaintext.Length),
            record.AsSpan(HeaderLength + plaintext.Length, TagLength),
            aad);
        sendSequence++;
        return record;
    }

    public int BodyLength(ReadOnlySpan<byte> header)
        => ValidateHeader(header) + TagLength;

    public byte[] Open(ReadOnlySpan<byte> record)
    {
        if (record.Length < HeaderLength + TagLength)
        {
            throw new InvalidDataException("Encrypted record is truncated.");
        }
        var header = record[..HeaderLength];
        var plaintextLength = ValidateHeader(header);
        if (record.Length != HeaderLength + plaintextLength + TagLength)
        {
            throw new InvalidDataException("Encrypted record length is invalid.");
        }

        Span<byte> nonce = stackalloc byte[12];
        WriteNonce(nonce, receiveNoncePrefix, receiveSequence);
        var plaintext = new byte[plaintextLength];
        var aad = BuildAad(header);
        receiveCipher.Decrypt(
            nonce,
            record.Slice(HeaderLength, plaintextLength),
            record.Slice(HeaderLength + plaintextLength, TagLength),
            plaintext,
            aad);
        receiveSequence++;
        return plaintext;
    }

    private int ValidateHeader(ReadOnlySpan<byte> header)
    {
        if (receiveSequence == ulong.MaxValue
            || header.Length != HeaderLength
            || header[0] != 0x45
            || header[1] != 0x33
            || header[2] != 0x01
            || header[3] != receiveDirection
            || BinaryPrimitives.ReadUInt64BigEndian(header[4..12]) != receiveSequence)
        {
            throw new InvalidDataException("Encrypted record header is invalid.");
        }
        var length = checked((int)BinaryPrimitives.ReadUInt32BigEndian(header[12..16]));
        if (length > MaximumPlaintextSize)
        {
            throw new InvalidDataException("Encrypted record is too large.");
        }
        return length;
    }

    private static void WriteHeader(Span<byte> header, byte direction, ulong sequence, int length)
    {
        header[0] = 0x45;
        header[1] = 0x33;
        header[2] = 0x01;
        header[3] = direction;
        BinaryPrimitives.WriteUInt64BigEndian(header[4..12], sequence);
        BinaryPrimitives.WriteUInt32BigEndian(header[12..16], checked((uint)length));
    }

    private static void WriteNonce(Span<byte> nonce, ReadOnlySpan<byte> prefix, ulong sequence)
    {
        if (prefix.Length != 4)
        {
            throw new CryptographicException("Encrypted record nonce prefix is invalid.");
        }
        prefix.CopyTo(nonce);
        BinaryPrimitives.WriteUInt64BigEndian(nonce[4..], sequence);
    }

    private static byte[] BuildAad(ReadOnlySpan<byte> header)
    {
        var aad = new byte[AadPrefix.Length + HeaderLength];
        AadPrefix.CopyTo(aad, 0);
        header.CopyTo(aad.AsSpan(AadPrefix.Length));
        return aad;
    }

    public void Dispose()
    {
        sendCipher.Dispose();
        receiveCipher.Dispose();
    }
}

internal sealed class SecureRecordStream(Stream inner, SecureRecordSession session) : Stream
{
    private byte[] bufferedPlaintext = [];
    private int bufferedOffset;
    private bool disposed;

    public override bool CanRead => !disposed && inner.CanRead;
    public override bool CanSeek => false;
    public override bool CanWrite => !disposed && inner.CanWrite;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override async ValueTask<int> ReadAsync(
        Memory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (buffer.IsEmpty)
        {
            return 0;
        }
        if (bufferedOffset == bufferedPlaintext.Length)
        {
            var header = new byte[SecureRecordSession.HeaderLength];
            await ReadExactlyAsync(inner, header, cancellationToken);
            var body = new byte[session.BodyLength(header)];
            await ReadExactlyAsync(inner, body, cancellationToken);
            var record = new byte[header.Length + body.Length];
            header.CopyTo(record, 0);
            body.CopyTo(record, header.Length);
            bufferedPlaintext = session.Open(record);
            bufferedOffset = 0;
        }

        var copyLength = Math.Min(buffer.Length, bufferedPlaintext.Length - bufferedOffset);
        bufferedPlaintext.AsMemory(bufferedOffset, copyLength).CopyTo(buffer);
        bufferedOffset += copyLength;
        return copyLength;
    }

    public override async ValueTask WriteAsync(
        ReadOnlyMemory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var record = session.Seal(buffer.Span);
        await inner.WriteAsync(record, cancellationToken);
    }

    public override Task FlushAsync(CancellationToken cancellationToken)
        => inner.FlushAsync(cancellationToken);

    public override void Flush() => inner.Flush();
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing && !disposed)
        {
            disposed = true;
            session.Dispose();
            inner.Dispose();
        }
        base.Dispose(disposing);
    }

    public override async ValueTask DisposeAsync()
    {
        if (!disposed)
        {
            disposed = true;
            session.Dispose();
            await inner.DisposeAsync();
        }
        GC.SuppressFinalize(this);
    }

    private static async Task ReadExactlyAsync(
        Stream source,
        Memory<byte> destination,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var read = await source.ReadAsync(destination[offset..], cancellationToken);
            if (read == 0)
            {
                throw new EndOfStreamException("Secure Ech0 connection closed.");
            }
            offset += read;
        }
    }
}

internal static class SecureHandshake
{
    public const int ProtocolVersion = 3;
    public const string Capability = "secureTransportV3";

    public static byte[] BuildTranscript(
        KeyExchangeClientHello clientHello,
        ReadOnlySpan<byte> serverSigningPublicKey,
        ReadOnlySpan<byte> serverEphemeralPublicKey,
        ReadOnlySpan<byte> serverNonce,
        string receiverId)
    {
        var authMode = clientHello.AuthMode switch
        {
            "pairing" => (byte)1,
            "trusted" => (byte)2,
            _ => throw new InvalidDataException("Unknown secure authentication mode."),
        };
        var clientPublicKey = Convert.FromBase64String(clientHello.ClientEphemeralPublicKey);
        var clientNonce = Convert.FromBase64String(clientHello.ClientNonce);
        if (clientHello.ProtocolVersion != ProtocolVersion
            || clientPublicKey.Length != 65
            || clientNonce.Length != 32
            || serverSigningPublicKey.Length != 65
            || serverEphemeralPublicKey.Length != 65
            || serverNonce.Length != 32)
        {
            throw new InvalidDataException("Secure handshake fields are invalid.");
        }

        using var transcript = new MemoryStream();
        transcript.Write("Ech0-v3-handshake"u8);
        Span<byte> protocol = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(protocol, checked((ushort)ProtocolVersion));
        transcript.Write(protocol);
        transcript.WriteByte(authMode);
        WriteLengthPrefixed(transcript, clientHello.ExpectedReceiverId ?? "");
        WriteLengthPrefixed(transcript, clientHello.ExpectedReceiverKeyHash ?? "");
        transcript.Write(clientNonce);
        transcript.Write(clientPublicKey);
        transcript.Write(serverNonce);
        transcript.Write(serverEphemeralPublicKey);
        transcript.Write(serverSigningPublicKey);
        WriteLengthPrefixed(transcript, receiverId);
        return transcript.ToArray();
    }

    public static byte[] PairingProof(string pairingCode, ReadOnlySpan<byte> transcript)
    {
        var normalized = PairingCode.Normalize(pairingCode)
            ?? throw new InvalidDataException("Pairing code is invalid.");
        return HMACSHA256.HashData(Encoding.UTF8.GetBytes(normalized), transcript);
    }

    public static string ReceiverKeyHash(ReadOnlySpan<byte> publicKey)
        => Convert.ToHexString(SHA256.HashData(publicKey)).ToLowerInvariant();

    public static bool TrustedReceiverMatches(
        string expectedReceiverId,
        string expectedReceiverKeyHash,
        string actualReceiverId,
        string actualReceiverKeyHash)
        => string.Equals(expectedReceiverId, actualReceiverId, StringComparison.Ordinal)
            && string.Equals(
                expectedReceiverKeyHash,
                actualReceiverKeyHash,
                StringComparison.Ordinal);

    public static byte[] ExportX963(ECParameters parameters)
    {
        if (parameters.Q.X is not { Length: 32 } x || parameters.Q.Y is not { Length: 32 } y)
        {
            throw new CryptographicException("P-256 public key is invalid.");
        }
        var output = new byte[65];
        output[0] = 0x04;
        x.CopyTo(output, 1);
        y.CopyTo(output, 33);
        return output;
    }

    public static ECParameters ImportX963(ReadOnlySpan<byte> publicKey)
    {
        if (publicKey.Length != 65 || publicKey[0] != 0x04)
        {
            throw new CryptographicException("P-256 public key is invalid.");
        }
        return new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint
            {
                X = publicKey[1..33].ToArray(),
                Y = publicKey[33..65].ToArray(),
            },
        };
    }

    private static void WriteLengthPrefixed(Stream destination, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length > ushort.MaxValue)
        {
            throw new InvalidDataException("Secure handshake string is too long.");
        }
        Span<byte> length = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(length, checked((ushort)bytes.Length));
        destination.Write(length);
        destination.Write(bytes);
    }
}

internal sealed record SecureTransportConnection(
    SecureRecordStream Stream,
    string ReceiverKeyHash);

internal static class SecureTransportClient
{
    public static async Task<SecureTransportConnection> NegotiateAsync(
        Stream rawStream,
        Ech0Settings settings,
        CancellationToken cancellationToken)
    {
        var pairingCode = PairingCode.Normalize(settings.PairingToken);
        var authMode = pairingCode is not null ? "pairing" : "trusted";
        if (authMode == "trusted"
            && (string.IsNullOrWhiteSpace(settings.ReceiverId)
                || string.IsNullOrWhiteSpace(settings.ReceiverKeyHash)))
        {
            throw new PairingRequiredException("receiverPinMissing");
        }

        using var clientAgreement = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var clientPublicKey = SecureHandshake.ExportX963(clientAgreement.ExportParameters(false));
        var clientNonce = RandomNumberGenerator.GetBytes(32);
        var clientHello = new KeyExchangeClientHello(
            "keyExchangeClientHello",
            SecureHandshake.ProtocolVersion,
            authMode,
            Convert.ToBase64String(clientPublicKey),
            Convert.ToBase64String(clientNonce),
            authMode == "trusted" ? settings.ReceiverId : null,
            authMode == "trusted" ? settings.ReceiverKeyHash : null);
        var packet = Ech0Protocol.EncodeControl(clientHello);
        await rawStream.WriteAsync(packet, cancellationToken);
        await rawStream.FlushAsync(cancellationToken);

        var responsePacket = await Ech0Protocol.ReadPacketAsync(rawStream, cancellationToken);
        if (responsePacket.Type != Ech0Protocol.ControlType
            || Ech0Protocol.ReadKind(responsePacket.Payload) != "keyExchangeServerHello")
        {
            throw new InvalidDataException("Expected keyExchangeServerHello.");
        }
        var response = Ech0Protocol.DecodeControl<KeyExchangeServerHello>(responsePacket.Payload);
        if (!response.Accepted)
        {
            if (response.Reason == "rateLimited")
            {
                throw new InvalidOperationException("Pairing attempts are temporarily rate-limited.");
            }
            throw new PairingRequiredException(response.Reason ?? "secureHandshakeRejected");
        }
        if (string.IsNullOrWhiteSpace(response.ReceiverId)
            || string.IsNullOrWhiteSpace(response.ServerSigningPublicKey)
            || string.IsNullOrWhiteSpace(response.ServerEphemeralPublicKey)
            || string.IsNullOrWhiteSpace(response.ServerNonce)
            || string.IsNullOrWhiteSpace(response.Signature))
        {
            throw new InvalidDataException("Secure server handshake is incomplete.");
        }

        var signingPublicKey = Convert.FromBase64String(response.ServerSigningPublicKey);
        var serverEphemeralPublicKey = Convert.FromBase64String(response.ServerEphemeralPublicKey);
        var serverNonce = Convert.FromBase64String(response.ServerNonce);
        var signature = Convert.FromBase64String(response.Signature);
        var receiverKeyHash = SecureHandshake.ReceiverKeyHash(signingPublicKey);
        var transcript = SecureHandshake.BuildTranscript(
            clientHello,
            signingPublicKey,
            serverEphemeralPublicKey,
            serverNonce,
            response.ReceiverId);

        using var signingVerifier = ECDsa.Create();
        signingVerifier.ImportParameters(SecureHandshake.ImportX963(signingPublicKey));
        if (!signingVerifier.VerifyData(
                transcript,
                signature,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.IeeeP1363FixedFieldConcatenation))
        {
            throw new CryptographicException("Mac identity signature is invalid.");
        }

        if (authMode == "trusted")
        {
            if (!SecureHandshake.TrustedReceiverMatches(
                    settings.ReceiverId,
                    settings.ReceiverKeyHash,
                    response.ReceiverId,
                    receiverKeyHash))
            {
                throw new PairingRequiredException("receiverIdentityMismatch");
            }
        }
        else
        {
            if (string.IsNullOrWhiteSpace(response.PairingProof)
                || !CryptographicOperations.FixedTimeEquals(
                    Convert.FromBase64String(response.PairingProof),
                    SecureHandshake.PairingProof(pairingCode!, transcript)))
            {
                throw new PairingRequiredException("pairingProofInvalid");
            }
        }

        using var serverAgreement = ECDiffieHellman.Create();
        serverAgreement.ImportParameters(SecureHandshake.ImportX963(serverEphemeralPublicKey));
        var sharedSecret = clientAgreement.DeriveRawSecretAgreement(serverAgreement.PublicKey);
        var keys = SecureSessionKeyMaterial.Derive(
            sharedSecret,
            transcript,
            clientNonce,
            serverNonce);
        CryptographicOperations.ZeroMemory(sharedSecret);
        return new SecureTransportConnection(
            new SecureRecordStream(rawStream, new SecureRecordSession(true, keys)),
            receiverKeyHash);
    }
}
