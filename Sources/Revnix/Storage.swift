import Foundation

/// Small synchronous key-value store. The default is file-backed (survives
/// relaunch — the offline cache and the purchase retry queue depend on
/// that); `MemoryStorage` is for tests and previews.
public protocol RevnixStorage: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

public final class MemoryStorage: RevnixStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func set(_ key: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    public func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }
}

/// One JSON file under Application Support/revnix/. Loaded once, written
/// on every mutation (values are small: ids, one entitlement snapshot per
/// recent customer, the pending-purchase queue).
public final class FileStorage: RevnixStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir =
            directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent("revnix", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("storage.json")
        if let data = try? Data(contentsOf: fileURL),
            let loaded = try? JSONDecoder().decode(
                [String: String].self, from: data)
        {
            self.values = loaded
        } else {
            self.values = [:]
        }
    }

    public func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func set(_ key: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        persistLocked()
    }

    public func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
        persistLocked()
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

func generateAnonymousId() -> String {
    "rvx_anon_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        .lowercased()
}
