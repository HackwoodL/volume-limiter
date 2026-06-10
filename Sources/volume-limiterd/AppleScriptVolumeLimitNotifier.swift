import Foundation
import VolumeLimiterCore

final class AppleScriptVolumeLimitNotifier: VolumeLimitNotifying {
    private let queue = DispatchQueue(label: "com.volumelimiter.notifications")
    private let minimumInterval: TimeInterval
    private var lastNotificationAt: Date?

    init(minimumInterval: TimeInterval = 5) {
        self.minimumInterval = minimumInterval
    }

    func volumeWasLimited(from currentVolume: Int, to limit: Int, deviceName: String) {
        queue.async { [minimumInterval] in
            let now = Date()
            if let lastNotificationAt = self.lastNotificationAt,
               now.timeIntervalSince(lastNotificationAt) < minimumInterval {
                return
            }
            self.lastNotificationAt = now
            self.deliverNotification(from: currentVolume, to: limit, deviceName: deviceName)
        }
    }

    private func deliverNotification(from currentVolume: Int, to limit: Int, deviceName: String) {
        let script = """
        display notification "Volume was reduced from \(currentVolume)% to \(limit)% on \(escaped(deviceName))." with title "Volume Limiter" subtitle "Volume capped"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
        } catch {
            fputs("volume-limiterd: failed to deliver notification: \(error.localizedDescription)\n", stderr)
        }
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
