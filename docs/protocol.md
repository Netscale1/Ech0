# Ech0 Secure Protocol v3

The Windows sender and macOS receiver use one TCP connection. Version 3 is the only supported protocol version; version 2 and plaintext `clientHello`, control, credential, and audio traffic are rejected.

## Security contract

Version 3 protects against a network peer that can observe, alter, replay, inject, or redirect LAN traffic:

- the first pairing authenticates the Mac with a 128-bit random Base32 pairing code;
- later reconnects require the receiver ID and SHA-256 pin of the Mac signing key saved during pairing;
- the Mac authenticates Windows with the high-entropy trusted secret already associated with `senderId`;
- credentials, device names, control messages, and audio are sent only in AES-256-GCM records;
- signed ephemeral P-256 ECDH provides a new session key and forward secrecy for every connection;
- direction and sequence are authenticated, so reflection, reordering, and replay are rejected;
- pairing handshakes are limited to five attempts per peer and twenty globally per 60-second window.

The Mac persists its P-256 signing private key beside `receiverId` with owner-only file permissions. Windows stores the receiver key hash and its own trusted secret in the existing DPAPI-protected settings. A user-level compromise of either endpoint, traffic-volume analysis, and sustained connection-slot denial of service are outside this transport boundary. Do not expose port `48484/TCP` directly to the Internet.

## Plain packet framing

The initial key exchange uses the existing packet envelope:

- `1 byte`: message type;
- `4 bytes`: unsigned big-endian payload length;
- `N bytes`: payload.

Message types inside the encrypted channel remain:

- `0x01`: UTF-8 JSON control message;
- `0x02`: audio frame.

Only one plaintext application packet is permitted: `keyExchangeClientHello`. The Mac replies with one plaintext `keyExchangeServerHello`. Every byte after that exchange must be an encrypted record.

Control payloads are limited to 16 KiB and all packet payloads to 64 KiB.

## Key exchange

### `keyExchangeClientHello`

```json
{
  "kind": "keyExchangeClientHello",
  "protocolVersion": 3,
  "authMode": "pairing",
  "clientEphemeralPublicKey": "base64-x963-p256-public-key",
  "clientNonce": "base64-32-random-bytes",
  "expectedReceiverId": null,
  "expectedReceiverKeyHash": null
}
```

For a trusted reconnect, `authMode` is `trusted` and both expected receiver fields are mandatory. No pairing code, trusted secret, sender ID, or device name is exposed in this plaintext message.

### `keyExchangeServerHello`

```json
{
  "kind": "keyExchangeServerHello",
  "accepted": true,
  "reason": null,
  "receiverId": "a0ab3c21-16a5-41be-95c5-95f242f6a5cc",
  "serverSigningPublicKey": "base64-x963-p256-public-key",
  "serverEphemeralPublicKey": "base64-x963-p256-public-key",
  "serverNonce": "base64-32-random-bytes",
  "signature": "base64-p1363-ecdsa-signature",
  "pairingProof": "base64-hmac-sha256"
}
```

The signed binary transcript binds:

1. the literal `Ech0-v3-handshake`;
2. protocol version and authentication mode;
3. expected receiver ID and key hash;
4. both nonces;
5. both ephemeral/signing public keys;
6. the actual receiver ID.

The Mac signs the transcript with persistent ECDSA P-256/SHA-256. During first pairing, it additionally returns `HMAC-SHA256(normalizedPairingCode, transcript)`. The 26-character normalized Base32 code carries 128 bits of randomness; hyphens, case, and surrounding whitespace are presentation-only. During trusted reconnect, Windows instead requires the saved receiver ID and signing-key hash to match exactly.

Both peers derive the raw ephemeral P-256 ECDH secret, then derive 72 bytes with RFC 5869 HKDF-SHA256:

- salt: `SHA256(clientNonce || serverNonce)`;
- info: `"Ech0-v3-session" || SHA256(transcript)`;
- bytes `0..<32`: client write key;
- bytes `32..<64`: server write key;
- bytes `64..<68`: client nonce prefix;
- bytes `68..<72`: server nonce prefix.

The static signing key authenticates the ephemeral exchange but is not used in ECDH, so later disclosure of that key does not decrypt previously captured sessions.

## Encrypted record layer

Each record is:

- bytes `0..<2`: ASCII magic `E3`;
- byte `2`: record version `1`;
- byte `3`: direction (`1` client-to-server, `2` server-to-client);
- bytes `4..<12`: unsigned big-endian sequence number;
- bytes `12..<16`: unsigned big-endian ciphertext length;
- ciphertext;
- 16-byte AES-GCM authentication tag.

The 12-byte AES-GCM nonce is the four-byte direction-specific HKDF prefix followed by the eight-byte sequence. Additional authenticated data is `"Ech0-v3-record" || recordHeader`. Each direction starts at sequence zero and accepts exactly the next value. A sequence or tag failure terminates the connection; failed authentication never advances the receive sequence.

The record plaintext is one complete packet envelope. Its maximum size is 65,541 bytes.

## Encrypted authentication

The first encrypted control is `clientHello`:

```json
{
  "kind": "clientHello",
  "protocolVersion": 3,
  "token": "normalized-pairing-code-or-empty",
  "deviceName": "Windows PC",
  "senderId": "3ef5d92f-335f-4bb2-a735-51e5232cfc31",
  "trustedSecret": "base64-encoded-random-secret",
  "capabilities": ["remoteCaptureControl", "secureTransportV3"],
  "sampleRate": 48000,
  "channels": 1,
  "frameMs": 20
}
```

Authentication modes cannot be mixed:

- `pairing` accepts only the current pairing code and persists the sender before acknowledging trust;
- `trusted` requires an empty token and a matching sender ID/secret;
- a token cannot downgrade or rescue a failed trusted reconnect;
- a stored trusted identity cannot bypass a failed pairing attempt.

The encrypted `serverHello` confirms the negotiated version, capabilities, receiver identity, and pin:

```json
{
  "kind": "serverHello",
  "accepted": true,
  "reason": null,
  "targetBufferMs": 60,
  "negotiatedProtocolVersion": 3,
  "capabilities": ["remoteCaptureControl", "secureTransportV3"],
  "receiverId": "a0ab3c21-16a5-41be-95c5-95f242f6a5cc",
  "receiverName": "Mac mini",
  "receiverKeyHash": "lowercase-sha256-hex",
  "authentication": "trusted",
  "trustEstablished": true
}
```

Windows commits the receiver ID and key hash only after this encrypted confirmation. Existing v2 associations have no pin and intentionally require one new pairing.

## Runtime control messages

After authentication, the v2 runtime semantics remain unchanged:

- `captureDemand { active, generation }` is sent by the Mac immediately after authentication;
- `captureStatus { generation, state, errorCode }` reports `idle`, `starting`, `capturing`, `paused`, or `error`;
- `ping { monotonicMs }` is sent once per second and echoed as `pong`;
- `stop { reason }` is terminal and is processed before the connection closes.

Audio is accepted only while the current capture demand is active. Revoking the trusted sender sends `stop(reason: "trustRevoked")` in the encrypted channel.

## Audio frame payload

The encrypted audio packet payload is fixed:

- `8 bytes`: unsigned big-endian sequence;
- `8 bytes`: unsigned big-endian capture timestamp in milliseconds;
- `4 bytes`: unsigned big-endian flags;
- `1,920 bytes`: PCM16 little-endian mono samples.

The format is 48 kHz, mono, PCM16LE, 20 ms / 960 samples per frame. Bit zero of `flags` denotes a muted frame.

## Session rules

- The receiver permits one active sender.
- Key exchange and encrypted `clientHello` must finish before audio or runtime controls.
- A connection that does not authenticate or send heartbeats within five seconds is released.
- Rejections after key exchange are encrypted; a key-exchange rejection contains no receiver key material.
- The sender validates the ECDSA signature before accepting the exchange and validates the HMAC or existing pin before transmitting any credential.
- The Mac stores only a SHA-256 hash of each Windows trusted secret.
