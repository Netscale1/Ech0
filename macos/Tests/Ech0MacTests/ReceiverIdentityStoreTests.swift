import CryptoKit
import XCTest
@testable import Ech0Mac

final class ReceiverIdentityStoreTests: XCTestCase {
    func testIdentityPersistsAcrossStoreInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ReceiverIdentityStore(fileURL: fileURL).loadOrCreate()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let second = try ReceiverIdentityStore(fileURL: fileURL).loadOrCreate()

        XCTAssertFalse(first.id.isEmpty)
        XCTAssertNoThrow(
            try P256.Signing.PrivateKey(rawRepresentation: first.signingPrivateKey)
        )
        XCTAssertEqual(first, second)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
    }

    func testLegacyIdentityIsMigratedWithoutChangingReceiverId() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"id":"legacy-receiver"}"#.utf8).write(to: fileURL)

        let identity = try ReceiverIdentityStore(fileURL: fileURL).loadOrCreate()

        XCTAssertEqual(identity.id, "legacy-receiver")
        XCTAssertNoThrow(
            try P256.Signing.PrivateKey(rawRepresentation: identity.signingPrivateKey)
        )
    }

    func testCorruptedPersistedIdentityFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)

        XCTAssertThrowsError(try ReceiverIdentityStore(fileURL: fileURL).loadOrCreate())
    }

    func testIdentityCreationFailsInsteadOfReturningEphemeralIdentity() throws {
        let blockingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: blockingParent.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: blockingParent) }

        XCTAssertThrowsError(
            try ReceiverIdentityStore(
                fileURL: blockingParent.appendingPathComponent("receiver-identity.json")
            ).loadOrCreate()
        )
    }
}
