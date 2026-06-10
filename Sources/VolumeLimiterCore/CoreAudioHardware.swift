#if os(macOS)

import CoreAudio
import Foundation

public final class CoreAudioHardware: AudioHardwareControlling {
    private struct ListenerRegistration {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let listenerQueue = DispatchQueue(label: "com.volumelimiter.coreaudio.listeners")
    private let lock = NSRecursiveLock()
    private var defaultDeviceChanged: ((AudioDeviceIdentifier) -> Void)?
    private var volumeChanged: ((AudioDeviceIdentifier) -> Void)?
    private var defaultDeviceListener: ListenerRegistration?
    private var volumeListeners: [ListenerRegistration] = []
    private var monitoredDeviceID: AudioDeviceIdentifier?

    public init() {}

    public func defaultOutputDevice() throws -> AudioDeviceIdentifier {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceIdentifier(0)
        var size = UInt32(MemoryLayout<AudioDeviceIdentifier>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            throw audioError(operation: "Get default output device", status: status)
        }
        return deviceID
    }

    public func outputDeviceSnapshot(for deviceID: AudioDeviceIdentifier) throws -> OutputDeviceSnapshot {
        let name = deviceName(deviceID: deviceID)
        let uid = deviceUID(deviceID: deviceID)
        let transport = transportType(deviceID: deviceID)
        let volumeState = readOutputVolume(deviceID: deviceID)

        var diagnostics = volumeState.diagnostics
        if transport == nil {
            diagnostics.append(
                AudioDiagnostic(
                    code: "transportTypeUnavailable",
                    message: "Could not read the current output device transport type."
                )
            )
        }

        return OutputDeviceSnapshot(
            id: deviceID,
            uid: uid,
            name: name,
            currentVolume: volumeState.volume,
            volumeControlAvailable: volumeState.settable,
            isHeadphoneOutput: isHeadphoneOutput(name: name, transport: transport),
            diagnostics: diagnostics
        )
    }

    public func outputDeviceList() throws -> [OutputDeviceRef] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var dataSize = UInt32(0)
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr else {
            throw audioError(operation: "List audio devices", status: sizeStatus)
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else {
            return []
        }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs)
        guard dataStatus == noErr else {
            throw audioError(operation: "List audio devices", status: dataStatus)
        }

        var refs: [OutputDeviceRef] = []
        for deviceID in deviceIDs where hasOutputStreams(deviceID: deviceID) {
            guard let uid = deviceUID(deviceID: deviceID) else {
                continue
            }
            let name = deviceName(deviceID: deviceID)
            refs.append(
                OutputDeviceRef(
                    uid: uid,
                    name: name,
                    isHeadphoneOutput: isHeadphoneOutput(name: name, transport: transportType(deviceID: deviceID))
                )
            )
        }
        return refs
    }

    private func hasOutputStreams(deviceID: AudioDeviceIdentifier) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    public func setOutputVolume(deviceID: AudioDeviceIdentifier, percent: Int) throws {
        let scalar = Float32(Double(try VolumeLimiterConfig.validatedLimit(percent)) / 100.0)
        let mainAddress = volumeAddress(element: kAudioObjectPropertyElementMain)

        if hasProperty(deviceID: deviceID, address: mainAddress),
           try isPropertySettable(deviceID: deviceID, address: mainAddress) {
            try setVolumeScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain, scalar: scalar)
            return
        }

        let writableChannels = channelElementsWithVolume(deviceID: deviceID).filter { element in
            let address = volumeAddress(element: element)
            return (try? isPropertySettable(deviceID: deviceID, address: address)) == true
        }

        guard !writableChannels.isEmpty else {
            throw AudioHardwareError(
                operation: "Set output volume",
                message: "No writable master or channel output volume scalar was found."
            )
        }

        for element in writableChannels {
            try setVolumeScalar(deviceID: deviceID, element: element, scalar: scalar)
        }
    }

    public func startMonitoring(
        defaultDeviceChanged: @escaping (AudioDeviceIdentifier) -> Void,
        volumeChanged: @escaping (AudioDeviceIdentifier) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        self.defaultDeviceChanged = defaultDeviceChanged
        self.volumeChanged = volumeChanged
        try installDefaultDeviceListener()
        try installVolumeListenersForCurrentDevice()
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        removeVolumeListeners()
        if var listener = defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID,
                &listener.address,
                listenerQueue,
                listener.block
            )
            defaultDeviceListener = nil
        }
    }

    private func installDefaultDeviceListener() throws {
        if defaultDeviceListener != nil {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else {
                return
            }
            do {
                let deviceID = try self.defaultOutputDevice()
                try self.installVolumeListenersForCurrentDevice()
                self.defaultDeviceChanged?(deviceID)
            } catch {
                self.defaultDeviceChanged?(0)
            }
        }
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, listenerQueue, block)
        guard status == noErr else {
            throw audioError(operation: "Add default output device listener", status: status)
        }
        defaultDeviceListener = ListenerRegistration(objectID: objectID, address: address, block: block)
    }

    private func installVolumeListenersForCurrentDevice() throws {
        lock.lock()
        defer { lock.unlock() }

        removeVolumeListeners()
        let deviceID = try defaultOutputDevice()
        monitoredDeviceID = deviceID

        var elements = [kAudioObjectPropertyElementMain]
        elements.append(contentsOf: channelElementsWithVolume(deviceID: deviceID))
        var installed = false

        for element in Array(Set(elements)) {
            var address = volumeAddress(element: element)
            guard hasProperty(deviceID: deviceID, address: address) else {
                continue
            }

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else {
                    return
                }
                self.volumeChanged?(deviceID)
            }

            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
            if status == noErr {
                installed = true
                volumeListeners.append(
                    ListenerRegistration(objectID: deviceID, address: address, block: block)
                )
            }
        }

        if !installed {
            throw AudioHardwareError(
                operation: "Add output volume listener",
                message: "Current output device does not expose a listenable output volume scalar."
            )
        }
    }

    private func removeVolumeListeners() {
        for var listener in volumeListeners {
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID,
                &listener.address,
                listenerQueue,
                listener.block
            )
        }
        volumeListeners.removeAll()
        monitoredDeviceID = nil
    }

    private func readOutputVolume(deviceID: AudioDeviceIdentifier) -> (
        volume: Int?,
        settable: Bool,
        diagnostics: [AudioDiagnostic]
    ) {
        var diagnostics: [AudioDiagnostic] = []
        let mainAddress = volumeAddress(element: kAudioObjectPropertyElementMain)

        if hasProperty(deviceID: deviceID, address: mainAddress),
           let scalar = try? readVolumeScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            let settable = (try? isPropertySettable(deviceID: deviceID, address: mainAddress)) == true
            return (percent(from: scalar), settable, diagnostics)
        }

        let channels = channelElementsWithVolume(deviceID: deviceID)
        let scalars = channels.compactMap { element in
            try? readVolumeScalar(deviceID: deviceID, element: element)
        }
        let settable = channels.contains { element in
            let address = volumeAddress(element: element)
            return (try? isPropertySettable(deviceID: deviceID, address: address)) == true
        }

        guard !scalars.isEmpty else {
            diagnostics.append(
                AudioDiagnostic(
                    code: "volumeScalarUnavailable",
                    message: "No readable master or output channel volume scalar was found."
                )
            )
            return (nil, settable, diagnostics)
        }

        let average = scalars.reduce(Float32(0), +) / Float32(scalars.count)
        return (percent(from: average), settable, diagnostics)
    }

    private func readVolumeScalar(deviceID: AudioDeviceIdentifier, element: AudioObjectPropertyElement) throws -> Float32 {
        var address = volumeAddress(element: element)
        guard hasProperty(deviceID: deviceID, address: address) else {
            throw AudioHardwareError(operation: "Read output volume", message: "Volume scalar property is unavailable.")
        }
        var scalar = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &scalar)
        guard status == noErr else {
            throw audioError(operation: "Read output volume", status: status)
        }
        return scalar
    }

    private func setVolumeScalar(
        deviceID: AudioDeviceIdentifier,
        element: AudioObjectPropertyElement,
        scalar: Float32
    ) throws {
        var address = volumeAddress(element: element)
        guard try isPropertySettable(deviceID: deviceID, address: address) else {
            throw AudioHardwareError(operation: "Set output volume", message: "Volume scalar is not settable.")
        }
        var value = scalar
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw audioError(operation: "Set output volume", status: status)
        }
    }

    private func channelElementsWithVolume(deviceID: AudioDeviceIdentifier) -> [AudioObjectPropertyElement] {
        (1...32).compactMap { element in
            let address = volumeAddress(element: AudioObjectPropertyElement(element))
            return hasProperty(deviceID: deviceID, address: address) ? AudioObjectPropertyElement(element) : nil
        }
    }

    private func isPropertySettable(
        deviceID: AudioDeviceIdentifier,
        address: AudioObjectPropertyAddress
    ) throws -> Bool {
        var mutableAddress = address
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &mutableAddress, &settable)
        guard status == noErr else {
            throw audioError(operation: "Check if audio property is settable", status: status)
        }
        return settable.boolValue
    }

    private func hasProperty(deviceID: AudioDeviceIdentifier, address: AudioObjectPropertyAddress) -> Bool {
        var mutableAddress = address
        return AudioObjectHasProperty(deviceID, &mutableAddress)
    }

    private func deviceName(deviceID: AudioDeviceIdentifier) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else {
            return "Unknown Output Device"
        }
        return name.takeRetainedValue() as String
    }

    private func deviceUID(deviceID: AudioDeviceIdentifier) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard hasProperty(deviceID: deviceID, address: address) else {
            return nil
        }
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else {
            return nil
        }
        let value = uid.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    private func transportType(deviceID: AudioDeviceIdentifier) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard hasProperty(deviceID: deviceID, address: address) else {
            return nil
        }
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else {
            return nil
        }
        return transport
    }

    private func isHeadphoneOutput(name: String, transport: UInt32?) -> Bool {
        if transport == kAudioDeviceTransportTypeBluetooth {
            return true
        }

        let normalizedName = name.lowercased()
        let headphoneNameFragments = [
            "headphone",
            "headphones",
            "headset",
            "earphone",
            "earphones",
            "earbud",
            "earbuds",
            "airpods",
            "beats",
            "blackwire",
            "freeclip",
            "enco"
        ]
        return headphoneNameFragments.contains { normalizedName.contains($0) }
    }

    private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    private func percent(from scalar: Float32) -> Int {
        min(100, max(0, Int((scalar * 100).rounded())))
    }

    private func audioError(operation: String, status: OSStatus) -> AudioHardwareError {
        AudioHardwareError(operation: operation, status: status, message: coreAudioMessage(for: status))
    }

    private func coreAudioMessage(for status: OSStatus) -> String {
        if let known = SecCopyErrorMessageString(status, nil) as String? {
            return known
        }
        return "Core Audio returned \(status)."
    }
}

#else

import Foundation

public final class CoreAudioHardware: AudioHardwareControlling {
    public init() {}

    public func defaultOutputDevice() throws -> AudioDeviceIdentifier {
        throw AudioHardwareError(operation: "Core Audio", message: "Core Audio is only available on macOS.")
    }

    public func outputDeviceSnapshot(for deviceID: AudioDeviceIdentifier) throws -> OutputDeviceSnapshot {
        throw AudioHardwareError(operation: "Core Audio", message: "Core Audio is only available on macOS.")
    }

    public func outputDeviceList() throws -> [OutputDeviceRef] {
        throw AudioHardwareError(operation: "Core Audio", message: "Core Audio is only available on macOS.")
    }

    public func setOutputVolume(deviceID: AudioDeviceIdentifier, percent: Int) throws {
        throw AudioHardwareError(operation: "Core Audio", message: "Core Audio is only available on macOS.")
    }

    public func startMonitoring(
        defaultDeviceChanged: @escaping (AudioDeviceIdentifier) -> Void,
        volumeChanged: @escaping (AudioDeviceIdentifier) -> Void
    ) throws {
        throw AudioHardwareError(operation: "Core Audio", message: "Core Audio is only available on macOS.")
    }

    public func stopMonitoring() {}
}

#endif
