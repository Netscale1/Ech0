import Foundation

struct ReceiverIdentity: Codable, Equatable {
    let id: String
}

final class ReceiverIdentityStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func loadOrCreate() -> ReceiverIdentity {
        if
            let data = try? Data(contentsOf: fileURL),
            let identity = try? JSONDecoder().decode(ReceiverIdentity.self, from: data),
            !identity.id.isEmpty
        {
            return identity
        }

        let identity = ReceiverIdentity(id: UUID().uuidString.lowercased())
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(identity).write(to: fileURL, options: .atomic)
        } catch {
            // The in-memory identity remains usable for this run.
        }
        return identity
    }

    private static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return base
            .appendingPathComponent("Ech0Mac", isDirectory: true)
            .appendingPathComponent("receiver-identity.json", isDirectory: false)
    }
}
