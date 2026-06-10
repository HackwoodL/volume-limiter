import Foundation

public struct VolumeLimiterConfig: Codable, Equatable {
    public static let defaultLimit = 50

    public var enabled: Bool
    public var limit: Int
    public var headphoneOnly: Bool
    public var notifyOnLimit: Bool

    public init(
        enabled: Bool = true,
        limit: Int = VolumeLimiterConfig.defaultLimit,
        headphoneOnly: Bool = false,
        notifyOnLimit: Bool = false
    ) throws {
        self.enabled = enabled
        self.limit = try Self.validatedLimit(limit)
        self.headphoneOnly = headphoneOnly
        self.notifyOnLimit = notifyOnLimit
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case limit
        case headphoneOnly
        case bluetoothOnly
        case notifyOnLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        let headphoneOnly = try container.decodeIfPresent(Bool.self, forKey: .headphoneOnly)
            ?? container.decodeIfPresent(Bool.self, forKey: .bluetoothOnly)
            ?? false
        let notifyOnLimit = try container.decodeIfPresent(Bool.self, forKey: .notifyOnLimit) ?? false

        try self.init(
            enabled: enabled,
            limit: limit,
            headphoneOnly: headphoneOnly,
            notifyOnLimit: notifyOnLimit
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(limit, forKey: .limit)
        try container.encode(headphoneOnly, forKey: .headphoneOnly)
        try container.encode(notifyOnLimit, forKey: .notifyOnLimit)
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
