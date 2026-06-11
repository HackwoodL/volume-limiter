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
        try suite.run("Core headphone-only skips speaker devices", testHeadphoneOnlySkipsSpeakerDevices)
        try suite.run("Core headphone-only clamps Bluetooth headphones", testHeadphoneOnlyClampsBluetoothHeadphones)
        try suite.run("Core headphone-only clamps wired headphones", testHeadphoneOnlyClampsWiredHeadphones)
        try suite.run("Core rejects invalid limit", testInvalidLimitIsRejected)
        try suite.run("Core disabled limiter does not clamp", testDisabledLimiterDoesNotClamp)
        try suite.run("Core rapid volume changes each clamp via fast path", testRapidVolumeChangesClampEachTime)
        try suite.run("Core swallows volume-up key at the cap", testInterceptorSwallowsVolumeUpAtCap)
        try suite.run("Core passes volume-up key below the cap", testInterceptorPassesVolumeUpBelowCap)
        try suite.run("Core passes volume-up key when disabled", testInterceptorPassesVolumeUpWhenDisabled)
        try suite.run("Core re-asserts cap when over before swallowing", testInterceptorReassertsCapWhenOver)
        try suite.run("Core notifies when a volume-up key is swallowed at the cap", testInterceptorNotifiesWhenSwallowing)
        try suite.run("Core does not notify on swallow when notify disabled", testInterceptorSwallowSilentWhenNotifyOff)
        try suite.run("Core notifies when limit is enforced", testNotifyOnLimit)
        try suite.run("Core notify is throttled under rapid clamps", testNotifyThrottledUnderRapidClamps)
        try suite.run("Core does not notify when notify disabled", testNotifyDisabled)
        try suite.run("Core config store persists settings", testConfigStorePersistsSettings)
        try suite.run("Core per-device override clamps to device limit", testPerDeviceOverrideClampsToDeviceLimit)
        try suite.run("Core per-device override ignored when disabled", testPerDeviceOverrideIgnoredWhenDisabled)
        try suite.run("Core setDeviceLimitsEnabled toggles enforcement", testSetDeviceLimitsEnabledTogglesEnforcement)
        try suite.run("Core default limit applies without override", testDefaultLimitAppliesWhenNoDeviceOverride)
        try suite.run("Core setLimit sets the default cap", testSetLimitSetsDefault)
        try suite.run("Core setDeviceLimit clamps immediately", testSetDeviceLimitClampsImmediately)
        try suite.run("Core device override beats default", testDeviceOverrideBeatsDefault)
        try suite.run("Core remove device limit falls back to default", testRemoveDeviceLimitFallsBackToDefault)
        try suite.run("Core name fallback when UID changes", testNameFallbackWhenUIDChanges)
        try suite.run("Core config persists device limits", testConfigStorePersistsDeviceLimits)
        try suite.run("Core config decodes legacy JSON", testConfigDecodesLegacyJSONWithoutDeviceLimits)
        try suite.run("Core config resolvedLimit resolution", testConfigResolvedLimit)
        try suite.run("IPC request/response Codable round trip", testRequestAndResponseCodableRoundTrip)
        try suite.run("IPC Unix socket handles newline JSON", testUnixSocketServerHandlesOneLineJSONRequests)
        try suite.run("IPC server returns structured error for invalid JSON", testServerRejectsInvalidJSON)
        try suite.run("IPC rejects active duplicate socket server", testUnixSocketServerRejectsDuplicateActiveServer)
        try suite.run("CLI set sends setLimit request", testCLISetSendsSetLimitRequest)
        try suite.run("CLI status renders daemon status", testCLIStatusRendersDaemonStatus)
        try suite.run("CLI rejects invalid limit locally", testCLIRejectsInvalidLimit)
        try suite.run("CLI maps daemon connection failure", testCLIMapsDaemonConnectionFailure)
        try suite.run("CLI talks to server over Unix socket", testCLITalksToServerOverUnixSocket)
        try suite.run("CLI device set sends setDeviceLimit", testCLIDeviceSetSendsSetDeviceLimit)
        try suite.run("CLI device remove sends removeDeviceLimit", testCLIDeviceRemoveSendsRemoveDeviceLimit)
        try suite.run("CLI device on enables per-device caps", testCLIDeviceOnSendsSetDeviceLimitsEnabled)
        try suite.run("CLI device list renders overrides", testCLIDeviceListRendersOverrides)

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

private func testHeadphoneOnlySkipsSpeakerDevices() throws {
    let audio = FakeAudioHardware(volume: 90, isHeadphoneOutput: false)
    let config = try VolumeLimiterConfig(headphoneOnly: true)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.setVolumeCalls, [])
    try expectEqual(audio.volume, 90)
}

private func testHeadphoneOnlyClampsBluetoothHeadphones() throws {
    let audio = FakeAudioHardware(volume: 90, isHeadphoneOutput: true)
    let config = try VolumeLimiterConfig(headphoneOnly: true)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.setVolumeCalls, [50])
    try expectEqual(audio.volume, 50)
}

private func testHeadphoneOnlyClampsWiredHeadphones() throws {
    let audio = FakeAudioHardware(volume: 90, isHeadphoneOutput: true)
    audio.deviceName = "Poly Blackwire 3325 Series"
    let config = try VolumeLimiterConfig(headphoneOnly: true)
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

private func testInterceptorSwallowsVolumeUpAtCap() throws {
    let audio = FakeAudioHardware(volume: 80)
    let config = try VolumeLimiterConfig(limit: 40)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start() // clamps to 40; now sitting at the cap

    try expectTrue(engine.shouldSwallowVolumeUp(), "at the cap the volume-up key must be swallowed")
}

private func testInterceptorPassesVolumeUpBelowCap() throws {
    let audio = FakeAudioHardware(volume: 80)
    let config = try VolumeLimiterConfig(limit: 40)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()
    audio.volume = 25 // below the cap

    try expectEqual(engine.shouldSwallowVolumeUp(), false)
}

private func testInterceptorPassesVolumeUpWhenDisabled() throws {
    let audio = FakeAudioHardware(volume: 80)
    let config = try VolumeLimiterConfig(enabled: false, limit: 40)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(engine.shouldSwallowVolumeUp(), false)
}

private func testInterceptorReassertsCapWhenOver() throws {
    let audio = FakeAudioHardware(volume: 80)
    let config = try VolumeLimiterConfig(limit: 40)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()
    audio.setVolumeCalls.removeAll()
    audio.volume = 90 // a spike sneaks above the cap at decision time

    try expectTrue(engine.shouldSwallowVolumeUp(), "over the cap still swallows")
    try expectEqual(audio.volume, 40)
    try expectEqual(audio.setVolumeCalls, [40])
}

private func testInterceptorNotifiesWhenSwallowing() throws {
    let audio = FakeAudioHardware(volume: 40) // already at the cap
    let notifier = FakeNotifier()
    let config = try VolumeLimiterConfig(limit: 40, notifyOnLimit: true)
    let engine = try makeEngine(audio: audio, config: config, notifier: notifier)

    try engine.start() // at the cap, nothing to clamp, so no notification yet
    try expectEqual(notifier.events.count, 0)

    // Swallowing a volume-up at the cap should still tell the user it was blocked,
    // with a "held at the limit" event (from == to == the cap).
    try expectTrue(engine.shouldSwallowVolumeUp(), "swallow at cap")
    try expectEqual(notifier.events, [NotificationEvent(from: 40, to: 40, deviceName: "Fake Speakers")])
}

private func testInterceptorSwallowSilentWhenNotifyOff() throws {
    let audio = FakeAudioHardware(volume: 40)
    let notifier = FakeNotifier()
    let config = try VolumeLimiterConfig(limit: 40, notifyOnLimit: false)
    let engine = try makeEngine(audio: audio, config: config, notifier: notifier)

    try engine.start()
    try expectTrue(engine.shouldSwallowVolumeUp())
    try expectEqual(notifier.events, [])
}

private func testRapidVolumeChangesClampEachTime() throws {
    let audio = FakeAudioHardware(volume: 20)
    let config = try VolumeLimiterConfig(limit: 40)
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    // Simulate spamming volume-up: each press bumps the volume; the fast path
    // must clamp every one back to 40 (never letting it stack toward 100).
    for bump in [55, 62, 70, 90] {
        audio.emitVolumeChange(volume: bump)
    }

    try expectEqual(audio.volume, 40)
    try expectEqual(audio.setVolumeCalls, [40, 40, 40, 40])
}

private func testNotifyThrottledUnderRapidClamps() throws {
    let audio = FakeAudioHardware(volume: 20)
    let notifier = FakeNotifier()
    let config = try VolumeLimiterConfig(limit: 40, notifyOnLimit: true)
    let engine = try makeEngine(audio: audio, config: config, notifier: notifier)

    try engine.start()
    for bump in [60, 70, 80, 95] {
        audio.emitVolumeChange(volume: bump)
    }

    // Many clamps, but notifications are throttled to avoid a flood.
    try expectEqual(audio.volume, 40)
    try expectEqual(notifier.events.count, 1)
}

private func testNotifyOnLimit() throws {
    let audio = FakeAudioHardware(volume: 80)
    let notifier = FakeNotifier()
    let config = try VolumeLimiterConfig(limit: 40, notifyOnLimit: true)
    let engine = try makeEngine(audio: audio, config: config, notifier: notifier)

    try engine.start()

    try expectEqual(audio.volume, 40)
    try expectEqual(notifier.events, [
        NotificationEvent(from: 80, to: 40, deviceName: "Fake Speakers")
    ])
}

private func testNotifyDisabled() throws {
    let audio = FakeAudioHardware(volume: 80)
    let notifier = FakeNotifier()
    let config = try VolumeLimiterConfig(limit: 40, notifyOnLimit: false)
    let engine = try makeEngine(audio: audio, config: config, notifier: notifier)

    try engine.start()

    try expectEqual(audio.volume, 40)
    try expectEqual(notifier.events, [])
}

private func testConfigStorePersistsSettings() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("config.json")
    let store = VolumeLimiterConfigStore(fileURL: url)
    let config = try VolumeLimiterConfig(
        enabled: false,
        limit: 33,
        headphoneOnly: true,
        notifyOnLimit: true
    )

    try store.save(config)

    try expectEqual(try store.load(), config)
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
        headphoneOnly: false,
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

private func testUnixSocketServerRejectsDuplicateActiveServer() throws {
    let socketPath = temporarySocketPath()
    let firstServer = UnixSocketServer(path: socketPath) { request in
        IPCResponse.success(id: request.id)
    }
    try firstServer.start()
    defer { firstServer.stop() }

    let duplicateServer = UnixSocketServer(path: socketPath) { request in
        IPCResponse.success(id: request.id)
    }

    try expectThrows {
        try duplicateServer.start()
    }
}

private func testCLISetSendsSetLimitRequest() throws {
    let client = FakeCLIClient(
        responses: [
            IPCResponse(ok: true, id: "fixed-id", enabled: true, limit: 30, defaultLimit: 30)
        ]
    )
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["set", "30"])

    try expectEqual(output.exitCode, 0)
    try expectEqual(output.stdout, "Default limit set to 30%.\n")
    try expectEqual(client.requests, [
        IPCRequest(id: "fixed-id", cmd: IPCCommand.setLimit.rawValue, value: 30)
    ])
}

private func testCLIStatusRendersDaemonStatus() throws {
    let client = FakeCLIClient(
        responses: [
            IPCResponse(
                ok: true,
                id: "fixed-id",
                enabled: true,
                limit: 45,
                currentVolume: 12,
                deviceName: "Fake Speakers",
                headphoneOnly: false,
                notifyOnLimit: false,
                deviceIsHeadphone: false,
                volumeControlAvailable: true,
                diagnostics: [],
                defaultLimit: 45
            )
        ]
    )
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["status"])

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

private func testCLITalksToServerOverUnixSocket() throws {
    let socketPath = temporarySocketPath()
    var limit = 50
    let server = UnixSocketServer(path: socketPath) { request in
        switch request.command {
        case .setLimit:
            guard let value = request.value else {
                return IPCResponse.failure(id: request.id, code: "missingArgument", message: "missing value")
            }
            limit = value
            return fakeStatusResponse(id: request.id, limit: limit)
        case .getStatus:
            return fakeStatusResponse(id: request.id, limit: limit)
        default:
            return IPCResponse.failure(id: request.id, code: "unexpectedCommand", message: request.cmd)
        }
    }
    try server.start()
    defer { server.stop() }

    let runner = VolumeLimitCommandRunner(
        client: UnixSocketClient(path: socketPath),
        requestID: { UUID().uuidString }
    )

    let setOutput = runner.run(arguments: ["set", "42"])
    try expectEqual(setOutput.exitCode, 0)
    try expectEqual(setOutput.stdout, "Default limit set to 42%.\n")

    let statusOutput = runner.run(arguments: ["status"])
    try expectEqual(statusOutput.exitCode, 0)
    try expectTrue(statusOutput.stdout.contains("Limit: 42%"), "updated limit from socket server")
}

private func testPerDeviceOverrideClampsToDeviceLimit() throws {
    let audio = FakeAudioHardware(volume: 90)
    audio.uid = "uid-headphones"
    let config = try VolumeLimiterConfig(
        limit: 80,
        deviceLimitsEnabled: true,
        deviceLimits: ["uid-headphones": DeviceLimit(limit: 40, name: "Headphones")]
    )
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.setVolumeCalls, [40])
    try expectEqual(audio.volume, 40)
}

private func testPerDeviceOverrideIgnoredWhenDisabled() throws {
    let audio = FakeAudioHardware(volume: 90)
    audio.uid = "uid-headphones"
    let config = try VolumeLimiterConfig(
        limit: 80,
        deviceLimitsEnabled: false,
        deviceLimits: ["uid-headphones": DeviceLimit(limit: 40, name: "Headphones")]
    )
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.volume, 80)
}

private func testSetDeviceLimitsEnabledTogglesEnforcement() throws {
    let audio = FakeAudioHardware(volume: 90)
    audio.uid = "uid-x"
    let config = try VolumeLimiterConfig(
        limit: 80,
        deviceLimitsEnabled: false,
        deviceLimits: ["uid-x": DeviceLimit(limit: 40, name: "X")]
    )
    let engine = try makeEngine(audio: audio, config: config)
    try engine.start()
    try expectEqual(audio.volume, 80)

    _ = try engine.setDeviceLimitsEnabled(true)
    try expectEqual(audio.volume, 40)
}

private func testDefaultLimitAppliesWhenNoDeviceOverride() throws {
    let audio = FakeAudioHardware(volume: 90)
    audio.uid = "uid-speakers"
    let config = try VolumeLimiterConfig(
        limit: 55,
        deviceLimitsEnabled: true,
        deviceLimits: ["uid-headphones": DeviceLimit(limit: 40, name: "Headphones")]
    )
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.volume, 55)
}

private func testSetLimitSetsDefault() throws {
    let audio = FakeAudioHardware(volume: 10)
    audio.uid = "uid-x"
    let engine = try makeEngine(audio: audio, config: try VolumeLimiterConfig(limit: 50))

    let status = try engine.setLimit(65)

    try expectEqual(status.defaultLimit, 65)
    try expectTrue(status.deviceLimits.isEmpty, "setLimit does not create a per-device override")
}

private func testSetDeviceLimitClampsImmediately() throws {
    let audio = FakeAudioHardware(volume: 90)
    audio.uid = "uid-x"
    let engine = try makeEngine(audio: audio, config: try VolumeLimiterConfig(limit: 80, deviceLimitsEnabled: true))

    _ = try engine.setDeviceLimit(uid: "uid-x", name: "X", limit: 45)

    try expectEqual(audio.volume, 45)
    try expectEqual(engine.status().deviceLimits["uid-x"]?.limit, 45)
}

private func testDeviceOverrideBeatsDefault() throws {
    let audio = FakeAudioHardware(volume: 10)
    audio.uid = "uid-x"
    let engine = try makeEngine(audio: audio, config: try VolumeLimiterConfig(limit: 50, deviceLimitsEnabled: true))
    try engine.start()
    _ = try engine.setDeviceLimit(uid: "uid-x", name: "Headphones", limit: 40)

    let status = try engine.setLimit(70)

    try expectEqual(status.defaultLimit, 70)
    try expectEqual(status.limit, 40)

    audio.emitVolumeChange(volume: 90)
    try expectEqual(audio.volume, 40)
}

private func testRemoveDeviceLimitFallsBackToDefault() throws {
    let audio = FakeAudioHardware(volume: 10)
    audio.uid = "uid-x"
    let engine = try makeEngine(audio: audio, config: try VolumeLimiterConfig(limit: 55, deviceLimitsEnabled: true))
    _ = try engine.setDeviceLimit(uid: "uid-x", name: "Headphones", limit: 40)

    let status = try engine.removeDeviceLimit(uid: "uid-x")

    try expectTrue(!status.deviceHasLimitOverride, "override cleared")
    try expectEqual(status.limit, 55)
    try expectTrue(status.deviceLimits.isEmpty, "no overrides remain")
}

private func testNameFallbackWhenUIDChanges() throws {
    let audio = FakeAudioHardware(volume: 90)
    audio.uid = "uid-new"
    audio.deviceName = "Sony WH-1000XM5"
    let config = try VolumeLimiterConfig(
        limit: 80,
        deviceLimitsEnabled: true,
        deviceLimits: ["uid-old": DeviceLimit(limit: 35, name: "Sony WH-1000XM5")]
    )
    let engine = try makeEngine(audio: audio, config: config)

    try engine.start()

    try expectEqual(audio.volume, 35)
}

private func testConfigStorePersistsDeviceLimits() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("config.json")
    let store = VolumeLimiterConfigStore(fileURL: url)
    let config = try VolumeLimiterConfig(
        limit: 50,
        deviceLimits: [
            "uid-a": DeviceLimit(limit: 60, name: "A"),
            "uid-b": DeviceLimit(limit: 30, name: "B")
        ]
    )

    try store.save(config)

    try expectEqual(try store.load(), config)
}

private func testConfigDecodesLegacyJSONWithoutDeviceLimits() throws {
    let json = #"{"enabled": true, "limit": 42, "headphoneOnly": false, "notifyOnLimit": false}"#
    let config = try JSONDecoder().decode(VolumeLimiterConfig.self, from: Data(json.utf8))

    try expectEqual(config.limit, 42)
    try expectTrue(config.deviceLimits.isEmpty, "legacy config has no device limits")
}

private func testConfigResolvedLimit() throws {
    let config = try VolumeLimiterConfig(
        limit: 50,
        deviceLimits: ["uid-a": DeviceLimit(limit: 60, name: "A")]
    )

    try expectEqual(config.resolvedLimit(forKey: "uid-a", name: "A"), 60)
    try expectEqual(config.resolvedLimit(forKey: "uid-z", name: "A"), 60)
    try expectEqual(config.resolvedLimit(forKey: "uid-z", name: "Z"), 50)
}

private func testCLIDeviceSetSendsSetDeviceLimit() throws {
    let client = FakeCLIClient(responses: [
        IPCResponse(
            ok: true,
            id: "fixed-id",
            defaultLimit: 50,
            deviceLimits: [DeviceLimitEntry(uid: "uid-a", name: "Headphones", limit: 60)]
        )
    ])
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["device", "set", "uid-a", "60"])

    try expectEqual(output.exitCode, 0)
    try expectEqual(output.stdout, "Limit for Headphones set to 60%.\n")
    try expectEqual(client.requests, [
        IPCRequest(id: "fixed-id", cmd: IPCCommand.setDeviceLimit.rawValue, value: 60, deviceUID: "uid-a")
    ])
}

private func testCLIDeviceRemoveSendsRemoveDeviceLimit() throws {
    let client = FakeCLIClient(responses: [IPCResponse(ok: true, id: "fixed-id", defaultLimit: 50)])
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["device", "remove", "uid-a"])

    try expectEqual(output.exitCode, 0)
    try expectEqual(output.stdout, "Removed per-device limit for uid-a.\n")
    try expectEqual(client.requests, [
        IPCRequest(id: "fixed-id", cmd: IPCCommand.removeDeviceLimit.rawValue, deviceUID: "uid-a")
    ])
}

private func testCLIDeviceOnSendsSetDeviceLimitsEnabled() throws {
    let client = FakeCLIClient(responses: [IPCResponse(ok: true, id: "fixed-id", deviceLimitsEnabled: true)])
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["device", "on"])

    try expectEqual(output.exitCode, 0)
    try expectEqual(output.stdout, "Per-device caps are on.\n")
    try expectEqual(client.requests, [
        IPCRequest(id: "fixed-id", cmd: IPCCommand.setDeviceLimitsEnabled.rawValue, enabled: true)
    ])
}

private func testCLIDeviceListRendersOverrides() throws {
    let client = FakeCLIClient(responses: [
        IPCResponse(
            ok: true,
            id: "fixed-id",
            defaultLimit: 50,
            deviceLimits: [DeviceLimitEntry(uid: "uid-a", name: "Headphones", limit: 60)]
        )
    ])
    let runner = VolumeLimitCommandRunner(client: client, requestID: { "fixed-id" })

    let output = runner.run(arguments: ["device", "list"])

    try expectEqual(output.exitCode, 0)
    try expectTrue(output.stdout.contains("Default limit: 50%"), "default limit line")
    try expectTrue(output.stdout.contains("Headphones: 60%"), "device override line")
    try expectEqual(client.requests, [
        IPCRequest(id: "fixed-id", cmd: IPCCommand.getStatus.rawValue)
    ])
}

private func makeEngine(
    audio: FakeAudioHardware,
    config: VolumeLimiterConfig,
    notifier: VolumeLimitNotifying = NoopVolumeLimitNotifier()
) throws -> VolumeLimiterEngine {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("config.json")
    let store = VolumeLimiterConfigStore(fileURL: url)
    try store.save(config)
    return try VolumeLimiterEngine(audio: audio, configStore: store, notifier: notifier)
}

private final class FakeAudioHardware: AudioHardwareControlling {
    var deviceID: AudioDeviceIdentifier = 1
    var volume: Int
    var isHeadphoneOutput: Bool
    var volumeControlAvailable: Bool
    var deviceName: String = "Fake Speakers"
    var uid: String? = "uid-fake-speakers"
    var deviceList: [OutputDeviceRef]?
    var setVolumeCalls: [Int] = []
    private var volumeChanged: ((AudioDeviceIdentifier) -> Void)?
    private var defaultDeviceChanged: ((AudioDeviceIdentifier) -> Void)?

    init(volume: Int, isHeadphoneOutput: Bool = false, volumeControlAvailable: Bool = true) {
        self.volume = volume
        self.isHeadphoneOutput = isHeadphoneOutput
        self.volumeControlAvailable = volumeControlAvailable
    }

    func defaultOutputDevice() throws -> AudioDeviceIdentifier {
        deviceID
    }

    func outputDeviceSnapshot(for deviceID: AudioDeviceIdentifier) throws -> OutputDeviceSnapshot {
        OutputDeviceSnapshot(
            id: deviceID,
            uid: uid,
            name: deviceName,
            currentVolume: volume,
            volumeControlAvailable: volumeControlAvailable,
            isHeadphoneOutput: isHeadphoneOutput
        )
    }

    func outputDeviceList() throws -> [OutputDeviceRef] {
        deviceList ?? [OutputDeviceRef(uid: uid ?? "uid-fake", name: deviceName, isHeadphoneOutput: isHeadphoneOutput)]
    }

    func currentOutputVolumePercent(deviceID: AudioDeviceIdentifier) -> Int? {
        volume
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

private struct NotificationEvent: Equatable {
    var from: Int
    var to: Int
    var deviceName: String
}

private final class FakeNotifier: VolumeLimitNotifying {
    var events: [NotificationEvent] = []

    func volumeWasLimited(from currentVolume: Int, to limit: Int, deviceName: String) {
        events.append(NotificationEvent(from: currentVolume, to: limit, deviceName: deviceName))
    }
}

private func fakeStatusResponse(id: String, limit: Int) -> IPCResponse {
    IPCResponse(
        ok: true,
        id: id,
        enabled: true,
        limit: limit,
        currentVolume: 10,
        deviceName: "Fake Speakers",
        headphoneOnly: false,
        notifyOnLimit: false,
        deviceIsHeadphone: false,
        volumeControlAvailable: true,
        diagnostics: [],
        defaultLimit: limit
    )
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
