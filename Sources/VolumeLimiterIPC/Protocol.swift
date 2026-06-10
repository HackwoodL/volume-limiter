import Foundation

public enum VolumeLimiterIPC {
    public static let version = 1

    public static func defaultSocketPath(uid: uid_t = getuid()) -> String {
        "/tmp/volume-limiter-\(uid).sock"
    }
}

public enum IPCCommand: String, Codable, Equatable {
    case ping
    case getStatus
    case setLimit
    case setDefaultLimit
    case resetDeviceLimit
    case setEnabled
    case setHeadphoneOnly
    case setNotifyOnLimit
}

public struct IPCRequest: Codable, Equatable {
    public var version: Int
    public var id: String
    public var cmd: String
    public var value: Int?
    public var enabled: Bool?

    public init(
        version: Int = VolumeLimiterIPC.version,
        id: String,
        cmd: String,
        value: Int? = nil,
        enabled: Bool? = nil
    ) {
        self.version = version
        self.id = id
        self.cmd = cmd
        self.value = value
        self.enabled = enabled
    }

    public var command: IPCCommand? {
        IPCCommand(rawValue: cmd)
    }
}

public struct IPCErrorPayload: Codable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A per-device volume cap override, transported in status responses for listing.
public struct DeviceLimitEntry: Codable, Equatable {
    public var uid: String
    public var name: String?
    public var limit: Int

    public init(uid: String, name: String? = nil, limit: Int) {
        self.uid = uid
        self.name = name
        self.limit = limit
    }
}

public struct IPCResponse: Codable, Equatable {
    public var ok: Bool
    public var id: String
    public var error: IPCErrorPayload?
    public var enabled: Bool?
    public var limit: Int?
    public var currentVolume: Int?
    public var deviceName: String?
    public var headphoneOnly: Bool?
    public var notifyOnLimit: Bool?
    public var deviceIsHeadphone: Bool?
    public var volumeControlAvailable: Bool?
    public var diagnostics: [String]?
    public var deviceUID: String?
    public var defaultLimit: Int?
    public var deviceHasLimitOverride: Bool?
    public var deviceLimits: [DeviceLimitEntry]?

    public init(
        ok: Bool,
        id: String,
        error: IPCErrorPayload? = nil,
        enabled: Bool? = nil,
        limit: Int? = nil,
        currentVolume: Int? = nil,
        deviceName: String? = nil,
        headphoneOnly: Bool? = nil,
        notifyOnLimit: Bool? = nil,
        deviceIsHeadphone: Bool? = nil,
        volumeControlAvailable: Bool? = nil,
        diagnostics: [String]? = nil,
        deviceUID: String? = nil,
        defaultLimit: Int? = nil,
        deviceHasLimitOverride: Bool? = nil,
        deviceLimits: [DeviceLimitEntry]? = nil
    ) {
        self.ok = ok
        self.id = id
        self.error = error
        self.enabled = enabled
        self.limit = limit
        self.currentVolume = currentVolume
        self.deviceName = deviceName
        self.headphoneOnly = headphoneOnly
        self.notifyOnLimit = notifyOnLimit
        self.deviceIsHeadphone = deviceIsHeadphone
        self.volumeControlAvailable = volumeControlAvailable
        self.diagnostics = diagnostics
        self.deviceUID = deviceUID
        self.defaultLimit = defaultLimit
        self.deviceHasLimitOverride = deviceHasLimitOverride
        self.deviceLimits = deviceLimits
    }

    public static func success(id: String) -> IPCResponse {
        IPCResponse(ok: true, id: id)
    }

    public static func failure(id: String, code: String, message: String) -> IPCResponse {
        IPCResponse(ok: false, id: id, error: IPCErrorPayload(code: code, message: message))
    }
}

public enum IPCProtocolError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case unknownCommand(String)
    case missingArgument(String)
    case invalidArgument(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Unsupported IPC protocol version \(version)."
        case let .unknownCommand(command):
            "Unknown IPC command '\(command)'."
        case let .missingArgument(argument):
            "Missing required argument '\(argument)'."
        case let .invalidArgument(message):
            "Invalid argument: \(message)"
        case let .invalidRequest(message):
            "Invalid IPC request: \(message)"
        }
    }
}
