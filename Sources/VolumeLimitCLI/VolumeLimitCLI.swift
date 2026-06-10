import Foundation
import VolumeLimiterIPC

public protocol VolumeLimiterClientSending {
    func send(_ request: IPCRequest) throws -> IPCResponse
}

extension UnixSocketClient: VolumeLimiterClientSending {}

public struct CommandOutput: Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct VolumeLimitCommandRunner {
    private let client: VolumeLimiterClientSending
    private let requestID: () -> String

    public init(
        client: VolumeLimiterClientSending,
        requestID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.client = client
        self.requestID = requestID
    }

    public func run(arguments: [String], executableName: String = "volume-limit") -> CommandOutput {
        guard let first = arguments.first else {
            return usageError("Missing command.", executableName: executableName)
        }

        if first == "--help" || first == "-h" || first == "help" {
            return CommandOutput(stdout: helpText(executableName: executableName))
        }

        do {
            switch first {
            case "set":
                return try handleSet(arguments: arguments)
            case "default":
                return try handleSetDefault(arguments: arguments)
            case "reset":
                return try handleReset(arguments: arguments)
            case "device":
                return try handleDevice(arguments: arguments)
            case "get":
                return try handleGet(arguments: arguments)
            case "status":
                return try handleStatus(arguments: arguments)
            case "on":
                return try handleToggle(arguments: arguments, enabled: true)
            case "off":
                return try handleToggle(arguments: arguments, enabled: false)
            case "headphone-only":
                return try handleHeadphoneOnly(arguments: arguments)
            default:
                return usageError("Unknown command: \(first)", executableName: executableName)
            }
        } catch let error as CLIError {
            return error.output(executableName: executableName)
        } catch {
            return CommandOutput(stderr: "\(executableName): \(error.localizedDescription)\n", exitCode: 1)
        }
    }

    private func handleSet(arguments: [String]) throws -> CommandOutput {
        guard arguments.count == 2 else {
            throw CLIError.usage("Expected: set <0-100>")
        }
        guard let value = Int(arguments[1]), (0...100).contains(value) else {
            throw CLIError.usage("Volume limit must be an integer in 0...100.")
        }

        let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.setLimit.rawValue, value: value))
        let device = response.deviceName ?? "the current device"
        let limit = try required(response.limit, field: "limit")
        return CommandOutput(stdout: "Limit for \(device) set to \(limit)%.\n")
    }

    private func handleSetDefault(arguments: [String]) throws -> CommandOutput {
        guard arguments.count == 2 else {
            throw CLIError.usage("Expected: default <0-100>")
        }
        guard let value = Int(arguments[1]), (0...100).contains(value) else {
            throw CLIError.usage("Volume limit must be an integer in 0...100.")
        }

        let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.setDefaultLimit.rawValue, value: value))
        let limit = try required(response.defaultLimit, field: "defaultLimit")
        return CommandOutput(stdout: "Default limit set to \(limit)%.\n")
    }

    private func handleReset(arguments: [String]) throws -> CommandOutput {
        guard arguments.count == 1 else {
            throw CLIError.usage("Expected: reset")
        }

        let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.resetDeviceLimit.rawValue))
        let device = response.deviceName ?? "the current device"
        let limit = try required(response.limit, field: "limit")
        return CommandOutput(stdout: "\(device) now uses the default limit (\(limit)%).\n")
    }

    private func handleDevice(arguments: [String]) throws -> CommandOutput {
        guard arguments.count == 2, arguments[1] == "list" else {
            throw CLIError.usage("Expected: device list")
        }

        let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.getStatus.rawValue))
        let defaultLimit = try required(response.defaultLimit, field: "defaultLimit")
        let entries = response.deviceLimits ?? []

        var lines = ["Default limit: \(defaultLimit)%"]
        if entries.isEmpty {
            lines.append("No per-device limits configured.")
        } else {
            lines.append("Per-device limits:")
            for entry in entries {
                lines.append("  - \(entry.name ?? entry.uid): \(entry.limit)%  [\(entry.uid)]")
            }
        }
        return CommandOutput(stdout: lines.joined(separator: "\n").appending("\n"))
    }

    private func handleGet(arguments: [String]) throws -> CommandOutput {
        guard arguments.count == 1 else {
            throw CLIError.usage("Expected: get")
        }
        let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.getStatus.rawValue))
        return CommandOutput(stdout: try compactStatusText(response))
    }

    private func handleStatus(arguments: [String]) throws -> CommandOutput {
        guard arguments.count == 1 else {
            throw CLIError.usage("Expected: status")
        }
        let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.getStatus.rawValue))
        return CommandOutput(stdout: try fullStatusText(response))
    }

    private func handleToggle(arguments: [String], enabled: Bool) throws -> CommandOutput {
        guard arguments.count == 1 else {
            throw CLIError.usage("Expected: \(enabled ? "on" : "off")")
        }
        let response = try send(
            IPCRequest(
                id: requestID(),
                cmd: IPCCommand.setEnabled.rawValue,
                enabled: enabled
            )
        )
        let state = try required(response.enabled, field: "enabled") ? "on" : "off"
        return CommandOutput(stdout: "Volume limiting is \(state).\n")
    }

    private func handleHeadphoneOnly(arguments: [String]) throws -> CommandOutput {
        guard arguments.count == 2 else {
            throw CLIError.usage("Expected: headphone-only <on|off|status>")
        }

        switch arguments[1] {
        case "on", "off":
            let enabled = arguments[1] == "on"
            let response = try send(
                IPCRequest(
                    id: requestID(),
                    cmd: IPCCommand.setHeadphoneOnly.rawValue,
                    enabled: enabled
                )
            )
            let state = try required(response.headphoneOnly, field: "headphoneOnly") ? "on" : "off"
            return CommandOutput(stdout: "Headphone-only mode is \(state).\n")
        case "status":
            let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.getStatus.rawValue))
            let state = try required(response.headphoneOnly, field: "headphoneOnly") ? "on" : "off"
            return CommandOutput(stdout: "Headphone-only mode is \(state).\n")
        default:
            throw CLIError.usage("Expected: headphone-only <on|off|status>")
        }
    }

    private func send(_ request: IPCRequest) throws -> IPCResponse {
        do {
            let response = try client.send(request)
            guard response.ok else {
                throw CLIError.daemonError(response.error?.message ?? "daemon returned an unknown error")
            }
            return response
        } catch let error as CLIError {
            throw error
        } catch let error as UnixSocketError {
            if error.isConnectionFailure {
                throw CLIError.daemonUnavailable
            }
            throw error
        }
    }
}

public func runVolumeLimitCLI(arguments: [String], executablePath: String) -> Never {
    let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
    let runner = VolumeLimitCommandRunner(client: UnixSocketClient())
    let output = runner.run(arguments: arguments, executableName: executableName)
    if !output.stdout.isEmpty {
        print(output.stdout, terminator: "")
    }
    if !output.stderr.isEmpty {
        fputs(output.stderr, stderr)
    }
    exit(output.exitCode)
}

private enum CLIError: Error {
    case usage(String)
    case daemonUnavailable
    case daemonError(String)
    case missingResponseField(String)

    func output(executableName: String) -> CommandOutput {
        switch self {
        case let .usage(message):
            return CommandOutput(
                stderr: "\(message)\n\n\(helpText(executableName: executableName))",
                exitCode: 64
            )
        case .daemonUnavailable:
            return CommandOutput(
                stderr: """
                volume-limiterd is not running.
                Start it with: brew services start volume-limiter
                """.appending("\n"),
                exitCode: 69
            )
        case let .daemonError(message):
            return CommandOutput(stderr: "volume-limiterd error: \(message)\n", exitCode: 1)
        case let .missingResponseField(field):
            return CommandOutput(stderr: "volume-limiterd response is missing '\(field)'.\n", exitCode: 1)
        }
    }
}

private func usageError(_ message: String, executableName: String) -> CommandOutput {
    CommandOutput(
        stderr: "\(message)\n\n\(helpText(executableName: executableName))",
        exitCode: 64
    )
}

private func required<T>(_ value: T?, field: String) throws -> T {
    guard let value else {
        throw CLIError.missingResponseField(field)
    }
    return value
}

private func compactStatusText(_ response: IPCResponse) throws -> String {
    let currentVolume = response.currentVolume.map { "\($0)%" } ?? "unavailable"
    let limit = try required(response.limit, field: "limit")
    let scope = (response.deviceHasLimitOverride ?? false) ? "this device" : "default"
    return """
    Limit: \(limit)% (\(scope))
    Current volume: \(currentVolume)
    Device: \(try required(response.deviceName, field: "deviceName"))
    Enabled: \(try onOff(required(response.enabled, field: "enabled")))
    Headphone-only: \(try onOff(required(response.headphoneOnly, field: "headphoneOnly")))
    """
    .appending("\n")
}

private func fullStatusText(_ response: IPCResponse) throws -> String {
    let currentVolume = response.currentVolume.map { "\($0)%" } ?? "unavailable"
    let diagnostics = response.diagnostics ?? []
    let diagnosticText = diagnostics.isEmpty
        ? "Diagnostics: none\n"
        : "Diagnostics:\n" + diagnostics.map { "  - \($0)" }.joined(separator: "\n") + "\n"

    let overrides = response.deviceLimits ?? []
    let deviceLimitsText = overrides.isEmpty
        ? "Per-device limits: none\n"
        : "Per-device limits:\n" + overrides.map { "  - \($0.name ?? $0.uid): \($0.limit)%" }.joined(separator: "\n") + "\n"

    return """
    Volume Limiter daemon: running
    Enabled: \(try onOff(required(response.enabled, field: "enabled")))
    Limit: \(try required(response.limit, field: "limit"))% (\((response.deviceHasLimitOverride ?? false) ? "per-device override" : "default"))
    Default limit: \(try required(response.defaultLimit, field: "defaultLimit"))%
    Current volume: \(currentVolume)
    Device: \(try required(response.deviceName, field: "deviceName"))
    Headphone-only: \(try onOff(required(response.headphoneOnly, field: "headphoneOnly")))
    Device is headphone: \(try yesNo(required(response.deviceIsHeadphone, field: "deviceIsHeadphone")))
    Volume control available: \(try yesNo(required(response.volumeControlAvailable, field: "volumeControlAvailable")))
    Notify on limit: \(try onOff(required(response.notifyOnLimit, field: "notifyOnLimit")))
    \(deviceLimitsText)\(diagnosticText)
    """
}

private func helpText(executableName: String) -> String {
    """
    Usage:
      \(executableName) set <0-100>          Cap the device you're currently using
      \(executableName) reset                Make the current device use the default cap
      \(executableName) default <0-100>      Set the default cap for other devices
      \(executableName) device list          List per-device caps
      \(executableName) get
      \(executableName) on
      \(executableName) off
      \(executableName) status
      \(executableName) headphone-only on
      \(executableName) headphone-only off
      \(executableName) headphone-only status
      \(executableName) --help

    volume-limit is a thin client; volume-limiterd owns Core Audio and configuration.
    Each output device remembers its own cap; "default" applies to devices you
    haven't set explicitly.
    """
}

private func onOff(_ value: Bool) -> String {
    value ? "on" : "off"
}

private func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
}

private extension UnixSocketError {
    var isConnectionFailure: Bool {
        switch self {
        case let .systemCall(name, errnoValue):
            name == "connect" && [ENOENT, ECONNREFUSED, ECONNRESET, EACCES].contains(errnoValue)
        case .disconnected:
            true
        case .pathTooLong, .invalidUTF8:
            false
        }
    }
}
