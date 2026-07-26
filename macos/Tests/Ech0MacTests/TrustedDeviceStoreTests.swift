import XCTest
@testable import Ech0Mac

final class TrustedDeviceStoreTests: XCTestCase {
    func testTrustAndValidateDevice() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = TrustedDeviceStore(fileURL: fileURL)

        let update = try store.trust(senderId: "sender-1", deviceName: "Windows PC", trustedSecret: "secret-1")

        XCTAssertNotNil(update)
        XCTAssertTrue(store.validate(senderId: "sender-1", trustedSecret: "secret-1"))
        XCTAssertEqual(store.allDevices().count, 1)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        _ = TrustedDeviceStore(fileURL: fileURL)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
    }

    func testEvictsOldestTrustedDeviceWhenLimitIsExceeded() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = TrustedDeviceStore(fileURL: fileURL)

        _ = try store.trust(senderId: "sender-1", deviceName: "Office PC", trustedSecret: "secret-1")
        _ = try store.trust(senderId: "sender-2", deviceName: "Laptop", trustedSecret: "secret-2")
        let update = try store.trust(senderId: "sender-3", deviceName: "Spare PC", trustedSecret: "secret-3")

        XCTAssertEqual(store.allDevices().count, 2)
        XCTAssertFalse(store.validate(senderId: "sender-1", trustedSecret: "secret-1"))
        XCTAssertTrue(store.validate(senderId: "sender-2", trustedSecret: "secret-2"))
        XCTAssertTrue(store.validate(senderId: "sender-3", trustedSecret: "secret-3"))
        XCTAssertEqual(update?.evicted?.id, "sender-1")
    }

    func testTrustRollsBackWhenPersistenceFails() throws {
        let blockingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: blockingParent.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: blockingParent) }
        let store = TrustedDeviceStore(
            fileURL: blockingParent.appendingPathComponent("trusted-devices.json")
        )

        XCTAssertThrowsError(
            try store.trust(
                senderId: "sender-1",
                deviceName: "Windows PC",
                trustedSecret: "secret-1"
            )
        )
        XCTAssertTrue(store.allDevices().isEmpty)
    }

    func testForgetRollsBackWhenPersistenceFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("trusted-devices.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrustedDeviceStore(fileURL: fileURL)
        _ = try store.trust(
            senderId: "sender-1",
            deviceName: "Windows PC",
            trustedSecret: "secret-1"
        )
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))

        XCTAssertThrowsError(try store.forget(id: "sender-1"))
        XCTAssertEqual(store.allDevices().map(\.id), ["sender-1"])
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("trusted-devices.json", isDirectory: false)
    }
}
