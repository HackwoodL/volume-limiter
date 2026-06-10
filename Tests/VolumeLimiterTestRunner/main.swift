import Darwin
import Foundation
import VolumeLimitCLI
import VolumeLimiterCore
import VolumeLimiterIPC

@main
struct VolumeLimiterTestRunner {
    static func main() throws {
        var suite = TestSuite()

        try suite.run("Core clamps startup volume above limit", testStartClampsVolumeAboveLimit)
        try suite.run("Core clamps on volume-change callback", testVolumeChangeCallbackClampsImmediately)
        try suite.run("Core bluetooth-only skips non-Bluetooth devices", testBluetoothOnlySkipsNonBluetoothDevices)
        try suite.run("Core bluetooth-only clamps Bluetooth devices", testBluetoothOnlyClampsBluetoothDevices)
        try suite.run("Core rejects invalid limit", testInvalidLimitIsRejected)
        try suite.run("Core disabled limiter does not clamp", testDisabledLimiterDoesNotClamp)
        try suite.run("IPC request/response Codable round trip", testRequestAndResponseCodableRoundTrip)
        try suite.run("IPC Unix socket handles newline JSON", testUnixSocketServerHandlesOneLineJSONRequests)
        try suite.run("IPC server returns structured error for invalid JSON", testServerRejectsInvalidJSON)
        try suite.run("CLI set sends setLimit request", testCLISetSendsSetLimitRequest)
        try suite.run("CLI get renders compact daemon status", testCLIGetRendersCompactStatus)
        try suite.run("CLI rejects invalid limit locally", testCLIRejectsInvalidLimit)
        try suite.run("CLI maps daemon connection failure", testCLIMapsDaemonConnectionFailure)

        print("All \(suite.passed) Volume Limiter tests passed.")
    }
}

private struct TestSuite {
    var passed = 0

    mutating func run(_ name: String, _ body: () throws -> Void) throws {
        do {
            try body()
            passed += 1
            print("PASS \(name)")
        } catch {
            fputs("FAIL \(name): \(error)\n", stderr)
            throw error
        }
    }
}

private enum TestFailure: Error, CustomStringConvertible {
    case expectedEqual(String, String, file: StaticString, line: UInt)
    case expectedTrue(String, file: StaticString, line: UInt)
    case expectedThrow(file: StaticString, line: UInt)

    var description: String {
        switch self {
        case let .expectedEqual(actual, expected, file, line):
            "expected \(actual) == \(expected) at \(file):\(line)"
        case let .expectedTrue(expression, file, line):
            "expected true for \(expression) at \(file):\(line)"
        case let .expectedThrow(file, line):
            "expected throw at \(file):\(line)"
        }
    }
}

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    guard actual == expected else {
        throw TestFailure.expectedEqual("\(actual)", "\(expected)", file: file, line: line)
    }
}

private func expectTrue(
    _ expression: @autoclosure () -> Bool,
    _ expressionDescription: String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    guard expression() else {
        throw TestFailure.expectedTrue(expressionDescription, file: file, line: line)
    }
}

private func expectThrows(
    _ body: () throws -> Void,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    do {
        try body()
    } catch {
        return
    }
    throw TestFailure.expectedThrow(file: file, line: line)
}

private func testStartClampsVolumeAboveLimit() throws {
    let audio = FakeAudioHardware(volume: 75)
    let engine = try makeEngine(audio: audio, config: VolumeLimiterConfig.default)

    try engine.start()

    try expectEqual(audio.setVolumeCalls, [50])
    try expectEqual(audio.volume, 50)
}

private func testVolumeChangeCallbackClampsImmediately() throws {
    let audio = FakeAudioHardware(volume: 20)
    let engine = try makeEngine(audio: audio, config: VolumeLimiterConfig.default)

    try engine.start()
    audio.emitVolumeChange(volume: 80)

    try expectEqual(audio.setVolumeCalls, [50])
    try expectEqual(audio.volume, 50)
}

private func testBluetoothOnlySkipsNonBluetoothDevices() throws {
    let audio = FakeAudioHardware(volume: 90, isBluetooth: false)
    let config = try VolumeLimiterConfig(bluetoothOnly: true)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.setVolumeCalls, [])
    try expectEqual(audio.volume, 90)
}

private func testBluetoothOnlyClampsBluetoothDevices() throws {
    let audio = FakeAudioHardware(volume: 90, isBluetooth: true)
    let config = try VolumeLimiterConfig(bluetoothOnly: true)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.setVolumeCalls, [50])
    try expectEqual(audio.volume, 50)
}

private func testInvalidLimitIsRejected() throws {
    let audio = FakeAudioHardware(volume: 30)
    let engine = try makeEngine(audio: audio, config: VolumeLimiterConfig.default)

    try expectThrows {
        try engine.setLimit(101)
    }
}

private func testDisabledLimiterDoesNotClamp() throws {
    let audio = FakeAudioHardware(volume: 80)
    let config = try VolumeLimiterConfig(enabled: false)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.setVolumeCalls, [])
    try expectEqual(audio.volume, 80)
}

private func testRequestAndResponseCodableRoundTrip() throws {
    let request = IPCRequest(id: "req-1", cmd: IPCCommand.setLimit.rawValue, value: 30)
    let requestData = try JSONEncoder().encode(request)
    let decodedRequest = try JSONDecoder().decode(IPCRequest.self, from: requestData)
    try expectEqual(decodedRequest, request)

    let response = IPCResponse(
        ok: true,
        id: "req-1",
        enabled: true,
        limit: 30,
        currentVolume: 24,
        deviceName: "MacBook Pro Speakers",
        bluetoothOnly: false,
        volumeControlAvailable: true,
        diagnostics: []
    )
    let responseData = try JSONEncoder().encode(response)
    let decodedResponse = try JSONDecoder().decode(IPCResponse.self, from: responseData)
    try expectEqual(decodedResponse, response)
}

private func testUnixSocketServerHandlesOneLineJSONRequests() throws {
    let socketPath = temporarySocketPath()
    let server = UnixSocketServer(path: socketPath) { request in
        do {
            try expectEqual(request.cmd, IPCCommand.ping.rawValue)
        } catch {
            return IPCResponse.failure(id: request.id, code: "testFailure", message: "\(error)")
        }
        return IPCResponse.success(id: request.id)
    }
    try server.start()
    defer { server.stop() }

    let client = UnixSocketClient(path: socketPath)
    let response = try client.send(IPCRequest(id: "ping-1", cmd: IPCCommand.ping.rawValue))

    try expectTrue(response.ok, "response.ok")
    try expectEqual(response.id, "ping-1")
}

private func testServerRejectsInvalidJSON() throws {
    let socketPath = temporarySocketPath()
    let server = UnixSocketServer(path: socketPath) { _ in
        IPCResponse.failure(id: "unexpected", code: "testFailure", message: "handler should not be called")
    }
    try server.start()
    defer { server.stop() }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try expectTrue(fd >= 0, "socket fd")
    defer { close(fd) }

    try connectForTest(fd: fd, path: socketPath)
    "{invalid-json}\n".data(using: .utf8)!.withUnsafeBytes { buffer in
        _ = write(fd, buffer.baseAddress, buffer.count)
    }

    let line = try readLineForTest(fd: fd)
    let response = try JSONDecoder().decode(IPCResponse.self, from: Data(line.utf8))
    try expectTrue(!response.ok, "!response.ok")
    try expectEqual(response.error?.code, "invalidRequest")
}

private func testCLISetSendsSetLimitRequest() throws {
    let client = FakeCLIClient(
        responses: [
            IPCResponse(ok: true, id: "fixed-id", enabled: true, limit: 30)
        ]
    )
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["set", "30"])

    try expectEqual(output.exitCode, 0)
    try expectEqual(output.stdout, "Limit set to 30%.\n")
    try expectEqual(client.requests, [
        IPCRequest(id: "fixed-id", cmd: IPCCommand.setLimit.rawValue, value: 30)
    ])
}

private func testCLIGetRendersCompactStatus() throws {
    let client = FakeCLIClient(
        responses: [
            IPCResponse(
                ok: true,
                id: "fixed-id",
                enabled: true,
                limit: 45,
                currentVolume: 12,
                deviceName: "Fake Speakers",
                bluetoothOnly: false
            )
        ]
    )
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["get"])

    try expectEqual(output.exitCode, 0)
    try expectTrue(output.stdout.contains("Limit: 45%"), "Limit line")
    try expectTrue(output.stdout.contains("Current volume: 12%"), "Current volume line")
    try expectTrue(output.stdout.contains("Device: Fake Speakers"), "Device line")
    try expectEqual(client.requests, [
        IPCRequest(id: "fixed-id", cmd: IPCCommand.getStatus.rawValue)
    ])
}

private func testCLIRejectsInvalidLimit() throws {
    let client = FakeCLIClient(responses: [])
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["set", "101"])

    try expectEqual(output.exitCode, 64)
    try expectTrue(output.stderr.contains("Volume limit must be an integer in 0...100."), "invalid limit message")
    try expectEqual(client.requests, [])
}

private func testCLIMapsDaemonConnectionFailure() throws {
    let client = FakeCLIClient(error: UnixSocketError.systemCall("connect", ENOENT))
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["status"])

    try expectEqual(output.exitCode, 69)
    try expectTrue(output.stderr.contains("volume-limiterd is not running."), "daemon unavailable message")
}

private func makeEngine(
    audio: FakeAudioHardware,
    config: VolumeLimiterConfig
) throws -> VolumeLimiterEngine {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("config.json")
    let store = VolumeLimiterConfigStore(fileURL: url)
    try store.save(config)
    return try VolumeLimiterEngine(audio: audio, configStore: store)
}

private final class FakeAudioHardware: AudioHardwareControlling {
    var deviceID: AudioDeviceIdentifier = 1
    var volume: Int
    var isBluetooth: Bool
    var volumeControlAvailable: Bool
    var setVolumeCalls: [Int] = []
    private var volumeChanged: ((AudioDeviceIdentifier) -> Void)?
    private var defaultDeviceChanged: ((AudioDeviceIdentifier) -> Void)?

    init(volume: Int, isBluetooth: Bool = false, volumeControlAvailable: Bool = true) {
        self.volume = volume
        self.isBluetooth = isBluetooth
        self.volumeControlAvailable = volumeControlAvailable
    }

    func defaultOutputDevice() throws -> AudioDeviceIdentifier {
        deviceID
    }

    func outputDeviceSnapshot(for deviceID: AudioDeviceIdentifier) throws -> OutputDeviceSnapshot {
        OutputDeviceSnapshot(
            id: deviceID,
            name: "Fake Speakers",
            currentVolume: volume,
            volumeControlAvailable: volumeControlAvailable,
            isBluetooth: isBluetooth
        )
    }

    func setOutputVolume(deviceID: AudioDeviceIdentifier, percent: Int) throws {
        volume = percent
        setVolumeCalls.append(percent)
    }

    func startMonitoring(
        defaultDeviceChanged: @escaping (AudioDeviceIdentifier) -> Void,
        volumeChanged: @escaping (AudioDeviceIdentifier) -> Void
    ) throws {
        self.defaultDeviceChanged = defaultDeviceChanged
        self.volumeChanged = volumeChanged
    }

    func stopMonitoring() {}

    func emitVolumeChange(volume: Int) {
        self.volume = volume
        volumeChanged?(deviceID)
    }
}

private final class FakeCLIClient: VolumeLimiterClientSending {
    private var responses: [IPCResponse]
    private let error: Error?
    private(set) var requests: [IPCRequest] = []

    init(responses: [IPCResponse], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    convenience init(error: Error) {
        self.init(responses: [], error: error)
    }

    func send(_ request: IPCRequest) throws -> IPCResponse {
        requests.append(request)
        if let error {
            throw error
        }
        guard !responses.isEmpty else {
            return IPCResponse.failure(id: request.id, code: "testFailure", message: "missing fake response")
        }
        return responses.removeFirst()
    }
}

private func temporarySocketPath() -> String {
    let suffix = UUID().uuidString.prefix(8)
    return "/tmp/vl-\(suffix).sock"
}

private func connectForTest(fd: Int32, path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
            for byteOffset in 0..<pathBytes.count {
                destination[byteOffset] = CChar(bitPattern: pathBytes[byteOffset])
            }
            destination[pathBytes.count] = 0
        }
    }

    try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            if connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size)) != 0 {
                throw UnixSocketError.systemCall("connect", errno)
            }
        }
    }
}

private func readLineForTest(fd: Int32) throws -> String {
    var data = Data()
    var byte = UInt8(0)
    while true {
        let result = read(fd, &byte, 1)
        if result <= 0 {
            throw UnixSocketError.disconnected
        }
        if byte == 0x0A {
            break
        }
        data.append(byte)
    }
    return String(data: data, encoding: .utf8)!
}
