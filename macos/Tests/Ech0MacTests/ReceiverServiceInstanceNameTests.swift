import Foundation
import Testing
@testable import Ech0Mac

struct ReceiverServiceInstanceNameTests {
    @Test
    func sessionIdentityChangesTheDnsSdInstanceName() throws {
        let firstSession = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let secondSession = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        let firstName = ReceiverServiceInstanceName.make(sessionID: firstSession)
        let secondName = ReceiverServiceInstanceName.make(sessionID: secondSession)

        #expect(firstName == "Ech0 11111111-1111-1111-1111-111111111111")
        #expect(firstName != secondName)
        #expect(firstName.utf8.count <= 63)
        #expect(secondName.utf8.count <= 63)
    }
}
