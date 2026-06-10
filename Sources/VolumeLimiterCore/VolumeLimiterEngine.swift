import Foundation

public struct VolumeLimiterStatus: Codable, Equatable {
    public var enabled: Bool
    public var limit: Int
    public var currentVolume: Int?
    public var deviceName: String
    public var bluetoothOnly: Bool
    public var notifyOnLimit: Bool
    public var deviceIsBluetooth: Bool
    public var volumeControlAvailable: Bool
    public var diagnostics: [AudioDiagnostic]

    public init(
        enabled: Bool,
        limit: Int,
        currentVolume: Int?,
        deviceName: String,
        bluetoothOnly: Bool,
        notifyOnLimit: Bool,
        deviceIsBluetooth: Bool,
        volumeControlAvailable: Bool,
        diagnostics: [AudioDiagnostic]
    ) {
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
}

public protocol VolumeLimitNotifying: AnyObject {
    func volumeWasLimited(from currentVolume: Int, to limit: Int, deviceName: String)
}

public final class NoopVolumeLimitNotifier: VolumeLimitNotifying {
    public init() {}

    public func volumeWasLimited(from currentVolume: Int, to limit: Int, deviceName: String) {}
}

public final class VolumeLimiterEngine {
    private let audio: AudioHardwareControlling
    private let configStore: VolumeLimiterConfigStore
    private let notifier: VolumeLimitNotifying
    private let lock = NSRecursiveLock()
    private var config: VolumeLimiterConfig
    private var runtimeDiagnostics: [AudioDiagnostic] = []

    public init(
        audio: AudioHardwareControlling,
        configStore: VolumeLimiterConfigStore = VolumeLimiterConfigStore(),
        notifier: VolumeLimitNotifying = NoopVolumeLimitNotifier()
    ) throws {
        self.audio = audio
        self.configStore = configStore
        self.notifier = notifier
        self.config = try configStore.load()
    }

    deinit {
        audio.stopMonitoring()
    }

    public func start() throws {
        lock.withLock {
            runtimeDiagnostics.removeAll()
        }
        try audio.startMonitoring(
            defaultDeviceChanged: { [weak self] _ in
                self?.handleAudioEvent(reason: "defaultOutputDeviceChanged")
            },
            volumeChanged: { [weak self] _ in
                self?.handleAudioEvent(reason: "outputVolumeChanged")
            }
        )
        try enforceLimitNow(reason: "startup")
    }

    public func stop() {
        audio.stopMonitoring()
    }

    @discardableResult
    public func setLimit(_ value: Int) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        config.limit = try VolumeLimiterConfig.validatedLimit(value)
        try configStore.save(config)
        try enforceLimitLocked(reason: "setLimit")
        return statusLocked()
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        config.enabled = enabled
        try configStore.save(config)
        if enabled {
            try enforceLimitLocked(reason: "setEnabled")
        }
        return statusLocked()
    }

    @discardableResult
    public func setBluetoothOnly(_ bluetoothOnly: Bool) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        config.bluetoothOnly = bluetoothOnly
        try configStore.save(config)
        try enforceLimitLocked(reason: "setBluetoothOnly")
        return statusLocked()
    }

    @discardableResult
    public func setNotifyOnLimit(_ notifyOnLimit: Bool) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        config.notifyOnLimit = notifyOnLimit
        try configStore.save(config)
        return statusLocked()
    }

    @discardableResult
    public func enforceLimitNow(reason: String) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        try enforceLimitLocked(reason: reason)
        return statusLocked()
    }

    public func status() -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked()
    }

    private func handleAudioEvent(reason: String) {
        do {
            try enforceLimitNow(reason: reason)
        } catch {
            appendDiagnostic(
                AudioDiagnostic(
                    code: "enforcementFailed",
                    message: "\(reason): \(error.localizedDescription)"
                )
            )
        }
    }

    private func enforceLimitLocked(reason _: String) throws {
        guard config.enabled else {
            return
        }

        let deviceID = try audio.defaultOutputDevice()
        let snapshot = try audio.outputDeviceSnapshot(for: deviceID)

        guard !config.bluetoothOnly || snapshot.isBluetooth else {
            return
        }

        guard snapshot.volumeControlAvailable else {
            appendDiagnostic(
                AudioDiagnostic(
                    code: "volumeControlUnavailable",
                    message: "Current output device does not expose a writable output volume."
                )
            )
            return
        }

        guard let currentVolume = snapshot.currentVolume else {
            appendDiagnostic(
                AudioDiagnostic(
                    code: "currentVolumeUnavailable",
                    message: "Current output volume could not be read."
                )
            )
            return
        }

        if currentVolume > config.limit {
            try audio.setOutputVolume(deviceID: deviceID, percent: config.limit)
            if config.notifyOnLimit {
                notifier.volumeWasLimited(
                    from: currentVolume,
                    to: config.limit,
                    deviceName: snapshot.name
                )
            }
        }
    }

    private func statusLocked() -> VolumeLimiterStatus {
        do {
            let deviceID = try audio.defaultOutputDevice()
            let snapshot = try audio.outputDeviceSnapshot(for: deviceID)
            return VolumeLimiterStatus(
                enabled: config.enabled,
                limit: config.limit,
                currentVolume: snapshot.currentVolume,
                deviceName: snapshot.name,
                bluetoothOnly: config.bluetoothOnly,
                notifyOnLimit: config.notifyOnLimit,
                deviceIsBluetooth: snapshot.isBluetooth,
                volumeControlAvailable: snapshot.volumeControlAvailable,
                diagnostics: snapshot.diagnostics + runtimeDiagnostics
            )
        } catch {
            return VolumeLimiterStatus(
                enabled: config.enabled,
                limit: config.limit,
                currentVolume: nil,
                deviceName: "Unavailable",
                bluetoothOnly: config.bluetoothOnly,
                notifyOnLimit: config.notifyOnLimit,
                deviceIsBluetooth: false,
                volumeControlAvailable: false,
                diagnostics: runtimeDiagnostics + [
                    AudioDiagnostic(
                        code: "statusUnavailable",
                        message: error.localizedDescription
                    )
                ]
            )
        }
    }

    private func appendDiagnostic(_ diagnostic: AudioDiagnostic) {
        lock.lock()
        defer { lock.unlock() }
        runtimeDiagnostics.append(diagnostic)
        if runtimeDiagnostics.count > 16 {
            runtimeDiagnostics.removeFirst(runtimeDiagnostics.count - 16)
        }
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
