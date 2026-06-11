import Foundation

#if os(macOS)
import CoreAudio

public typealias AudioDeviceIdentifier = AudioDeviceID
#else
public typealias AudioDeviceIdentifier = UInt32
#endif

public struct AudioDiagnostic: Codable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct OutputDeviceSnapshot: Codable, Equatable {
    public var id: AudioDeviceIdentifier
    public var uid: String?
    public var name: String
    public var currentVolume: Int?
    public var volumeControlAvailable: Bool
    public var isHeadphoneOutput: Bool
    public var diagnostics: [AudioDiagnostic]

    public init(
        id: AudioDeviceIdentifier,
        uid: String? = nil,
        name: String,
        currentVolume: Int?,
        volumeControlAvailable: Bool,
        isHeadphoneOutput: Bool,
        diagnostics: [AudioDiagnostic] = []
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.currentVolume = currentVolume
        self.volumeControlAvailable = volumeControlAvailable
        self.isHeadphoneOutput = isHeadphoneOutput
        self.diagnostics = diagnostics
    }
}

/// A lightweight reference to a connected output device, used to populate
/// the "add a device" picker without reading each device's volume.
public struct OutputDeviceRef: Codable, Equatable {
    public var uid: String
    public var name: String
    public var isHeadphoneOutput: Bool

    public init(uid: String, name: String, isHeadphoneOutput: Bool = false) {
        self.uid = uid
        self.name = name
        self.isHeadphoneOutput = isHeadphoneOutput
    }
}

public struct AudioHardwareError: Error, Equatable, LocalizedError {
    public var operation: String
    public var status: OSStatus?
    public var message: String

    public init(operation: String, status: OSStatus? = nil, message: String) {
        self.operation = operation
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        if let status {
            "\(operation) failed with OSStatus \(status): \(message)"
        } else {
            "\(operation) failed: \(message)"
        }
    }
}

public protocol AudioHardwareControlling: AnyObject {
    func defaultOutputDevice() throws -> AudioDeviceIdentifier
    func outputDeviceSnapshot(for deviceID: AudioDeviceIdentifier) throws -> OutputDeviceSnapshot
    func outputDeviceList() throws -> [OutputDeviceRef]
    /// Lightweight read of just the output volume (no name/UID/transport), for the
    /// hot path that must keep up with rapid volume-key presses. Returns nil if
    /// the volume can't be read.
    func currentOutputVolumePercent(deviceID: AudioDeviceIdentifier) -> Int?
    func setOutputVolume(deviceID: AudioDeviceIdentifier, percent: Int) throws
    func startMonitoring(
        defaultDeviceChanged: @escaping (AudioDeviceIdentifier) -> Void,
        volumeChanged: @escaping (AudioDeviceIdentifier) -> Void
    ) throws
    func stopMonitoring()
}
