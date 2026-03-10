# Ech0 Protocol v1

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
  "targetBufferMs": 60
}
```

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
  "reason": "invalidToken"
}
```

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
- If the token is invalid, the server replies with `serverHello.accepted = false` and closes the session.
- The sender may send `ping` once per second and compute round-trip time from the echoed `pong`.
- A `stop` packet is terminal and should be followed by closing the TCP connection.

