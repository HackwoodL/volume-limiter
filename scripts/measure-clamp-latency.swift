#!/usr/bin/env swift

import CoreAudio
import Foundation

struct Arguments {
    var limit = 30
    var timeoutSeconds = 30.0
    var triggerVolume: Int?
}

struct Listener {
    let objectID: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

final class MeasurementState {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let limit: Int
    private var overLimitAt: DispatchTime?
    private(set) var latencyMilliseconds: Double?

    init(limit: Int) {
        self.limit = limit
    }

    func observe(volume: Int) {
        let now = DispatchTime.now()

        lock.lock()
        defer { lock.unlock() }

        print("event volume=\(volume)%")
        fflush(stdout)

        if volume > limit {
            if overLimitAt == nil {
                overLimitAt = now
                print("observed-over-limit volume=\(volume)%")
                fflush(stdout)
            }
            return
        }

        guard let overLimitAt, latencyMilliseconds == nil else {
            return
        }

        let elapsed = now.uptimeNanoseconds - overLimitAt.uptimeNanoseconds
        latencyMilliseconds = Double(elapsed) / 1_000_000.0
        semaphore.signal()
    }

    func wait(timeoutSeconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + timeoutSeconds) == .success
    }
}

do {
    let arguments = try parseArguments()
    let deviceID = try defaultOutputDevice()
    let deviceName = deviceName(deviceID: deviceID)
    let initialVolume = try readVolumePercent(deviceID: deviceID)
    let state = MeasurementState(limit: arguments.limit)
    let queue = DispatchQueue(label: "com.volumelimiter.measure-latency")
    var listeners: [Listener] = []

    for element in volumeElements(deviceID: deviceID) {
        var address = volumeAddress(element: element)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            if let volume = try? readVolumePercent(deviceID: deviceID) {
                state.observe(volume: volume)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
        guard status == noErr else {
            throw MeasureError.coreAudio("AudioObjectAddPropertyListenerBlock", status)
        }
        listeners.append(Listener(objectID: deviceID, address: address, block: block))
    }

    defer {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, queue, listener.block)
        }
    }

    print("device=\(deviceName)")
    print("limit=\(arguments.limit)%")
    print("initial-volume=\(initialVolume)%")
    print("timeout=\(Int(arguments.timeoutSeconds))s")

    if let triggerVolume = arguments.triggerVolume {
        print("trigger-volume=\(triggerVolume)%")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            do {
                try setVolumePercent(deviceID: deviceID, percent: triggerVolume)
                print("triggered-volume-set")
                fflush(stdout)
            } catch {
                print("trigger-error=\(error.localizedDescription)")
                fflush(stdout)
            }
        }
    } else {
        print("Press the keyboard volume-up key until the system tries to exceed the limit.")
    }

    fflush(stdout)

    guard state.wait(timeoutSeconds: arguments.timeoutSeconds),
          let latency = state.latencyMilliseconds
    else {
        print("result=inconclusive: no over-limit then clamped event was observed before timeout")
        exit(2)
    }

    print(String(format: "clamp-latency-ms=%.2f", latency))
    if latency < 100 {
        print("result=pass")
        exit(0)
    } else {
        print("result=fail")
        exit(1)
    }
} catch {
    fputs("measure-clamp-latency: \(error.localizedDescription)\n", stderr)
    exit(1)
}

func parseArguments() throws -> Arguments {
    var result = Arguments()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()

    while let argument = iterator.next() {
        switch argument {
        case "--limit":
            guard let value = iterator.next(), let limit = Int(value), (0...100).contains(limit) else {
                throw MeasureError.invalidArgument("--limit requires an integer in 0...100")
            }
            result.limit = limit
        case "--timeout":
            guard let value = iterator.next(), let timeout = Double(value), timeout > 0 else {
                throw MeasureError.invalidArgument("--timeout requires a positive number of seconds")
            }
            result.timeoutSeconds = timeout
        case "--trigger":
            guard let value = iterator.next(), let volume = Int(value), (0...100).contains(volume) else {
                throw MeasureError.invalidArgument("--trigger requires an integer in 0...100")
            }
            result.triggerVolume = volume
        case "--help", "-h":
            print("""
            Usage: scripts/measure-clamp-latency.swift [--limit 30] [--timeout 30] [--trigger 60]

            Without --trigger, press the keyboard volume-up key until the output volume tries to exceed the limit.
            With --trigger, the script sets system output volume after installing its listener; use this only when it is safe.
            """)
            exit(0)
        default:
            throw MeasureError.invalidArgument("unknown argument \(argument)")
        }
    }

    return result
}

func defaultOutputDevice() throws -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        &deviceID
    )
    guard status == noErr, deviceID != 0 else {
        throw MeasureError.coreAudio("default output device", status)
    }
    return deviceID
}

func deviceName(deviceID: AudioDeviceID) -> String {
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

func readVolumePercent(deviceID: AudioDeviceID) throws -> Int {
    let mainAddress = volumeAddress(element: kAudioObjectPropertyElementMain)
    if hasProperty(deviceID: deviceID, address: mainAddress),
       let scalar = try? readVolumeScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
        return percent(from: scalar)
    }

    let scalars = channelElements(deviceID: deviceID).compactMap {
        try? readVolumeScalar(deviceID: deviceID, element: $0)
    }
    guard !scalars.isEmpty else {
        throw MeasureError.message("No readable output volume scalar was found.")
    }
    return percent(from: scalars.reduce(Float32(0), +) / Float32(scalars.count))
}

func setVolumePercent(deviceID: AudioDeviceID, percent: Int) throws {
    let scalar = Float32(Double(percent) / 100.0)
    let mainAddress = volumeAddress(element: kAudioObjectPropertyElementMain)

    if hasProperty(deviceID: deviceID, address: mainAddress),
       try isSettable(deviceID: deviceID, address: mainAddress) {
        try setVolumeScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain, scalar: scalar)
        return
    }

    let writableChannels = try channelElements(deviceID: deviceID).filter {
        try isSettable(deviceID: deviceID, address: volumeAddress(element: $0))
    }
    guard !writableChannels.isEmpty else {
        throw MeasureError.message("No writable output volume scalar was found.")
    }

    for element in writableChannels {
        try setVolumeScalar(deviceID: deviceID, element: element, scalar: scalar)
    }
}

func volumeElements(deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
    var elements: [AudioObjectPropertyElement] = []
    let mainAddress = volumeAddress(element: kAudioObjectPropertyElementMain)
    if hasProperty(deviceID: deviceID, address: mainAddress) {
        elements.append(kAudioObjectPropertyElementMain)
    }
    elements.append(contentsOf: channelElements(deviceID: deviceID))
    return Array(Set(elements)).sorted()
}

func channelElements(deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
    (1...32).compactMap { element in
        let audioElement = AudioObjectPropertyElement(element)
        return hasProperty(deviceID: deviceID, address: volumeAddress(element: audioElement)) ? audioElement : nil
    }
}

func readVolumeScalar(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) throws -> Float32 {
    var address = volumeAddress(element: element)
    var scalar = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &scalar)
    guard status == noErr else {
        throw MeasureError.coreAudio("read volume", status)
    }
    return scalar
}

func setVolumeScalar(deviceID: AudioDeviceID, element: AudioObjectPropertyElement, scalar: Float32) throws {
    var address = volumeAddress(element: element)
    var value = scalar
    let size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
    guard status == noErr else {
        throw MeasureError.coreAudio("set volume", status)
    }
}

func isSettable(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) throws -> Bool {
    var mutableAddress = address
    var settable = DarwinBoolean(false)
    let status = AudioObjectIsPropertySettable(deviceID, &mutableAddress, &settable)
    guard status == noErr else {
        throw MeasureError.coreAudio("is settable", status)
    }
    return settable.boolValue
}

func hasProperty(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) -> Bool {
    var mutableAddress = address
    return AudioObjectHasProperty(deviceID, &mutableAddress)
}

func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: element
    )
}

func percent(from scalar: Float32) -> Int {
    min(100, max(0, Int((scalar * 100).rounded())))
}

enum MeasureError: Error, LocalizedError {
    case invalidArgument(String)
    case coreAudio(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message), let .message(message):
            message
        case let .coreAudio(operation, status):
            "\(operation) failed with OSStatus \(status)"
        }
    }
}
