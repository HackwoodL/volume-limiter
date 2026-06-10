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
    case setEnabled
    case setBluetoothOnly
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

public struct IPCResponse: Codable, Equatable {
    public var ok: Bool
    public var id: String
    public var error: IPCErrorPayload?
    public var enabled: Bool?
    public var limit: Int?
    public var currentVolume: Int?
    public var deviceName: String?
    public var bluetoothOnly: Bool?
    public var notifyOnLimit: Bool?
    public var deviceIsBluetooth: Bool?
    public var volumeControlAvailable: Bool?
    public var diagnostics: [String]?

    public init(
        ok: Bool,
        id: String,
        error: IPCErrorPayload? = nil,
        enabled: Bool? = nil,
        limit: Int? = nil,
        currentVolume: Int? = nil,
        deviceName: String? = nil,
        bluetoothOnly: Bool? = nil,
        notifyOnLimit: Bool? = nil,
        deviceIsBluetooth: Bool? = nil,
        volumeControlAvailable: Bool? = nil,
        diagnostics: [String]? = nil
    ) {
        self.ok = ok
        self.id = id
        self.error = error
        self.enabled = enabled
        self.limit = limit
        self.currentVolume = currentVolume
        self.deviceName = deviceName
        self.bluetoothOnly = bluetoothOnly
        self.notifyOnLimit = notifyOnLimit
        self.deviceIsBluetooth = deviceIsBluetooth
        self.volumeControlAvailable = volumeControlAvailable
        self.diagnostics = diagnostics
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
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Unsupported IPC protocol version \(version)."
        case let .unknownCommand(command):
            "Unknown IPC command '\(command)'."
        case let .missingArgument(argument):
            "Missing required argument '\(argument)'."
        case let .invalidRequest(message):
            "Invalid IPC request: \(message)"
        }
    }
}
