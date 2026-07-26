import Foundation

enum PairingCode {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    private static let normalizedLength = 26

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let random = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let encoded = base32Encode(random)
        return stride(from: 0, to: encoded.count, by: 4)
            .map { start in
                let end = min(start + 4, encoded.count)
                return String(decoding: encoded[start..<end], as: UTF8.self)
            }
            .joined(separator: "-")
    }

    static func normalize(_ value: String) -> String? {
        let candidate = value
            .filter { !$0.isWhitespace && $0 != "-" }
            .uppercased()
        guard candidate.utf8.count == normalizedLength else { return nil }
        guard candidate.utf8.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return candidate
    }

    static func isValid(_ value: String) -> Bool {
        normalize(value) != nil
    }

    private static func base32Encode(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(normalizedLength)
        var buffer: UInt32 = 0
        var bitCount = 0

        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                output.append(alphabet[Int((buffer >> UInt32(bitCount)) & 0x1f)])
            }
        }
        if bitCount > 0 {
            output.append(alphabet[Int((buffer << UInt32(5 - bitCount)) & 0x1f)])
        }
        return output
    }
}
