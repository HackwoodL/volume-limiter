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
    /// Cached "what to clamp to" so the hot path can skip the heavy device
    /// snapshot. Refreshed by the full enforce path on device/config changes; nil
    /// means "don't clamp" (disabled, headphone-only miss, or no volume control).
    private var activeEnforcement: (deviceID: AudioDeviceIdentifier, limit: Int, deviceName: String)?
    private var lastNotifyAt: Date?

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
                self?.handleVolumeEvent()
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

    /// Decides whether a hardware "volume up" key press should be swallowed by the
    /// key interceptor instead of reaching the system.
    ///
    /// Reactively clamping the volume after the fact cannot stop the audible burst
    /// on some Bluetooth devices: macOS's volume-key handler keeps its own counter
    /// that runs away to 100% during rapid presses, driving the device past the cap
    /// for a few milliseconds on every press. The only reliable fix is to stop the
    /// key from reaching that handler once we are already at the cap, so the counter
    /// never climbs. Returns true when we are actively capping the current device
    /// and the volume is already at (or above) the cap.
    public func shouldSwallowVolumeUp() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let enforcement = activeEnforcement else {
            return false
        }
        let current = audio.currentOutputVolumePercent(deviceID: enforcement.deviceID) ?? enforcement.limit
        guard current >= enforcement.limit else {
            return false
        }
        if current > enforcement.limit {
            try? audio.setOutputVolume(deviceID: enforcement.deviceID, percent: enforcement.limit)
        }
        // Give feedback that the volume-up was blocked at the cap. Without this the
        // swallowed key produces no volume change, so the notification path would
        // otherwise stay silent while the user keeps pressing. Throttled.
        maybeNotifyLocked(from: current, to: enforcement.limit, deviceName: enforcement.deviceName)
        return true
    }

    private func handleAudioEvent(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try enforceLimitLocked(reason: reason)
        } catch {
            appendDiagnosticLocked(
                AudioDiagnostic(
                    code: "enforcementFailed",
                    message: "\(reason): \(error.localizedDescription)"
                )
            )
        }
    }

    /// Hot path: runs on every volume-change notification. Does the minimum work
    /// (one lightweight volume read + a set if over the cap) using the cached
    /// enforcement context, so it keeps up with rapid volume-key presses and the
    /// volume only ever overshoots by ~one step instead of stacking toward 100%.
    private func handleVolumeEvent() {
        lock.lock()
        defer { lock.unlock() }

        guard let enforcement = activeEnforcement else {
            return
        }
        guard
            let current = audio.currentOutputVolumePercent(deviceID: enforcement.deviceID),
            current > enforcement.limit
        else {
            return
        }
        do {
            try audio.setOutputVolume(deviceID: enforcement.deviceID, percent: enforcement.limit)
            maybeNotifyLocked(from: current, to: enforcement.limit, deviceName: enforcement.deviceName)
        } catch {
            appendDiagnosticLocked(
                AudioDiagnostic(
                    code: "enforcementFailed",
                    message: "outputVolumeChanged: \(error.localizedDescription)"
                )
            )
        }
    }

    private func enforceLimitLocked(reason _: String) throws {
        guard config.enabled else {
            activeEnforcement = nil
            return
        }

        let deviceID = try audio.defaultOutputDevice()
        let snapshot = try audio.outputDeviceSnapshot(for: deviceID)

        guard !config.headphoneOnly || snapshot.isHeadphoneOutput else {
            activeEnforcement = nil
            return
        }

        guard snapshot.volumeControlAvailable else {
            activeEnforcement = nil
            appendDiagnosticLocked(
                AudioDiagnostic(
                    code: "volumeControlUnavailable",
                    message: "Current output device does not expose a writable output volume."
                )
            )
            return
        }

        let override = config.deviceLimitsEnabled
            ? config.deviceLimit(forKey: deviceKey(for: snapshot), name: snapshot.name)
            : nil
        let effectiveLimit = override?.limit ?? config.limit

        // Cache for the hot path before clamping, so volume events can be handled
        // cheaply even if the current volume can't be read right now.
        activeEnforcement = (deviceID: deviceID, limit: effectiveLimit, deviceName: snapshot.name)

        guard let currentVolume = snapshot.currentVolume else {
            appendDiagnosticLocked(
                AudioDiagnostic(
                    code: "currentVolumeUnavailable",
                    message: "Current output volume could not be read."
                )
            )
            return
        }

        if currentVolume > effectiveLimit {
            try audio.setOutputVolume(deviceID: deviceID, percent: effectiveLimit)
            maybeNotifyLocked(from: currentVolume, to: effectiveLimit, deviceName: snapshot.name)
        }
    }

    /// Notifies that the volume was capped, throttled so rapid key-repeat clamps
    /// don't produce a flood of notifications.
    private func maybeNotifyLocked(from currentVolume: Int, to limit: Int, deviceName: String) {
        guard config.notifyOnLimit else {
            return
        }
        let now = Date()
        if let last = lastNotifyAt, now.timeIntervalSince(last) < 5 {
            return
        }
        lastNotifyAt = now
        notifier.volumeWasLimited(from: currentVolume, to: limit, deviceName: deviceName)
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

    private func appendDiagnosticLocked(_ diagnostic: AudioDiagnostic) {
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
