import XCTest
@testable import Ech0Mac

final class LocalHostResolverTests: XCTestCase {
    func testPrefersPhysicalPrivateInterfaceOverVirtualOne() {
        let address = LocalHostResolver.bestIPv4Address(
            from: [
                InterfaceAddress(name: "utun2", address: "10.8.0.2", flags: Int32(IFF_UP)),
                InterfaceAddress(name: "en0", address: "192.168.1.24", flags: Int32(IFF_UP))
            ]
        )

        XCTAssertEqual(address, "192.168.1.24")
    }

    func testIgnoresLinkLocalAddressesWhenChoosingPairingHost() {
        let address = LocalHostResolver.bestIPv4Address(
            from: [
                InterfaceAddress(name: "en0", address: "169.254.12.20", flags: Int32(IFF_UP)),
                InterfaceAddress(name: "en1", address: "10.0.0.25", flags: Int32(IFF_UP))
            ]
        )

        XCTAssertEqual(address, "10.0.0.25")
    }
}
