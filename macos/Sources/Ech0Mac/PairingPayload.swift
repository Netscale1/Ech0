import Foundation

struct PairingPayload: Codable {
    let v: Int
    let host: String
    let port: Int
    let token: String

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

enum PairingCode {
    static func generate() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

