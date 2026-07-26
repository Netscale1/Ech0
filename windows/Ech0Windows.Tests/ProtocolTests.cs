using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using Xunit;

namespace Ech0.Windows.Tests;

public sealed class ProtocolTests
{
    [Fact]
    public void LoggingIoFailureDoesNotEscapeIntoRuntime()
    {
        Assert.False(Log.TryWrite(() => throw new IOException("disk unavailable")));
    }

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
        var json = """{"kind":"serverHello","accepted":true,"reason":null,"targetBufferMs":60,"negotiatedProtocolVersion":3,"capabilities":["remoteCaptureControl","secureTransportV3"],"receiverId":"receiver-1","receiverName":"Mac mini","receiverKeyHash":"key-hash","authentication":"trusted","trustEstablished":true}"""u8;

        var hello = Ech0Protocol.DecodeControl<ServerHello>(json);

        Assert.Equal("receiver-1", hello.ReceiverId);
        Assert.Equal("key-hash", hello.ReceiverKeyHash);
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
            "serverHello", true, null, 60, 3, ["remoteCaptureControl", "secureTransportV3"],
            "receiver-1", "Mac mini", "key-hash", "trusted", true);

        Assert.True(settings.TryCompleteTrust(hello));
        Assert.Equal(PairingState.Trusted, settings.PairingState);
        Assert.Equal("Mac mini", settings.ReceiverName);
        Assert.Equal("key-hash", settings.ReceiverKeyHash);
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
            null, null, null, null, null);

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
            ReceiverKeyHash = "key-hash",
            TrustConfirmed = true,
        };

        settings.MarkPairingRequired();

        Assert.Equal(PairingState.Unpaired, settings.PairingState);
        Assert.Equal("receiver-1", settings.ReceiverId);
        Assert.Equal("Mac mini", settings.ReceiverName);
    }

    [Fact]
    public void LegacyTrustedSettingsWithoutReceiverPinRequireNewPairing()
    {
        var settings = new Ech0Settings
        {
            Host = "mac.local",
            ReceiverId = "receiver-1",
            TrustConfirmed = true,
        };

        Assert.Equal(PairingState.Unpaired, settings.PairingState);
        Assert.False(settings.IsConfigured);
    }

    [Fact]
    public void PairingCodeRequiresHighEntropyBase32Value()
    {
        Assert.Equal(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            PairingCode.Normalize("abcd-efgh-ijkl-mnop-qrst-uvwx-yz"));
        Assert.Null(PairingCode.Normalize("123456"));
        Assert.Null(PairingCode.Normalize("ABCD-EFGH-IJKL-MNOP-QRST-UVWX-Y0"));
    }

    [Fact]
    public void SecureRecordsRoundTripAndRejectReplayTamperingAndWrongDirection()
    {
        var keys = new SecureSessionKeyMaterial(
            Enumerable.Repeat((byte)0x11, 32).ToArray(),
            Enumerable.Repeat((byte)0x22, 32).ToArray(),
            [0x01, 0x02, 0x03, 0x04],
            [0x05, 0x06, 0x07, 0x08]);
        using var client = new SecureRecordSession(true, keys);
        using var server = new SecureRecordSession(false, keys);
        var record = client.Seal("credential"u8);

        Assert.Equal("credential"u8.ToArray(), server.Open(record));
        Assert.ThrowsAny<Exception>(() => server.Open(record));

        using var tamperServer = new SecureRecordSession(false, keys);
        var tampered = (byte[])record.Clone();
        tampered[^1] ^= 0x01;
        Assert.ThrowsAny<CryptographicException>(() => tamperServer.Open(tampered));

        using var wrongDirection = new SecureRecordSession(true, keys);
        Assert.Throws<InvalidDataException>(() => wrongDirection.Open(record));
    }

    [Fact]
    public void SecureKeyScheduleAndRecordMatchCryptoKitVector()
    {
        var transcript = Convert.FromHexString(
            "456368302d76332d68616e647368616b65000301000000004444444444444444444444444444444444444444444444444444444444444444045ecbe4d1a6330a44c8f7ef951d4bf165e6c6b721efada985fb41661bc6e7fd6c8734640c4998ff7e374b06ce1a64a2ecd82ab036384fb83d9a79b127a27d50325555555555555555555555555555555555555555555555555555555555555555047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5000a72656365697665722d31");
        var sharedSecret = Convert.FromHexString(
            "b01a172a76a4602c92d3242cb897dde3024c740debb215b4c6b0aae93c2291a9");
        var keys = SecureSessionKeyMaterial.Derive(
            sharedSecret,
            transcript,
            Enumerable.Repeat((byte)0x44, 32).ToArray(),
            Enumerable.Repeat((byte)0x55, 32).ToArray());
        var combinedKeys = keys.ClientWriteKey
            .Concat(keys.ServerWriteKey)
            .Concat(keys.ClientNoncePrefix)
            .Concat(keys.ServerNoncePrefix)
            .ToArray();

        Assert.Equal(
            "C3BAEFAF513BF0CC928A70DD32FE7A6E10C31EAE5F896E00243D30D5CE05BF756B5FF986DD3F205486AA65B9FC5220B898CDBF59B129DCC2EC0874CA79464BACB032EFD9DBB7ECE6",
            Convert.ToHexString(combinedKeys));
        using var session = new SecureRecordSession(true, keys);
        Assert.Equal(
            "453301010000000000000000000000072A423F5809B2E445F62321EF065DDB24871F5767C3B6D5",
            Convert.ToHexString(session.Seal("interop"u8)));
    }

    [Fact]
    public void PlainKeyExchangeContainsNoCredentialOrDeviceIdentity()
    {
        var hello = new KeyExchangeClientHello(
            "keyExchangeClientHello",
            3,
            "pairing",
            Convert.ToBase64String(new byte[65]),
            Convert.ToBase64String(new byte[32]),
            null,
            null);
        var json = System.Text.Encoding.UTF8.GetString(Ech0Protocol.EncodeControl(hello));

        Assert.DoesNotContain("trustedSecret", json, StringComparison.Ordinal);
        Assert.DoesNotContain("pairingToken", json, StringComparison.Ordinal);
        Assert.DoesNotContain("deviceName", json, StringComparison.Ordinal);
        Assert.DoesNotContain("senderId", json, StringComparison.Ordinal);
    }

    [Fact]
    public void TrustedReconnectRejectsChangedReceiverIdOrKeyPin()
    {
        Assert.True(SecureHandshake.TrustedReceiverMatches(
            "receiver-1", "hash-1", "receiver-1", "hash-1"));
        Assert.False(SecureHandshake.TrustedReceiverMatches(
            "receiver-1", "hash-1", "receiver-2", "hash-1"));
        Assert.False(SecureHandshake.TrustedReceiverMatches(
            "receiver-1", "hash-1", "receiver-1", "hash-2"));
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

    [Fact]
    public void AccumulatorPreservesOrderingAcrossFragmentedAndBulkInput()
    {
        var accumulator = new PcmFrameAccumulator();
        var input = Enumerable.Range(0, Ech0Protocol.PcmBytesPerFrame * 3 + 17)
            .Select(index => (byte)(index % 251))
            .ToArray();

        var frames = new List<byte[]>();
        frames.AddRange(accumulator.Append(input.AsSpan(0, 333)));
        frames.AddRange(accumulator.Append(input.AsSpan(333, 1_777)));
        frames.AddRange(accumulator.Append(input.AsSpan(2_110)));

        Assert.Equal(3, frames.Count);
        Assert.Equal(
            input.AsSpan(0, Ech0Protocol.PcmBytesPerFrame * 3).ToArray(),
            frames.SelectMany(frame => frame).ToArray());
    }

    [Fact]
    public void AccumulatorClearDiscardsPartialFrame()
    {
        var accumulator = new PcmFrameAccumulator();
        Assert.Empty(accumulator.Append(new byte[123]));

        accumulator.Clear();
        var complete = Enumerable.Repeat((byte)7, Ech0Protocol.PcmBytesPerFrame).ToArray();
        var frames = accumulator.Append(complete);

        Assert.Single(frames);
        Assert.Equal(complete, frames[0]);
    }

    [Fact]
    public void CaptureFrameGateRejectsStaleSessionsAndGenerations()
    {
        Assert.True(CaptureFrameGate.ShouldSend(2, 4, 2, 4, true, false, true));
        Assert.False(CaptureFrameGate.ShouldSend(1, 4, 2, 4, true, false, true));
        Assert.False(CaptureFrameGate.ShouldSend(2, 3, 2, 4, true, false, true));
        Assert.False(CaptureFrameGate.ShouldSend(2, 4, 2, 4, false, false, true));
        Assert.False(CaptureFrameGate.ShouldSend(2, 4, 2, 4, true, true, true));
        Assert.False(CaptureFrameGate.ShouldSend(2, 4, 2, 4, true, false, false));
    }

    [Fact]
    public async Task ConnectionWorkerStartsWithProvidedPauseState()
    {
        await using var worker = new ConnectionWorker(new Ech0Settings(), initiallyPaused: true);

        Assert.True(worker.IsPaused);
    }

    [Fact]
    public async Task ConnectionTaskGroupJoinsSiblingCleanupBeforePropagatingFailure()
    {
        var primaryFailure = new InvalidOperationException("primary failure");
        var siblingCleanupCompleted = false;

        var observed = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            ConnectionTaskGroup.RunUntilFirstCompletionAsync(
                [
                    _ => Task.FromException(primaryFailure),
                    async cancellationToken =>
                    {
                        try
                        {
                            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                        }
                        finally
                        {
                            await Task.Yield();
                            siblingCleanupCompleted = true;
                        }
                    },
                ],
                CancellationToken.None));

        Assert.Same(primaryFailure, observed);
        Assert.True(siblingCleanupCompleted);
    }

    [Fact]
    public async Task AtomicSettingsWritesNeverExposePartialOrSharedTemporaryFiles()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"ech0-settings-{Guid.NewGuid():N}");
        var filePath = Path.Combine(directory, "settings.json");
        var payloads = Enumerable.Range(0, 24)
            .Select(index => $"{{\"value\":{index},\"padding\":\"{new string('x', 2_048)}\"}}")
            .ToArray();
        try
        {
            await Task.WhenAll(payloads.Select(payload => Task.Run(() =>
                AtomicSettingsFile.Write(filePath, () => payload))));

            Assert.Contains(File.ReadAllText(filePath), payloads);
            Assert.Empty(Directory.GetFiles(directory, "*.tmp"));
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [Fact]
    public void CaptureDemandGateRejectsPausedAndStaleCaptureTransitions()
    {
        Assert.True(CaptureDemandGate.ShouldStart(true, false, false));
        Assert.False(CaptureDemandGate.ShouldStart(true, true, false));
        Assert.False(CaptureDemandGate.ShouldStart(false, false, false));
        Assert.False(CaptureDemandGate.ShouldStart(true, false, true));

        Assert.True(CaptureDemandGate.ShouldReportUnexpectedStop(3, 7, 3, 7, true, false));
        Assert.False(CaptureDemandGate.ShouldReportUnexpectedStop(2, 7, 3, 7, true, false));
        Assert.False(CaptureDemandGate.ShouldReportUnexpectedStop(3, 6, 3, 7, true, false));
        Assert.False(CaptureDemandGate.ShouldReportUnexpectedStop(3, 7, 3, 7, false, false));
        Assert.False(CaptureDemandGate.ShouldReportUnexpectedStop(3, 7, 3, 7, true, true));
    }
}
