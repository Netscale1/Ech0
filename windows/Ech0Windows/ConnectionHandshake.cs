using System.Net.Sockets;

namespace Ech0.Windows;

internal sealed class PairingRequiredException(string reason) : Exception(reason);

internal static class ConnectionHandshake
{
    public static async Task<ServerHello> ConnectAndAuthenticateAsync(
        NetworkStream stream,
        Ech0Settings settings,
        CancellationToken cancellationToken)
    {
        var helloPacket = Ech0Protocol.EncodeControl(
            new ClientHello(
                "clientHello",
                2,
                settings.PairingToken,
                settings.DeviceName,
                settings.SenderId,
                settings.TrustedSecret,
                ["remoteCaptureControl"],
                48_000,
                1,
                20));
        await stream.WriteAsync(helloPacket, cancellationToken);
        await stream.FlushAsync(cancellationToken);

        var responsePacket = await Ech0Protocol.ReadPacketAsync(stream, cancellationToken);
        if (responsePacket.Type != Ech0Protocol.ControlType
            || Ech0Protocol.ReadKind(responsePacket.Payload) != "serverHello")
        {
            throw new InvalidDataException("Expected serverHello.");
        }

        var hello = Ech0Protocol.DecodeControl<ServerHello>(responsePacket.Payload);
        if (!hello.Accepted)
        {
            if (hello.Reason is "pairingRequired" or "trustRevoked" or "invalidToken")
            {
                throw new PairingRequiredException(hello.Reason);
            }
            throw new InvalidOperationException(hello.Reason ?? "Pairing rejected.");
        }
        if (hello.NegotiatedProtocolVersion != 2
            || hello.Capabilities?.Contains("remoteCaptureControl") != true)
        {
            throw new InvalidOperationException("Mac receiver does not support remote capture control.");
        }
        return hello;
    }
}

internal static class PairingProbe
{
    public static async Task<ServerHello> PairAsync(Ech0Settings candidate, CancellationToken cancellationToken)
    {
        using var client = new TcpClient { NoDelay = true };
        await client.ConnectAsync(candidate.Host, candidate.Port, cancellationToken);
        await using var stream = client.GetStream();
        var hello = await ConnectionHandshake.ConnectAndAuthenticateAsync(stream, candidate, cancellationToken);
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
