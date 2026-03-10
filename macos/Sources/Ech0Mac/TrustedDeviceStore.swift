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
            guard let index = devices.firstIndex(where: { $0.id == senderId && $0.secretHash == secretHash }) else {
                return false
            }
            devices[index].lastSeenAt = Date()
            persistUnlocked()
            return true
        }
    }

    @discardableResult
    func trust(senderId: String?, deviceName: String, trustedSecret: String?) -> TrustUpdate? {
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

        return lock.withLock {
            var evicted: TrustedDevice?

            if let index = devices.firstIndex(where: { $0.id == senderId }) {
                devices[index].deviceName = deviceName
                devices[index].lastSeenAt = now
                devices[index] = TrustedDevice(
                    id: senderId,
                    deviceName: deviceName,
                    secretHash: secretHash,
                    firstTrustedAt: devices[index].firstTrustedAt,
                    lastSeenAt: now
                )
                persistUnlocked()
                return TrustUpdate(device: devices[index], wasNew: false, evicted: nil)
            }

            if devices.count >= 2, let oldestIndex = devices.indices.min(by: { devices[$0].lastSeenAt < devices[$1].lastSeenAt }) {
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
            persistUnlocked()
            return TrustUpdate(device: device, wasNew: true, evicted: evicted)
        }
    }

    @discardableResult
    func forget(id: String) -> Bool {
        lock.withLock {
            guard let index = devices.firstIndex(where: { $0.id == id }) else {
                return false
            }
            devices.remove(at: index)
            persistUnlocked()
            return true
        }
    }

    private func load() {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else {
                devices = []
                return
            }
            devices = (try? JSONDecoder().decode([TrustedDevice].self, from: data)) ?? []
        }
    }

    private func persistUnlocked() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(devices)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Keep the in-memory state even if persistence fails.
        }
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
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
