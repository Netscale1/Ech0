import Foundation
import CryptoKit
import XCTest
@testable import Ech0Mac

final class SecureTransportTests: XCTestCase {
    func testPairingCodeCarriesHighEntropyAndNormalizesForCopyPaste() {
        let code = PairingCode.generate()

        XCTAssertTrue(PairingCode.isValid(code))
        XCTAssertEqual(PairingCode.normalize(code)?.count, 26)
        XCTAssertEqual(
            PairingCode.normalize("  \(code.lowercased())\n"),
            PairingCode.normalize(code)
        )
    }

    func testEncryptedRecordsRoundTripInBothDirections() throws {
        let keys = testKeyMaterial()
        let client = SecureRecordSession(role: .client, keyMaterial: keys)
        let server = SecureRecordSession(role: .server, keyMaterial: keys)

        let clientRecord = try client.seal(Data("client payload".utf8))
        XCTAssertEqual(try server.open(clientRecord), Data("client payload".utf8))

        let serverRecord = try server.seal(Data("server payload".utf8))
        XCTAssertEqual(try client.open(serverRecord), Data("server payload".utf8))
    }

    func testEncryptedRecordsRejectTamperingReplayAndWrongDirection() throws {
        let keys = testKeyMaterial()
        let client = SecureRecordSession(role: .client, keyMaterial: keys)
        let server = SecureRecordSession(role: .server, keyMaterial: keys)
        let wrongDirection = SecureRecordSession(role: .client, keyMaterial: keys)
        let record = try client.seal(Data("credential".utf8))

        var tampered = record
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try server.open(tampered))

        let freshServer = SecureRecordSession(role: .server, keyMaterial: keys)
        XCTAssertEqual(try freshServer.open(record), Data("credential".utf8))
        XCTAssertThrowsError(try freshServer.open(record))
        XCTAssertThrowsError(try wrongDirection.open(record))
    }

    func testPairingProofRejectsWrongCode() throws {
        let transcript = Data("handshake transcript".utf8)
        let proof = try SecureHandshake.pairingProof(
            pairingCode: "ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ",
            transcript: transcript
        )

        XCTAssertTrue(
            SecureHandshake.constantTimeEquals(
                proof,
                try SecureHandshake.pairingProof(
                    pairingCode: "ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ",
                    transcript: transcript
                )
            )
        )
        XCTAssertFalse(
            SecureHandshake.constantTimeEquals(
                proof,
                try SecureHandshake.pairingProof(
                    pairingCode: "ZBCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ",
                    transcript: transcript
                )
            )
        )
    }

    func testPairingAttemptsAreLimitedPerPeerAndGlobally() {
        var limiter = PairingAttemptLimiter(
            maxAttemptsPerPeer: 2,
            maxAttemptsGlobally: 3,
            window: 60
        )

        XCTAssertTrue(limiter.registerAttempt(peer: "10.0.0.1", now: 0))
        XCTAssertTrue(limiter.registerAttempt(peer: "10.0.0.1", now: 1))
        XCTAssertFalse(limiter.registerAttempt(peer: "10.0.0.1", now: 2))
        XCTAssertTrue(limiter.registerAttempt(peer: "10.0.0.2", now: 3))
        XCTAssertFalse(limiter.registerAttempt(peer: "10.0.0.3", now: 4))

        limiter.reset(peer: "10.0.0.1")
        XCTAssertTrue(limiter.registerAttempt(peer: "10.0.0.1", now: 5))
        XCTAssertTrue(limiter.registerAttempt(peer: "10.0.0.3", now: 61))
    }

    func testPlainKeyExchangeContainsNoCredentialOrDeviceIdentity() throws {
        let hello = KeyExchangeClientHello(
            protocolVersion: 3,
            authMode: "pairing",
            clientEphemeralPublicKey: Data(repeating: 0, count: 65).base64EncodedString(),
            clientNonce: Data(repeating: 0, count: 32).base64EncodedString(),
            expectedReceiverId: nil,
            expectedReceiverKeyHash: nil
        )

        let encoded = try ControlMessageCodec.encode(.keyExchangeClientHello(hello))
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("trustedSecret"))
        XCTAssertFalse(json.contains("pairingToken"))
        XCTAssertFalse(json.contains("deviceName"))
        XCTAssertFalse(json.contains("senderId"))
    }

    func testEncryptedRecordDoesNotExposeCredentialPlaintext() throws {
        let keys = testKeyMaterial()
        let client = SecureRecordSession(role: .client, keyMaterial: keys)
        let credential = Data("interop-trusted-secret".utf8)

        let record = try client.seal(credential)

        XCTAssertNil(record.range(of: credential))
    }

    func testSignedEphemeralHandshakeAuthenticatesPairingAndDerivesMatchingKeys() throws {
        let signingKey = try P256.Signing.PrivateKey(
            rawRepresentation: scalar(1)
        )
        let serverAgreementKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: scalar(2)
        )
        let clientAgreementKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: scalar(3)
        )
        let clientNonce = Data(repeating: 0x44, count: 32)
        let serverNonce = Data(repeating: 0x55, count: 32)
        let pairingCode = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ"
        let hello = KeyExchangeClientHello(
            protocolVersion: 3,
            authMode: "pairing",
            clientEphemeralPublicKey: clientAgreementKey.publicKey.x963Representation.base64EncodedString(),
            clientNonce: clientNonce.base64EncodedString(),
            expectedReceiverId: nil,
            expectedReceiverKeyHash: nil
        )

        let result = try SecureServerKeyExchange.accept(
            hello,
            receiverId: "receiver-1",
            signingPrivateKeyData: signingKey.rawRepresentation,
            pairingCode: pairingCode,
            ephemeralPrivateKey: serverAgreementKey,
            serverNonce: serverNonce
        )
        let transcript = try SecureHandshake.transcript(
            clientHello: hello,
            serverSigningPublicKey: signingKey.publicKey.x963Representation,
            serverEphemeralPublicKey: serverAgreementKey.publicKey.x963Representation,
            serverNonce: serverNonce,
            receiverId: "receiver-1"
        )
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: Data(base64Encoded: result.response.signature!)!
        )
        XCTAssertTrue(signingKey.publicKey.isValidSignature(signature, for: transcript))
        XCTAssertTrue(
            SecureHandshake.constantTimeEquals(
                Data(base64Encoded: result.response.pairingProof!)!,
                try SecureHandshake.pairingProof(
                    pairingCode: pairingCode,
                    transcript: transcript
                )
            )
        )

        let clientSharedSecret = try clientAgreementKey.sharedSecretFromKeyAgreement(
            with: serverAgreementKey.publicKey
        )
        let clientKeys = SecureSessionKeyMaterial.derive(
            sharedSecret: clientSharedSecret.withUnsafeBytes { Data($0) },
            transcript: transcript,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        let clientSession = SecureRecordSession(role: .client, keyMaterial: clientKeys)
        let encrypted = try clientSession.seal(Data("encrypted hello".utf8))
        XCTAssertEqual(
            transcript.hex,
            "456368302d76332d68616e647368616b65000301000000004444444444444444444444444444444444444444444444444444444444444444045ecbe4d1a6330a44c8f7ef951d4bf165e6c6b721efada985fb41661bc6e7fd6c8734640c4998ff7e374b06ce1a64a2ecd82ab036384fb83d9a79b127a27d50325555555555555555555555555555555555555555555555555555555555555555047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5000a72656365697665722d31"
        )
        XCTAssertEqual(
            clientSharedSecret.withUnsafeBytes { Data($0) }.hex,
            "b01a172a76a4602c92d3242cb897dde3024c740debb215b4c6b0aae93c2291a9"
        )
        XCTAssertEqual(
            (clientKeys.clientWriteKey + clientKeys.serverWriteKey + clientKeys.clientNoncePrefix + clientKeys.serverNoncePrefix).hex,
            "c3baefaf513bf0cc928a70dd32fe7a6e10c31eae5f896e00243d30d5ce05bf756b5ff986dd3f205486aa65b9fc5220b898cdbf59b129dcc2ec0874ca79464bacb032efd9dbb7ece6"
        )
        let vectorSession = SecureRecordSession(role: .client, keyMaterial: clientKeys)
        let vectorRecord = try vectorSession.seal(Data("interop".utf8))
        XCTAssertEqual(
            vectorRecord.hex,
            "453301010000000000000000000000072a423f5809b2e445f62321ef065ddb24871f5767c3b6d5"
        )
        XCTAssertEqual(try result.session.open(encrypted), Data("encrypted hello".utf8))
    }

    func testTrustedHandshakeRejectsAnUnpinnedReceiver() throws {
        let signingKey = P256.Signing.PrivateKey()
        let clientAgreementKey = P256.KeyAgreement.PrivateKey()
        let hello = KeyExchangeClientHello(
            protocolVersion: 3,
            authMode: "trusted",
            clientEphemeralPublicKey: clientAgreementKey.publicKey.x963Representation.base64EncodedString(),
            clientNonce: Data(repeating: 0x11, count: 32).base64EncodedString(),
            expectedReceiverId: "receiver-1",
            expectedReceiverKeyHash: "wrong-key"
        )

        XCTAssertThrowsError(
            try SecureServerKeyExchange.accept(
                hello,
                receiverId: "receiver-1",
                signingPrivateKeyData: signingKey.rawRepresentation,
                pairingCode: PairingCode.generate()
            )
        )
    }

    private func testKeyMaterial() -> SecureSessionKeyMaterial {
        SecureSessionKeyMaterial(
            clientWriteKey: Data(repeating: 0x11, count: 32),
            serverWriteKey: Data(repeating: 0x22, count: 32),
            clientNoncePrefix: Data([0x01, 0x02, 0x03, 0x04]),
            serverNoncePrefix: Data([0x05, 0x06, 0x07, 0x08])
        )
    }

    private func scalar(_ value: UInt8) -> Data {
        Data(repeating: 0, count: 31) + Data([value])
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
