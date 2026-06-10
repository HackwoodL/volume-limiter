import Darwin
import Dispatch
import Foundation
import VolumeLimiterCore
import VolumeLimiterIPC

private let socketPath = VolumeLimiterIPC.defaultSocketPath()
private let engine: VolumeLimiterEngine

do {
    engine = try VolumeLimiterEngine(
        audio: CoreAudioHardware(),
        notifier: AppleScriptVolumeLimitNotifier()
    )
} catch {
    fputs("volume-limiterd: failed to initialize engine: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let server = UnixSocketServer(path: socketPath) { request in
    handle(request: request, engine: engine)
}

do {
    try engine.start()
    try server.start()
    print("volume-limiterd listening on \(socketPath)")
} catch {
    fputs("volume-limiterd: failed to start: \(error.localizedDescription)\n", stderr)
    engine.stop()
    server.stop()
    exit(1)
}

let shutdownSemaphore = DispatchSemaphore(value: 0)
installSignalHandler(SIGINT, semaphore: shutdownSemaphore)
installSignalHandler(SIGTERM, semaphore: shutdownSemaphore)

shutdownSemaphore.wait()
engine.stop()
server.stop()

private func installSignalHandler(_ signalNumber: Int32, semaphore: DispatchSemaphore) {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    source.setEventHandler {
        semaphore.signal()
    }
    source.resume()
}

private func handle(request: IPCRequest, engine: VolumeLimiterEngine) -> IPCResponse {
    guard request.version == VolumeLimiterIPC.version else {
        return .failure(
            id: request.id,
            code: "unsupportedVersion",
            message: IPCProtocolError.unsupportedVersion(request.version).localizedDescription
        )
    }

    guard let command = request.command else {
        return .failure(
            id: request.id,
            code: "unknownCommand",
            message: IPCProtocolError.unknownCommand(request.cmd).localizedDescription
        )
    }

    do {
        switch command {
        case .ping:
            return .success(id: request.id)
        case .getStatus:
            return response(id: request.id, status: engine.status())
        case .setLimit:
            guard let value = request.value else {
                return missingArgumentResponse(id: request.id, argument: "value")
            }
            guard (0...100).contains(value) else {
                return invalidArgumentResponse(id: request.id, message: "value must be an integer in 0...100")
            }
            return response(id: request.id, status: try engine.setLimit(value))
        case .setEnabled:
            guard let enabled = request.enabled else {
                return missingArgumentResponse(id: request.id, argument: "enabled")
            }
            return response(id: request.id, status: try engine.setEnabled(enabled))
        case .setHeadphoneOnly:
            guard let enabled = request.enabled else {
                return missingArgumentResponse(id: request.id, argument: "enabled")
            }
            return response(id: request.id, status: try engine.setHeadphoneOnly(enabled))
        case .setNotifyOnLimit:
            guard let enabled = request.enabled else {
                return missingArgumentResponse(id: request.id, argument: "enabled")
            }
            return response(id: request.id, status: try engine.setNotifyOnLimit(enabled))
        }
    } catch {
        return .failure(id: request.id, code: "commandFailed", message: error.localizedDescription)
    }
}

private func response(id: String, status: VolumeLimiterStatus) -> IPCResponse {
    IPCResponse(
        ok: true,
        id: id,
        enabled: status.enabled,
        limit: status.limit,
        currentVolume: status.currentVolume,
        deviceName: status.deviceName,
        headphoneOnly: status.headphoneOnly,
        notifyOnLimit: status.notifyOnLimit,
        deviceIsHeadphone: status.deviceIsHeadphone,
        volumeControlAvailable: status.volumeControlAvailable,
        diagnostics: status.diagnostics.map { "\($0.code): \($0.message)" }
    )
}

private func missingArgumentResponse(id: String, argument: String) -> IPCResponse {
    .failure(
        id: id,
        code: "missingArgument",
        message: IPCProtocolError.missingArgument(argument).localizedDescription
    )
}

private func invalidArgumentResponse(id: String, message: String) -> IPCResponse {
    .failure(
        id: id,
        code: "invalidArgument",
        message: IPCProtocolError.invalidArgument(message).localizedDescription
    )
}
