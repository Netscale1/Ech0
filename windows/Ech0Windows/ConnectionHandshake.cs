using System.Net.Sockets;

namespace Ech0.Windows;

internal sealed class PairingRequiredException(string reason) : Exception(reason);
internal sealed record AuthenticatedConnection(SecureRecordStream Stream, ServerHello Hello);

internal static class ConnectionHandshake
{
    public static async Task<AuthenticatedConnection> ConnectAndAuthenticateAsync(
        Stream rawStream,
        Ech0Settings settings,
        CancellationToken cancellationToken)
    {
        var transport = await SecureTransportClient.NegotiateAsync(
            rawStream,
            settings,
            cancellationToken);
        try
        {
            var helloPacket = Ech0Protocol.EncodeControl(
                new ClientHello(
                    "clientHello",
                    SecureHandshake.ProtocolVersion,
                    PairingCode.Normalize(settings.PairingToken) ?? "",
                    settings.DeviceName,
                    settings.SenderId,
                    settings.TrustedSecret,
                    ["remoteCaptureControl", SecureHandshake.Capability],
                    48_000,
                    1,
                    20));
            await transport.Stream.WriteAsync(helloPacket, cancellationToken);
            await transport.Stream.FlushAsync(cancellationToken);

            var responsePacket = await Ech0Protocol.ReadPacketAsync(
                transport.Stream,
                cancellationToken);
            if (responsePacket.Type != Ech0Protocol.ControlType
                || Ech0Protocol.ReadKind(responsePacket.Payload) != "serverHello")
            {
                throw new InvalidDataException("Expected serverHello.");
            }

            var hello = Ech0Protocol.DecodeControl<ServerHello>(responsePacket.Payload);
            if (!hello.Accepted)
            {
                if (hello.Reason is "pairingRequired" or "trustRevoked")
                {
                    throw new PairingRequiredException(hello.Reason);
                }
                throw new InvalidOperationException(hello.Reason ?? "Pairing rejected.");
            }
            if (hello.NegotiatedProtocolVersion != SecureHandshake.ProtocolVersion
                || hello.Capabilities?.Contains("remoteCaptureControl") != true
                || hello.Capabilities.Contains(SecureHandshake.Capability) != true
                || !string.Equals(
                    hello.ReceiverKeyHash,
                    transport.ReceiverKeyHash,
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Mac receiver did not complete secure transport negotiation.");
            }
            return new AuthenticatedConnection(transport.Stream, hello);
        }
        catch
        {
            await transport.Stream.DisposeAsync();
            throw;
        }
    }
}

internal static class PairingProbe
{
    public static async Task<ServerHello> PairAsync(Ech0Settings candidate, CancellationToken cancellationToken)
    {
        using var client = new TcpClient { NoDelay = true };
        await client.ConnectAsync(candidate.Host, candidate.Port, cancellationToken);
        var authenticated = await ConnectionHandshake.ConnectAndAuthenticateAsync(
            client.GetStream(),
            candidate,
            cancellationToken);
        await using var stream = authenticated.Stream;
        var hello = authenticated.Hello;
        if (hello.TrustEstablished != true || string.IsNullOrWhiteSpace(hello.ReceiverId))
        {
            throw new InvalidOperationException("The Mac did not confirm the trusted relationship.");
        }

        var stop = Ech0Protocol.EncodeControl(new StopMessage("stop", "pairingComplete"));
        await stream.WriteAsync(stop, cancellationToken);
        await stream.FlushAsync(cancellationToken);
        return hello;
    }
}
