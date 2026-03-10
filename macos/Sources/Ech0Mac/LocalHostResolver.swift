import Darwin
import Foundation

enum LocalHostResolver {
    static func primaryIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }

        defer { freeifaddrs(interfaces) }

        var candidates: [InterfaceAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }

            guard let socketAddress = entry.ifa_addr else { continue }
            let family = socketAddress.pointee.sa_family
            let flags = Int32(entry.ifa_flags)
            guard family == UInt8(AF_INET) else { continue }
            guard (flags & IFF_UP) == IFF_UP else { continue }
            guard (flags & IFF_LOOPBACK) != IFF_LOOPBACK else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                candidates.append(
                    InterfaceAddress(
                        name: String(cString: entry.ifa_name),
                        address: String(cString: hostname),
                        flags: flags
                    )
                )
            }
        }

        return bestIPv4Address(from: candidates)
    }

    static func bestIPv4Address(from candidates: [InterfaceAddress]) -> String? {
        candidates
            .filter { candidate in
                guard (candidate.flags & IFF_UP) == IFF_UP else { return false }
                guard (candidate.flags & IFF_LOOPBACK) != IFF_LOOPBACK else { return false }
                guard !candidate.isLinkLocal else { return false }
                guard !candidate.isVirtual else { return false }
                return true
            }
            .sorted(by: isPreferred(_:over:))
            .first?
            .address
    }

    private static func isPreferred(_ lhs: InterfaceAddress, over rhs: InterfaceAddress) -> Bool {
        let lhsScore = lhs.preferenceScore
        let rhsScore = rhs.preferenceScore
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }

        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }

        return lhs.address < rhs.address
    }
}

struct InterfaceAddress: Equatable {
    let name: String
    let address: String
    let flags: Int32

    private static let virtualPrefixes = [
        "utun",
        "tun",
        "tap",
        "ppp",
        "ipsec",
        "wg",
        "bridge",
        "vmnet",
        "vnic",
        "feth",
        "gif",
        "stf",
        "awdl",
        "llw",
        "anpi",
        "ap"
    ]

    var isVirtual: Bool {
        Self.virtualPrefixes.contains { name.hasPrefix($0) }
    }

    var isPhysical: Bool {
        name.hasPrefix("en")
    }

    var isPrivateLAN: Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }

        switch (octets[0], octets[1]) {
        case (10, _), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    var isLinkLocal: Bool {
        address.hasPrefix("169.254.")
    }

    var preferenceScore: Int {
        var score = 0
        if isPhysical {
            score += 100
        }
        if isPrivateLAN {
            score += 10
        }
        return score
    }
}
