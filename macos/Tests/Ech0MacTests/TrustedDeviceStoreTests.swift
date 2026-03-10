import XCTest
@testable import Ech0Mac

final class TrustedDeviceStoreTests: XCTestCase {
    func testTrustAndValidateDevice() throws {
        let store = TrustedDeviceStore(fileURL: temporaryFileURL())

        let update = store.trust(senderId: "sender-1", deviceName: "Pixel 9", trustedSecret: "secret-1")

        XCTAssertNotNil(update)
        XCTAssertTrue(store.validate(senderId: "sender-1", trustedSecret: "secret-1"))
        XCTAssertEqual(store.allDevices().count, 1)
    }

    func testEvictsOldestTrustedDeviceWhenLimitIsExceeded() throws {
        let store = TrustedDeviceStore(fileURL: temporaryFileURL())

        _ = store.trust(senderId: "sender-1", deviceName: "Pixel 9", trustedSecret: "secret-1")
        _ = store.trust(senderId: "sender-2", deviceName: "Galaxy S24", trustedSecret: "secret-2")
        let update = store.trust(senderId: "sender-3", deviceName: "Nothing Phone", trustedSecret: "secret-3")

        XCTAssertEqual(store.allDevices().count, 2)
        XCTAssertFalse(store.validate(senderId: "sender-1", trustedSecret: "secret-1"))
        XCTAssertTrue(store.validate(senderId: "sender-2", trustedSecret: "secret-2"))
        XCTAssertTrue(store.validate(senderId: "sender-3", trustedSecret: "secret-3"))
        XCTAssertEqual(update?.evicted?.id, "sender-1")
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
    }
}
