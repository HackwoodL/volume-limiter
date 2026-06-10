import Foundation

/// A per-device volume cap override, keyed by the device's stable UID.
/// `name` is stored for human-readable config/listing and as a fallback match
/// when a device's UID changes (e.g. some Bluetooth re-pairings).
public struct DeviceLimit: Codable, Equatable {
    public var limit: Int
    public var name: String?

    public init(limit: Int, name: String? = nil) {
        self.limit = limit
        self.name = name
    }
}

public struct VolumeLimiterConfig: Codable, Equatable {
    public static let defaultLimit = 50

    public var enabled: Bool
    public var limit: Int
    public var headphoneOnly: Bool
    public var notifyOnLimit: Bool
    public var deviceLimitsEnabled: Bool
    public var deviceLimits: [String: DeviceLimit]

    public init(
        enabled: Bool = true,
        limit: Int = VolumeLimiterConfig.defaultLimit,
        headphoneOnly: Bool = false,
        notifyOnLimit: Bool = false,
        deviceLimitsEnabled: Bool = false,
        deviceLimits: [String: DeviceLimit] = [:]
    ) throws {
        self.enabled = enabled
        self.limit = try Self.validatedLimit(limit)
        self.headphoneOnly = headphoneOnly
        self.notifyOnLimit = notifyOnLimit
        self.deviceLimitsEnabled = deviceLimitsEnabled
        self.deviceLimits = try Self.validatedDeviceLimits(deviceLimits)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case limit
        case headphoneOnly
        case bluetoothOnly
        case notifyOnLimit
        case deviceLimitsEnabled
        case deviceLimits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        let headphoneOnly = try container.decodeIfPresent(Bool.self, forKey: .headphoneOnly)
            ?? container.decodeIfPresent(Bool.self, forKey: .bluetoothOnly)
            ?? false
        let notifyOnLimit = try container.decodeIfPresent(Bool.self, forKey: .notifyOnLimit) ?? false
        let deviceLimitsEnabled = try container.decodeIfPresent(Bool.self, forKey: .deviceLimitsEnabled) ?? false
        let storedDeviceLimits = try container.decodeIfPresent([String: DeviceLimit].self, forKey: .deviceLimits) ?? [:]
        let deviceLimits = storedDeviceLimits.mapValues { entry in
            DeviceLimit(limit: min(100, max(0, entry.limit)), name: entry.name)
        }

        try self.init(
            enabled: enabled,
            limit: limit,
            headphoneOnly: headphoneOnly,
            notifyOnLimit: notifyOnLimit,
            deviceLimitsEnabled: deviceLimitsEnabled,
            deviceLimits: deviceLimits
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(limit, forKey: .limit)
        try container.encode(headphoneOnly, forKey: .headphoneOnly)
        try container.encode(notifyOnLimit, forKey: .notifyOnLimit)
        try container.encode(deviceLimitsEnabled, forKey: .deviceLimitsEnabled)
        try container.encode(deviceLimits, forKey: .deviceLimits)
    }

    public static var `default`: VolumeLimiterConfig {
        try! VolumeLimiterConfig()
    }

    public static func validatedLimit(_ value: Int) throws -> Int {
        guard (0...100).contains(value) else {
            throw VolumeLimiterConfigError.invalidLimit(value)
        }
        return value
    }

    public static func validatedDeviceLimits(_ limits: [String: DeviceLimit]) throws -> [String: DeviceLimit] {
        try limits.mapValues { DeviceLimit(limit: try validatedLimit($0.limit), name: $0.name) }
    }

    /// Returns the override that applies to a device, matching by UID key first
    /// and then by stored display name (UID-change fallback). Nil if none.
    public func deviceLimit(forKey key: String?, name: String?) -> DeviceLimit? {
        if let key, let override = deviceLimits[key] {
            return override
        }
        if let name, let match = deviceLimits.values.first(where: { $0.name == name }) {
            return match
        }
        return nil
    }

    /// The map key whose override currently applies to the device, if any.
    public func deviceLimitKey(forKey key: String?, name: String?) -> String? {
        if let key, deviceLimits[key] != nil {
            return key
        }
        if let name {
            return deviceLimits.first(where: { $0.value.name == name })?.key
        }
        return nil
    }

    /// Effective cap for a device: its override if present, otherwise the default `limit`.
    public func resolvedLimit(forKey key: String?, name: String?) -> Int {
        deviceLimit(forKey: key, name: name)?.limit ?? limit
    }
}

public enum VolumeLimiterConfigError: Error, Equatable, LocalizedError {
    case invalidLimit(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidLimit(value):
            "Volume limit must be in 0...100, got \(value)."
        }
    }
}

public final class VolumeLimiterConfigStore {
    public let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("VolumeLimiter", isDirectory: true)
            self.fileURL = base.appendingPathComponent("config.json")
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() throws -> VolumeLimiterConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(VolumeLimiterConfig.self, from: data)
    }

    public func save(_ config: VolumeLimiterConfig) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: [.atomic])
    }
}
