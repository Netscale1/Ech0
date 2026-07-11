import XCTest
@testable import Ech0Mac

final class ReceiverIdentityStoreTests: XCTestCase {
    func testIdentityPersistsAcrossStoreInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("identity.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ReceiverIdentityStore(fileURL: fileURL).loadOrCreate()
        let second = ReceiverIdentityStore(fileURL: fileURL).loadOrCreate()

        XCTAssertFalse(first.id.isEmpty)
        XCTAssertEqual(first, second)
    }
}
