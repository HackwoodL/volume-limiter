import Foundation

public struct VolumeLimiterStatus: Codable, Equatable {
    public var enabled: Bool
    public var limit: Int
    public var defaultLimit: Int
    public var deviceLimitsEnabled: Bool
    public var currentVolume: Int?
    public var deviceName: String
    public var deviceUID: String?
    public var deviceHasLimitOverride: Bool
    public var headphoneOnly: Bool
    public var notifyOnLimit: Bool
    public var deviceIsHeadphone: Bool
    public var volumeControlAvailable: Bool
    public var diagnostics: [AudioDiagnostic]
    public var deviceLimits: [String: DeviceLimit]
    public var connectedDevices: [OutputDeviceRef]

    public init(
        enabled: Bool,
        limit: Int,
        defaultLimit: Int,
        deviceLimitsEnabled: Bool = false,
        currentVolume: Int?,
        deviceName: String,
        deviceUID: String? = nil,
        deviceHasLimitOverride: Bool = false,
        headphoneOnly: Bool,
        notifyOnLimit: Bool,
        deviceIsHeadphone: Bool,
        volumeControlAvailable: Bool,
        diagnostics: [AudioDiagnostic],
        deviceLimits: [String: DeviceLimit] = [:],
        connectedDevices: [OutputDeviceRef] = []
    ) {
        self.enabled = enabled
        self.limit = limit
        self.defaultLimit = defaultLimit
        self.deviceLimitsEnabled = deviceLimitsEnabled
        self.currentVolume = currentVolume
        self.deviceName = deviceName
        self.deviceUID = deviceUID
        self.deviceHasLimitOverride = deviceHasLimitOverride
        self.headphoneOnly = headphoneOnly
        self.notifyOnLimit = notifyOnLimit
        self.deviceIsHeadphone = deviceIsHeadphone
        self.volumeControlAvailable = volumeControlAvailable
        self.diagnostics = diagnostics
        self.deviceLimits = deviceLimits
        self.connectedDevices = connectedDevices
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

    /// Sets the default cap applied to every device without a per-device override.
    @discardableResult
    public func setLimit(_ value: Int) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        config.limit = try VolumeLimiterConfig.validatedLimit(value)
        try configStore.save(config)
        try enforceLimitLocked(reason: "setLimit")
        return statusLocked()
    }

    /// Enables or disables the per-device override feature as a whole.
    @discardableResult
    public func setDeviceLimitsEnabled(_ enabled: Bool) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        config.deviceLimitsEnabled = enabled
        try configStore.save(config)
        try enforceLimitLocked(reason: "setDeviceLimitsEnabled")
        return statusLocked()
    }

    /// Adds or updates a per-device cap override, keyed by the device's stable UID.
    @discardableResult
    public func setDeviceLimit(uid: String, name: String?, limit value: Int) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        let validated = try VolumeLimiterConfig.validatedLimit(value)
        let resolvedName = name ?? config.deviceLimits[uid]?.name ?? connectedDeviceName(forUID: uid)
        config.deviceLimits[uid] = DeviceLimit(limit: validated, name: resolvedName)
        try configStore.save(config)
        try enforceLimitLocked(reason: "setDeviceLimit")
        return statusLocked()
    }

    /// Removes a per-device override so the device falls back to the default cap.
    @discardableResult
    public func removeDeviceLimit(uid: String) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        if config.deviceLimits.removeValue(forKey: uid) != nil {
            try configStore.save(config)
            try enforceLimitLocked(reason: "removeDeviceLimit")
        }
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
    public func setHeadphoneOnly(_ headphoneOnly: Bool) throws -> VolumeLimiterStatus {
        lock.lock()
        defer { lock.unlock() }
        config.headphoneOnly = headphoneOnly
        try configStore.save(config)
        try enforceLimitLocked(reason: "setHeadphoneOnly")
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

        guard !config.headphoneOnly || snapshot.isHeadphoneOutput else {
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

        let override = config.deviceLimitsEnabled
            ? config.deviceLimit(forKey: deviceKey(for: snapshot), name: snapshot.name)
            : nil
        let effectiveLimit = override?.limit ?? config.limit
        if currentVolume > effectiveLimit {
            try audio.setOutputVolume(deviceID: deviceID, percent: effectiveLimit)
            if config.notifyOnLimit {
                notifier.volumeWasLimited(
                    from: currentVolume,
                    to: effectiveLimit,
                    deviceName: snapshot.name
                )
            }
        }
    }

    private func connectedDeviceName(forUID uid: String) -> String? {
        (try? audio.outputDeviceList())?.first(where: { $0.uid == uid })?.name
    }

    private func deviceKey(for snapshot: OutputDeviceSnapshot) -> String? {
        if let uid = snapshot.uid, !uid.isEmpty {
            return uid
        }
        return snapshot.name.isEmpty ? nil : "name:\(snapshot.name)"
    }

    private func statusLocked() -> VolumeLimiterStatus {
        let connectedDevices = (try? audio.outputDeviceList()) ?? []
        do {
            let deviceID = try audio.defaultOutputDevice()
            let snapshot = try audio.outputDeviceSnapshot(for: deviceID)
            let override = config.deviceLimitsEnabled
                ? config.deviceLimit(forKey: deviceKey(for: snapshot), name: snapshot.name)
                : nil
            return VolumeLimiterStatus(
                enabled: config.enabled,
                limit: override?.limit ?? config.limit,
                defaultLimit: config.limit,
                deviceLimitsEnabled: config.deviceLimitsEnabled,
                currentVolume: snapshot.currentVolume,
                deviceName: snapshot.name,
                deviceUID: snapshot.uid,
                deviceHasLimitOverride: override != nil,
                headphoneOnly: config.headphoneOnly,
                notifyOnLimit: config.notifyOnLimit,
                deviceIsHeadphone: snapshot.isHeadphoneOutput,
                volumeControlAvailable: snapshot.volumeControlAvailable,
                diagnostics: snapshot.diagnostics + runtimeDiagnostics,
                deviceLimits: config.deviceLimits,
                connectedDevices: connectedDevices
            )
        } catch {
            return VolumeLimiterStatus(
                enabled: config.enabled,
                limit: config.limit,
                defaultLimit: config.limit,
                deviceLimitsEnabled: config.deviceLimitsEnabled,
                currentVolume: nil,
                deviceName: "Unavailable",
                deviceUID: nil,
                deviceHasLimitOverride: false,
                headphoneOnly: config.headphoneOnly,
                notifyOnLimit: config.notifyOnLimit,
                deviceIsHeadphone: false,
                volumeControlAvailable: false,
                diagnostics: runtimeDiagnostics + [
                    AudioDiagnostic(
                        code: "statusUnavailable",
                        message: error.localizedDescription
                    )
                ],
                deviceLimits: config.deviceLimits,
                connectedDevices: connectedDevices
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
