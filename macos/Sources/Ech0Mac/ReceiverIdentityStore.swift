import CryptoKit
import Foundation

struct ReceiverIdentity: Codable, Equatable {
    let id: String
    let signingPrivateKey: Data

    init(id: String, signingPrivateKey: Data = Data()) {
        self.id = id
        self.signingPrivateKey = signingPrivateKey
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case signingPrivateKey
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        signingPrivateKey = try values.decodeIfPresent(
            Data.self,
            forKey: .signingPrivateKey
        ) ?? Data()
    }
}

final class ReceiverIdentityStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func loadOrCreate() throws -> ReceiverIdentity {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(ReceiverIdentity.self, from: data)
            guard !decoded.id.isEmpty else {
                throw SecureTransportError.invalidHandshake
            }
            if decoded.signingPrivateKey.isEmpty {
                let migrated = ReceiverIdentity(
                    id: decoded.id,
                    signingPrivateKey: P256.Signing.PrivateKey().rawRepresentation
                )
                try persist(migrated)
                return migrated
            }
            _ = try P256.Signing.PrivateKey(rawRepresentation: decoded.signingPrivateKey)
            try applyPrivatePermissions()
            return decoded
        }

        let identity = ReceiverIdentity(
            id: UUID().uuidString.lowercased(),
            signingPrivateKey: P256.Signing.PrivateKey().rawRepresentation
        )
        try persist(identity)
        return identity
    }

    private func persist(_ identity: ReceiverIdentity) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try JSONEncoder().encode(identity).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func applyPrivatePermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return base
            .appendingPathComponent("Ech0Mac", isDirectory: true)
            .appendingPathComponent("receiver-identity.json", isDirectory: false)
    }
}
