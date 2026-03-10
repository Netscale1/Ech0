import Foundation

struct TrustedDevice: Codable, Identifiable, Equatable {
    let id: String
    var deviceName: String
    let secretHash: String
    let firstTrustedAt: Date
    var lastSeenAt: Date
}
