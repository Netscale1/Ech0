import CryptoKit
import Foundation

enum SecureTransportError: LocalizedError {
    case authenticationFailed
    case invalidHandshake
    case invalidRecord
    case recordTooLarge
    case sequenceExhausted

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "Secure transport authentication failed."
        case .invalidHandshake:
            return "The secure transport handshake is invalid."
        case .invalidRecord:
            return "The encrypted record is invalid."
        case .recordTooLarge:
            return "The encrypted record exceeds the allowed size."
        case .sequenceExhausted:
            return "The encrypted record sequence is exhausted."
        }
    }
}

struct SecureSessionKeyMaterial: Equatable {
    let clientWriteKey: Data
    let serverWriteKey: Data
    let clientNoncePrefix: Data
    let serverNoncePrefix: Data

    static func derive(
        sharedSecret: Data,
        transcript: Data,
        clientNonce: Data,
        serverNonce: Data
    ) -> Self {
        let salt = Data(SHA256.hash(data: clientNonce + serverNonce))
        let info = Data("Ech0-v3-session".utf8) + Data(SHA256.hash(data: transcript))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: info,
            outputByteCount: 72
        )
        let bytes = key.withUnsafeBytes { Data($0) }
        return Self(
            clientWriteKey: bytes.subdata(in: 0..<32),
            serverWriteKey: bytes.subdata(in: 32..<64),
            clientNoncePrefix: bytes.subdata(in: 64..<68),
            serverNoncePrefix: bytes.subdata(in: 68..<72)
        )
    }
}

// Instances are confined to the receiver's serial network queue.
final class SecureRecordSession: @unchecked Sendable {
    enum Role {
        case client
        case server
    }

    static let headerLength = 16
    static let tagLength = 16
    static let maximumPlaintextSize = PacketCodec.maximumPayloadSize + 5

    private static let aadPrefix = Data("Ech0-v3-record".utf8)
    private static let clientDirection: UInt8 = 1
    private static let serverDirection: UInt8 = 2

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendNoncePrefix: Data
    private let receiveNoncePrefix: Data
    private let sendDirection: UInt8
    private let receiveDirection: UInt8
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0

    init(role: Role, keyMaterial: SecureSessionKeyMaterial) {
        switch role {
        case .client:
            sendKey = SymmetricKey(data: keyMaterial.clientWriteKey)
            receiveKey = SymmetricKey(data: keyMaterial.serverWriteKey)
            sendNoncePrefix = keyMaterial.clientNoncePrefix
            receiveNoncePrefix = keyMaterial.serverNoncePrefix
            sendDirection = Self.clientDirection
            receiveDirection = Self.serverDirection
        case .server:
            sendKey = SymmetricKey(data: keyMaterial.serverWriteKey)
            receiveKey = SymmetricKey(data: keyMaterial.clientWriteKey)
            sendNoncePrefix = keyMaterial.serverNoncePrefix
            receiveNoncePrefix = keyMaterial.clientNoncePrefix
            sendDirection = Self.serverDirection
            receiveDirection = Self.clientDirection
        }
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= Self.maximumPlaintextSize else {
            throw SecureTransportError.recordTooLarge
        }
        guard sendSequence < UInt64.max else {
            throw SecureTransportError.sequenceExhausted
        }

        let header = makeHeader(
            direction: sendDirection,
            sequence: sendSequence,
            plaintextLength: plaintext.count
        )
        let nonce = try AES.GCM.Nonce(data: makeNonce(prefix: sendNoncePrefix, sequence: sendSequence))
        let sealed = try AES.GCM.seal(
            plaintext,
            using: sendKey,
            nonce: nonce,
            authenticating: Self.aadPrefix + header
        )
        sendSequence += 1
        return header + sealed.ciphertext + sealed.tag
    }

    func bodyLength(forHeader header: Data) throws -> Int {
        let plaintextLength = try validateHeader(header)
        return plaintextLength + Self.tagLength
    }

    func open(_ record: Data) throws -> Data {
        guard record.count >= Self.headerLength + Self.tagLength else {
            throw SecureTransportError.invalidRecord
        }
        let header = record.prefix(Self.headerLength)
        let plaintextLength = try validateHeader(Data(header))
        guard record.count == Self.headerLength + plaintextLength + Self.tagLength else {
            throw SecureTransportError.invalidRecord
        }

        let ciphertextStart = record.startIndex + Self.headerLength
        let tagStart = ciphertextStart + plaintextLength
        let ciphertext = record[ciphertextStart..<tagStart]
        let tag = record[tagStart..<record.endIndex]
        let nonce = try AES.GCM.Nonce(
            data: makeNonce(prefix: receiveNoncePrefix, sequence: receiveSequence)
        )
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try AES.GCM.open(
            box,
            using: receiveKey,
            authenticating: Self.aadPrefix + header
        )
        receiveSequence += 1
        return plaintext
    }

    private func validateHeader(_ header: Data) throws -> Int {
        guard receiveSequence < UInt64.max,
              header.count == Self.headerLength,
              header[0] == 0x45,
              header[1] == 0x33,
              header[2] == 0x01,
              header[3] == receiveDirection,
              header.readUInt64BE(at: 4) == receiveSequence else {
            throw SecureTransportError.invalidRecord
        }
        let length = Int(header.readUInt32BE(at: 12))
        guard length <= Self.maximumPlaintextSize else {
            throw SecureTransportError.recordTooLarge
        }
        return length
    }

    private func makeHeader(direction: UInt8, sequence: UInt64, plaintextLength: Int) -> Data {
        var header = Data([0x45, 0x33, 0x01, direction])
        header.appendUInt64BE(sequence)
        header.appendUInt32BE(UInt32(plaintextLength))
        return header
    }

    private func makeNonce(prefix: Data, sequence: UInt64) -> Data {
        var nonce = prefix
        nonce.appendUInt64BE(sequence)
        return nonce
    }
}

enum SecureHandshake {
    static let protocolVersion = 3
    static let capability = "secureTransportV3"

    enum AuthenticationMode: String {
        case pairing
        case trusted

        var wireValue: UInt8 {
            switch self {
            case .pairing: return 1
            case .trusted: return 2
            }
        }
    }

    static func transcript(
        clientHello: KeyExchangeClientHello,
        serverSigningPublicKey: Data,
        serverEphemeralPublicKey: Data,
        serverNonce: Data,
        receiverId: String
    ) throws -> Data {
        guard clientHello.protocolVersion == protocolVersion,
              let authMode = AuthenticationMode(rawValue: clientHello.authMode),
              let clientPublicKey = Data(base64Encoded: clientHello.clientEphemeralPublicKey),
              clientPublicKey.count == 65,
              let clientNonce = Data(base64Encoded: clientHello.clientNonce),
              clientNonce.count == 32,
              serverSigningPublicKey.count == 65,
              serverEphemeralPublicKey.count == 65,
              serverNonce.count == 32 else {
            throw SecureTransportError.invalidHandshake
        }

        var transcript = Data("Ech0-v3-handshake".utf8)
        transcript.appendUInt16BE(UInt16(protocolVersion))
        transcript.append(authMode.wireValue)
        try transcript.appendLengthPrefixed(clientHello.expectedReceiverId ?? "")
        try transcript.appendLengthPrefixed(clientHello.expectedReceiverKeyHash ?? "")
        transcript.append(clientNonce)
        transcript.append(clientPublicKey)
        transcript.append(serverNonce)
        transcript.append(serverEphemeralPublicKey)
        transcript.append(serverSigningPublicKey)
        try transcript.appendLengthPrefixed(receiverId)
        return transcript
    }

    static func pairingProof(pairingCode: String, transcript: Data) throws -> Data {
        guard let normalized = PairingCode.normalize(pairingCode) else {
            throw SecureTransportError.authenticationFailed
        }
        let key = SymmetricKey(data: Data(normalized.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
    }

    static func constantTimeEquals(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (leftByte, rightByte) in zip(left, right) {
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }

    static func receiverKeyHash(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }
}

struct SecureServerKeyExchangeResult {
    let response: KeyExchangeServerHello
    let session: SecureRecordSession
    let authenticationMode: SecureHandshake.AuthenticationMode
    let receiverKeyHash: String
}

enum SecureServerKeyExchange {
    static func accept(
        _ clientHello: KeyExchangeClientHello,
        receiverId: String,
        signingPrivateKeyData: Data,
        pairingCode: String,
        ephemeralPrivateKey: P256.KeyAgreement.PrivateKey? = nil,
        serverNonce suppliedServerNonce: Data? = nil
    ) throws -> SecureServerKeyExchangeResult {
        guard clientHello.protocolVersion == SecureHandshake.protocolVersion,
              let authenticationMode = SecureHandshake.AuthenticationMode(
                rawValue: clientHello.authMode
              ),
              let clientPublicKeyData = Data(
                base64Encoded: clientHello.clientEphemeralPublicKey
              ),
              let clientNonce = Data(base64Encoded: clientHello.clientNonce),
              clientPublicKeyData.count == 65,
              clientNonce.count == 32 else {
            throw SecureTransportError.invalidHandshake
        }

        let signingPrivateKey = try P256.Signing.PrivateKey(
            rawRepresentation: signingPrivateKeyData
        )
        let signingPublicKey = signingPrivateKey.publicKey.x963Representation
        let receiverKeyHash = SecureHandshake.receiverKeyHash(signingPublicKey)
        if authenticationMode == .trusted {
            guard clientHello.expectedReceiverId == receiverId,
                  clientHello.expectedReceiverKeyHash == receiverKeyHash else {
                throw SecureTransportError.authenticationFailed
            }
        }

        let agreementPrivateKey = ephemeralPrivateKey ?? P256.KeyAgreement.PrivateKey()
        let agreementPublicKey = agreementPrivateKey.publicKey.x963Representation
        let serverNonce = suppliedServerNonce ?? randomBytes(count: 32)
        guard serverNonce.count == 32 else {
            throw SecureTransportError.invalidHandshake
        }
        let transcript = try SecureHandshake.transcript(
            clientHello: clientHello,
            serverSigningPublicKey: signingPublicKey,
            serverEphemeralPublicKey: agreementPublicKey,
            serverNonce: serverNonce,
            receiverId: receiverId
        )
        let signature = try signingPrivateKey.signature(for: transcript).rawRepresentation
        let pairingProof: Data? = authenticationMode == .pairing
            ? try SecureHandshake.pairingProof(pairingCode: pairingCode, transcript: transcript)
            : nil

        let clientPublicKey = try P256.KeyAgreement.PublicKey(
            x963Representation: clientPublicKeyData
        )
        let sharedSecret = try agreementPrivateKey.sharedSecretFromKeyAgreement(
            with: clientPublicKey
        )
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        let keyMaterial = SecureSessionKeyMaterial.derive(
            sharedSecret: sharedSecretData,
            transcript: transcript,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )

        return SecureServerKeyExchangeResult(
            response: KeyExchangeServerHello(
                accepted: true,
                reason: nil,
                receiverId: receiverId,
                serverSigningPublicKey: signingPublicKey.base64EncodedString(),
                serverEphemeralPublicKey: agreementPublicKey.base64EncodedString(),
                serverNonce: serverNonce.base64EncodedString(),
                signature: signature.base64EncodedString(),
                pairingProof: pairingProof?.base64EncodedString()
            ),
            session: SecureRecordSession(role: .server, keyMaterial: keyMaterial),
            authenticationMode: authenticationMode,
            receiverKeyHash: receiverKeyHash
        )
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }
}

struct PairingAttemptLimiter {
    private struct Attempt {
        let peer: String
        let timestamp: TimeInterval
    }

    private let maxAttemptsPerPeer: Int
    private let maxAttemptsGlobally: Int
    private let window: TimeInterval
    private var attempts: [Attempt] = []

    init(
        maxAttemptsPerPeer: Int = 5,
        maxAttemptsGlobally: Int = 20,
        window: TimeInterval = 60
    ) {
        self.maxAttemptsPerPeer = maxAttemptsPerPeer
        self.maxAttemptsGlobally = maxAttemptsGlobally
        self.window = window
    }

    mutating func registerAttempt(peer: String, now: TimeInterval) -> Bool {
        attempts.removeAll { now - $0.timestamp >= window }
        let peerAttempts = attempts.lazy.filter { $0.peer == peer }.count
        guard peerAttempts < maxAttemptsPerPeer,
              attempts.count < maxAttemptsGlobally else {
            return false
        }
        attempts.append(Attempt(peer: peer, timestamp: now))
        return true
    }

    mutating func reset(peer: String) {
        attempts.removeAll { $0.peer == peer }
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixed(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt16.max) else {
            throw SecureTransportError.invalidHandshake
        }
        appendUInt16BE(UInt16(bytes.count))
        append(bytes)
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        self[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
