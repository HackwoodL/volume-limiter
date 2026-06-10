import Cocoa
import Foundation
import PreferencePanes

@objc(VolumeLimiterPreferencePane)
public final class VolumeLimiterPreferencePane: NSPreferencePane {
    private let client = UnixSocketClient()
    private var isUpdatingControls = false
    private var refreshTimer: Timer?

    private var limitLabel = NSTextField(labelWithString: localized("limit.placeholder"))
    private var currentVolumeLabel = NSTextField(labelWithString: localized("currentVolume.unavailable"))
    private var deviceLabel = NSTextField(labelWithString: localized("device.unavailable"))
    private var daemonStatusLabel = NSTextField(labelWithString: "")
    private var diagnosticsLabel = NSTextField(labelWithString: "")
    private var limitSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private var headphoneOnlyButton = NSButton(
        checkboxWithTitle: localized("headphoneOnly.checkbox"),
        target: nil,
        action: nil
    )
    private var launchAtLoginButton = NSButton(
        checkboxWithTitle: localized("launchAtLogin.checkbox"),
        target: nil,
        action: nil
    )
    private var notifyOnLimitButton = NSButton(
        checkboxWithTitle: localized("notifyOnLimit.checkbox"),
        target: nil,
        action: nil
    )

    public override func loadMainView() -> NSView {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 430))
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: localized("app.title"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString: localized("app.subtitle")
        )
        subtitle.textColor = .secondaryLabelColor

        limitSlider.target = self
        limitSlider.action = #selector(limitSliderChanged(_:))
        limitSlider.numberOfTickMarks = 11
        limitSlider.allowsTickMarkValuesOnly = false

        headphoneOnlyButton.target = self
        headphoneOnlyButton.action = #selector(headphoneOnlyChanged(_:))

        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged(_:))

        notifyOnLimitButton.target = self
        notifyOnLimitButton.action = #selector(notifyOnLimitChanged(_:))

        let refreshButton = NSButton(
            title: localized("refresh.button"),
            target: self,
            action: #selector(refreshButtonPressed(_:))
        )
        let openCLIHelpButton = NSButton(
            title: localized("showStartCommand.button"),
            target: self,
            action: #selector(showDaemonStartCommand(_:))
        )

        diagnosticsLabel.textColor = .secondaryLabelColor
        diagnosticsLabel.lineBreakMode = .byWordWrapping
        diagnosticsLabel.maximumNumberOfLines = 4

        daemonStatusLabel.lineBreakMode = .byWordWrapping
        daemonStatusLabel.maximumNumberOfLines = 3

        let limitRow = horizontalStack([
            limitLabel,
            limitSlider
        ])
        limitRow.setCustomSpacing(16, after: limitLabel)
        limitSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = horizontalStack([
            refreshButton,
            openCLIHelpButton
        ])

        let stack = NSStackView(views: [
            title,
            subtitle,
            separator(),
            limitRow,
            currentVolumeLabel,
            deviceLabel,
            headphoneOnlyButton,
            launchAtLoginButton,
            notifyOnLimitButton,
            buttonRow,
            daemonStatusLabel,
            diagnosticsLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -24),
            limitSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])

        mainView = rootView
        refreshStatus()
        startAutoRefresh()
        return rootView
    }

    public override func didSelect() {
        super.didSelect()
        refreshStatus()
        startAutoRefresh()
    }

    public override func didUnselect() {
        super.didUnselect()
        stopAutoRefresh()
    }

    deinit {
        stopAutoRefresh()
    }

    @objc private func limitSliderChanged(_ sender: NSSlider) {
        guard !isUpdatingControls else {
            return
        }

        let value = Int(sender.doubleValue.rounded())
        do {
            let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.setLimit.rawValue, value: value))
            apply(response)
        } catch {
            showDaemonError(error)
        }
    }

    @objc private func headphoneOnlyChanged(_ sender: NSButton) {
        guard !isUpdatingControls else {
            return
        }

        do {
            let response = try send(
                IPCRequest(
                    id: requestID(),
                    cmd: IPCCommand.setHeadphoneOnly.rawValue,
                    enabled: sender.state == .on
                )
            )
            apply(response)
        } catch {
            showDaemonError(error)
            refreshStatus()
        }
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        do {
            try LaunchAgentManager.setEnabled(sender.state == .on)
            daemonStatusLabel.stringValue = sender.state == .on
                ? localizedFormat("launchAgent.enabled", LaunchAgentManager.label)
                : localized("launchAgent.disabled")
        } catch {
            daemonStatusLabel.stringValue = localizedFormat("launchAgent.error", error.localizedDescription)
            launchAtLoginButton.state = LaunchAgentManager.isEnabled ? .on : .off
        }
    }

    @objc private func notifyOnLimitChanged(_ sender: NSButton) {
        guard !isUpdatingControls else {
            return
        }

        do {
            let response = try send(
                IPCRequest(
                    id: requestID(),
                    cmd: IPCCommand.setNotifyOnLimit.rawValue,
                    enabled: sender.state == .on
                )
            )
            apply(response)
        } catch {
            showDaemonError(error)
            refreshStatus()
        }
    }

    @objc private func refreshButtonPressed(_: NSButton) {
        refreshStatus()
    }

    @objc private func showDaemonStartCommand(_: NSButton) {
        daemonStatusLabel.stringValue = localized("daemon.startCommand")
    }

    private func refreshStatus() {
        launchAtLoginButton.state = LaunchAgentManager.isEnabled ? .on : .off

        do {
            let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.getStatus.rawValue))
            apply(response)
        } catch {
            showDaemonError(error)
        }
    }

    private func startAutoRefresh() {
        guard refreshTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func send(_ request: IPCRequest) throws -> IPCResponse {
        let response = try client.send(request)
        guard response.ok else {
            throw PreferencePaneError.daemon(response.error?.message ?? localized("daemon.unknownError"))
        }
        return response
    }

    private func apply(_ response: IPCResponse) {
        isUpdatingControls = true
        defer { isUpdatingControls = false }

        let limit = response.limit ?? Int(limitSlider.doubleValue.rounded())
        limitSlider.integerValue = limit
        limitLabel.stringValue = localizedFormat("limit.value", limit)

        if let currentVolume = response.currentVolume {
            currentVolumeLabel.stringValue = localizedFormat("currentVolume.value", currentVolume)
        } else {
            currentVolumeLabel.stringValue = localized("currentVolume.unavailable")
        }

        deviceLabel.stringValue = localizedFormat("device.value", response.deviceName ?? localized("value.unavailable"))
        headphoneOnlyButton.state = (response.headphoneOnly ?? false) ? .on : .off
        notifyOnLimitButton.state = (response.notifyOnLimit ?? false) ? .on : .off

        let enabledText = (response.enabled ?? false) ? localized("state.on") : localized("state.off")
        let controlText = (response.volumeControlAvailable ?? false)
            ? localized("state.available")
            : localized("state.unavailable")
        let headphoneText = (response.deviceIsHeadphone ?? false) ? localized("state.yes") : localized("state.no")
        daemonStatusLabel.stringValue = localizedFormat(
            "daemon.status",
            enabledText,
            controlText,
            headphoneText
        )

        let diagnostics = response.diagnostics ?? []
        diagnosticsLabel.stringValue = diagnostics.isEmpty
            ? localized("diagnostics.none")
            : localizedFormat("diagnostics.value", diagnostics.joined(separator: " | "))
    }

    private func showDaemonError(_ error: Error) {
        currentVolumeLabel.stringValue = localized("currentVolume.unavailable")
        deviceLabel.stringValue = localized("device.unavailable")
        diagnosticsLabel.stringValue = localizedFormat("diagnostics.value", error.localizedDescription)
        daemonStatusLabel.stringValue = localized("daemon.notResponding")
    }

    private func requestID() -> String {
        UUID().uuidString
    }

    private func horizontalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

private enum PreferencePaneError: Error, LocalizedError {
    case daemon(String)
    case daemonExecutableNotFound
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case let .daemon(message):
            message
        case .daemonExecutableNotFound:
            localized("daemon.executableNotFound")
        case let .launchctlFailed(message):
            message
        }
    }
}

private func localized(_ key: String) -> String {
    let bundle = localizationBundle()
    return NSLocalizedString(
        key,
        tableName: nil,
        bundle: bundle,
        value: key,
        comment: ""
    )
}

private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: Locale.current, arguments: arguments)
}

private func localizationBundle() -> Bundle {
    let preferredLanguage = Locale.preferredLanguages.first?.lowercased() ?? ""
    let localization = preferredLanguage.hasPrefix("zh") ? "zh-Hans" : "en"
    let baseBundle = Bundle(for: VolumeLimiterPreferencePane.self)

    guard
        let path = baseBundle.path(forResource: localization, ofType: "lproj"),
        let bundle = Bundle(path: path)
    else {
        return baseBundle
    }

    return bundle
}

private enum LaunchAgentManager {
    static let label = "com.hackwoodl.volumelimiter"

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private static func install() throws {
        guard let daemonPath = resolvedDaemonPath() else {
            throw PreferencePaneError.daemonExecutableNotFound
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try launchAgentPlist(daemonPath: daemonPath).write(to: plistURL, atomically: true, encoding: .utf8)
        try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        try runLaunchctl(["enable", "gui/\(getuid())/\(label)"])
    }

    private static func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try? runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private static func resolvedDaemonPath() -> String? {
        let bundleSibling = Bundle(for: VolumeLimiterPreferencePane.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/volume-limiterd")
            .path
        let candidates = [
            bundleSibling,
            "/opt/homebrew/bin/volume-limiterd",
            "/usr/local/bin/volume-limiterd",
            "/usr/bin/volume-limiterd"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func launchAgentPlist(daemonPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "launchctl failed"
            throw PreferencePaneError.launchctlFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
