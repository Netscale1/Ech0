import CryptoKit
import Foundation

final class TrustedDeviceStore {
    private let lock = NSLock()
    private let fileURL: URL
    private var devices: [TrustedDevice] = []

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func allDevices() -> [TrustedDevice] {
        lock.withLock {
            devices.sorted { $0.lastSeenAt > $1.lastSeenAt }
        }
    }

    func validate(senderId: String?, trustedSecret: String?) -> Bool {
        guard
            let senderId,
            !senderId.isEmpty,
            let trustedSecret,
            !trustedSecret.isEmpty
        else {
            return false
        }

        let secretHash = Self.hash(secret: trustedSecret)
        return lock.withLock {
            guard let index = devices.firstIndex(where: { $0.id == senderId }),
                  SecureHandshake.constantTimeEquals(
                    Data(devices[index].secretHash.utf8),
                    Data(secretHash.utf8)
                  ) else {
                return false
            }
            let previousDevice = devices[index]
            devices[index].lastSeenAt = Date()
            do {
                try persistUnlocked()
            } catch {
                devices[index] = previousDevice
            }
            return true
        }
    }

    @discardableResult
    func trust(senderId: String?, deviceName: String, trustedSecret: String?) throws -> TrustUpdate? {
        guard
            let senderId,
            !senderId.isEmpty,
            let trustedSecret,
            !trustedSecret.isEmpty
        else {
            return nil
        }

        let now = Date()
        let secretHash = Self.hash(secret: trustedSecret)

        return try lock.withLock {
            let previousDevices = devices
            do {
                var evicted: TrustedDevice?

                if let index = devices.firstIndex(where: { $0.id == senderId }) {
                    devices[index] = TrustedDevice(
                        id: senderId,
                        deviceName: deviceName,
                        secretHash: secretHash,
                        firstTrustedAt: devices[index].firstTrustedAt,
                        lastSeenAt: now
                    )
                    try persistUnlocked()
                    return TrustUpdate(device: devices[index], wasNew: false, evicted: nil)
                }

                if devices.count >= 2,
                   let oldestIndex = devices.indices.min(by: {
                       devices[$0].lastSeenAt < devices[$1].lastSeenAt
                   }) {
                    evicted = devices.remove(at: oldestIndex)
                }

                let device = TrustedDevice(
                    id: senderId,
                    deviceName: deviceName,
                    secretHash: secretHash,
                    firstTrustedAt: now,
                    lastSeenAt: now
                )
                devices.append(device)
                try persistUnlocked()
                return TrustUpdate(device: device, wasNew: true, evicted: evicted)
            } catch {
                devices = previousDevices
                throw error
            }
        }
    }

    @discardableResult
    func forget(id: String) throws -> Bool {
        try lock.withLock {
            guard let index = devices.firstIndex(where: { $0.id == id }) else {
                return false
            }
            let previousDevices = devices
            devices.remove(at: index)
            do {
                try persistUnlocked()
                return true
            } catch {
                devices = previousDevices
                throw error
            }
        }
    }

    private func load() {
        lock.withLock {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard (try? applyPrivatePermissions()) != nil else {
                    devices = []
                    return
                }
            }
            guard let data = try? Data(contentsOf: fileURL) else {
                devices = []
                return
            }
            devices = (try? JSONDecoder().decode([TrustedDevice].self, from: data)) ?? []
        }
    }

    private func persistUnlocked() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let data = try JSONEncoder().encode(devices)
        try data.write(to: fileURL, options: .atomic)
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
            .appendingPathComponent("trusted-devices.json", isDirectory: false)
    }

    private static func hash(secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct TrustUpdate {
    let device: TrustedDevice
    let wasNew: Bool
    let evicted: TrustedDevice?
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
