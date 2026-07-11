# Ech0 Protocol v1 and v2

The transport uses a single TCP connection on the local network.

## Packet Framing

Every packet is:

- `1 byte`: message type
- `4 bytes`: unsigned big-endian payload length
- `N bytes`: payload

Message types:

- `0x01`: UTF-8 JSON control message
- `0x02`: audio frame

## Control Messages

Control messages are JSON objects with a required `kind` field.

### `clientHello`

```json
{
  "kind": "clientHello",
  "protocolVersion": 1,
  "token": "123456",
  "deviceName": "Pixel 8",
  "sampleRate": 48000,
  "channels": 1,
  "frameMs": 20
}
```

### `serverHello`

```json
{
  "kind": "serverHello",
  "accepted": true,
  "reason": null,
  "targetBufferMs": 60,
  "negotiatedProtocolVersion": 2,
  "capabilities": ["remoteCaptureControl"],
  "receiverId": "a0ab3c21-16a5-41be-95c5-95f242f6a5cc",
  "receiverName": "Mac mini",
  "authentication": "trusted",
  "trustEstablished": true
}
```

Version 1 remains sender-driven for Android. A version 2 sender includes `senderId`, `trustedSecret`, and `capabilities: ["remoteCaptureControl"]` in `clientHello`. The server sends the v2 messages below only after negotiating that capability.

The six-digit token is a bootstrap credential for a new device, not persistent shared state. On first pairing the Mac stores only a hash of `trustedSecret` and replies with `authentication: "pairing"` and `trustEstablished: true`. Later connections may omit the token and authenticate with the trusted sender identity. `receiverId` is stable across Mac app restarts; all added `serverHello` fields are optional for compatibility with older implementations.

### `captureDemand`

```json
{
  "kind": "captureDemand",
  "active": true,
  "generation": 4
}
```

The Mac sends the current demand immediately after handshake. Generations are monotonic within a receiver run; clients ignore older generations.

### `captureStatus`

```json
{
  "kind": "captureStatus",
  "generation": 4,
  "state": "capturing",
  "errorCode": null
}
```

Valid states are `idle`, `starting`, `capturing`, `paused`, and `error`.

### `ping`

```json
{
  "kind": "ping",
  "monotonicMs": 123456789
}
```

### `pong`

```json
{
  "kind": "pong",
  "monotonicMs": 123456789
}
```

### `stop`

```json
{
  "kind": "stop",
  "reason": "trustRevoked"
}
```

For v2, `pairingRequired` means that neither the trusted identity nor the current bootstrap code was accepted. `trustRevoked` immediately terminates an active trusted session. Version 1 retains the legacy `invalidToken` rejection.

## Audio Frame Payload

Audio frame payload layout:

- `8 bytes`: unsigned big-endian `sequence`
- `8 bytes`: unsigned big-endian `captureTimestampMs`
- `4 bytes`: unsigned big-endian `flags`
- `N bytes`: PCM16 little-endian mono samples

Flags:

- bit `0`: muted frame

For the v1 MVP, the audio format is fixed:

- sample rate: `48000`
- channels: `1`
- sample format: `PCM16LE`
- frame size: `20 ms` (`960` mono samples, `1920` bytes)
- audio payload size: exactly `1940` bytes including the 20-byte audio header

## Pairing QR Payload

The QR code and manual pairing data use the same JSON payload:

```json
{
  "v": 1,
  "host": "192.168.1.10",
  "port": 48484,
  "token": "123456"
}
```

## Session Rules

- The server accepts a single active sender.
- The sender must send `clientHello` before any audio frames.
- A v2 trusted sender reconnects with `senderId` and `trustedSecret`; the pairing token may be empty.
- If neither trust nor the token is valid, the server replies with `serverHello.accepted = false` and closes the session.
- Revoking the active sender sends `stop(reason: "trustRevoked")` before closing the connection.
- An active sender sends `ping` once per second and may compute round-trip time from the echoed `pong`.
- The receiver releases a connection that does not complete its handshake or send a heartbeat for more than 5 seconds, allowing a reconnect without restarting Ech0Mac.
- A `stop` packet is terminal and should be followed by closing the TCP connection.
- Control payloads are limited to 16 KiB and all payloads to 64 KiB.
- The protocol is not encrypted and must only be used on a trusted local network.
