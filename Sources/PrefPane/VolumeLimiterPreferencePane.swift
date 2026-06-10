import Cocoa
import Foundation
import PreferencePanes

@objc(VolumeLimiterPreferencePane)
public final class VolumeLimiterPreferencePane: NSPreferencePane {
    private let client = UnixSocketClient()
    private var isUpdatingControls = false
    private var refreshTimer: Timer?

    private let masterSwitch = NSSwitch()
    private let limitSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let headphoneOnlySwitch = NSSwitch()
    private let launchAtLoginSwitch = NSSwitch()
    private let notifyOnLimitSwitch = NSSwitch()

    private let limitTitleLabel = NSTextField(labelWithString: localized("limit.title"))
    private let limitValueLabel = NSTextField(labelWithString: localized("percent.placeholder"))
    private let limitScopeLabel = NSTextField(labelWithString: "")
    private let resetDefaultButton = NSButton(title: localized("reset.button"), target: nil, action: nil)
    private let currentVolumeTitleLabel = NSTextField(labelWithString: localized("currentVolume.title"))
    private let currentVolumeValueLabel = NSTextField(labelWithString: localized("value.unavailable"))
    private let deviceTitleLabel = NSTextField(labelWithString: localized("device.title"))
    private let deviceValueLabel = NSTextField(labelWithString: localized("value.unavailable"))
    private let warningTitleLabel = NSTextField(labelWithString: "")
    private let warningDetailLabel = NSTextField(labelWithString: "")

    private var warningCard: NSView?
    private var limitCard: NSView?
    private var optionsSection: NSView?
    private var optionsCard: NSView?

    public override func loadMainView() -> NSView {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))

        configureControls()

        let header = makeHeaderCard()
        let warning = makeWarningCard()
        let limit = makeLimitCard()
        let options = makeOptionsCard()
        let optionsHeading = sectionLabel(localized("section.options"))

        warningCard = warning
        limitCard = limit
        optionsSection = optionsHeading
        optionsCard = options
        warning.isHidden = true

        let outerStack = NSStackView(views: [
            header,
            warning,
            limit,
            optionsHeading,
            options
        ])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 14
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.setCustomSpacing(6, after: optionsHeading)

        rootView.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            outerStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            outerStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            warning.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            limit.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            options.widthAnchor.constraint(equalTo: outerStack.widthAnchor)
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

    @objc private func masterSwitchChanged(_ sender: NSSwitch) {
        guard !isUpdatingControls else {
            return
        }

        do {
            let response = try send(
                IPCRequest(
                    id: requestID(),
                    cmd: IPCCommand.setEnabled.rawValue,
                    enabled: sender.state == .on
                )
            )
            apply(response)
        } catch {
            showDaemonError(error)
            refreshStatus()
        }
    }

    @objc private func headphoneOnlyChanged(_ sender: NSSwitch) {
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

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        do {
            try LaunchAgentManager.setEnabled(sender.state == .on)
        } catch {
            sender.state = LaunchAgentManager.isEnabled ? .on : .off
            presentError(localizedFormat("launchAgent.error", error.localizedDescription))
        }
    }

    @objc private func notifyOnLimitChanged(_ sender: NSSwitch) {
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

    @objc private func resetLimitButtonPressed(_: NSButton) {
        do {
            let response = try send(IPCRequest(id: requestID(), cmd: IPCCommand.resetDeviceLimit.rawValue))
            apply(response)
        } catch {
            showDaemonError(error)
            refreshStatus()
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let window = mainView.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func refreshStatus() {
        launchAtLoginSwitch.state = LaunchAgentManager.isEnabled ? .on : .off
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
        limitValueLabel.stringValue = localizedFormat("percent.value", limit)

        let hasOverride = response.deviceHasLimitOverride ?? false
        let defaultLimit = response.defaultLimit ?? limit
        limitScopeLabel.stringValue = hasOverride
            ? localizedFormat("limit.scope.override", defaultLimit)
            : localized("limit.scope.default")
        resetDefaultButton.isHidden = !hasOverride

        if let currentVolume = response.currentVolume {
            currentVolumeValueLabel.stringValue = localizedFormat("percent.value", currentVolume)
        } else {
            currentVolumeValueLabel.stringValue = localized("value.unavailable")
        }

        deviceValueLabel.stringValue = response.deviceName ?? localized("value.unavailable")
        headphoneOnlySwitch.state = (response.headphoneOnly ?? false) ? .on : .off
        notifyOnLimitSwitch.state = (response.notifyOnLimit ?? false) ? .on : .off

        let limiterEnabled = response.enabled ?? false
        masterSwitch.state = limiterEnabled ? .on : .off
        updateLayout(
            daemonAvailable: true,
            limiterEnabled: limiterEnabled,
            volumeControlAvailable: response.volumeControlAvailable ?? false,
            diagnostics: response.diagnostics ?? []
        )
    }

    private func showDaemonError(_ error: Error) {
        currentVolumeValueLabel.stringValue = localized("value.unavailable")
        deviceValueLabel.stringValue = localized("value.unavailable")
        updateLayout(
            daemonAvailable: false,
            limiterEnabled: masterSwitch.state == .on,
            volumeControlAvailable: false,
            diagnostics: [error.localizedDescription]
        )
    }

    private func updateLayout(
        daemonAvailable: Bool,
        limiterEnabled: Bool,
        volumeControlAvailable: Bool,
        diagnostics: [String]
    ) {
        masterSwitch.isEnabled = daemonAvailable
        headphoneOnlySwitch.isEnabled = daemonAvailable
        notifyOnLimitSwitch.isEnabled = daemonAvailable
        limitSlider.isEnabled = daemonAvailable

        let showControls = daemonAvailable && limiterEnabled
        setHidden(limitCard, !showControls)
        setHidden(optionsSection, !showControls)
        setHidden(optionsCard, !showControls)

        if !daemonAvailable {
            warningTitleLabel.stringValue = localized("warning.daemonNotRunning")
            warningDetailLabel.stringValue = localized("daemon.startCommand")
            setHidden(warningCard, false)
        } else if limiterEnabled, !volumeControlAvailable {
            warningTitleLabel.stringValue = localized("warning.volumeControlUnavailable")
            warningDetailLabel.stringValue = diagnostics.isEmpty
                ? ""
                : localizedFormat("diagnostics.value", diagnostics.joined(separator: " | "))
            setHidden(warningCard, false)
        } else {
            setHidden(warningCard, true)
        }
        warningDetailLabel.isHidden = warningDetailLabel.stringValue.isEmpty
    }

    private func setHidden(_ view: NSView?, _ hidden: Bool) {
        guard let view = view, view.isHidden != hidden else {
            return
        }
        view.isHidden = hidden
    }

    private func requestID() -> String {
        UUID().uuidString
    }

    private func configureControls() {
        limitSlider.target = self
        limitSlider.action = #selector(limitSliderChanged(_:))
        limitSlider.numberOfTickMarks = 11
        limitSlider.allowsTickMarkValuesOnly = false
        limitSlider.controlSize = .small
        limitSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        limitSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        masterSwitch.target = self
        masterSwitch.action = #selector(masterSwitchChanged(_:))
        masterSwitch.setContentHuggingPriority(.required, for: .horizontal)

        headphoneOnlySwitch.target = self
        headphoneOnlySwitch.action = #selector(headphoneOnlyChanged(_:))
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged(_:))
        notifyOnLimitSwitch.target = self
        notifyOnLimitSwitch.action = #selector(notifyOnLimitChanged(_:))

        for label in [limitTitleLabel, currentVolumeTitleLabel, deviceTitleLabel] {
            label.font = .systemFont(ofSize: 13)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        for label in [limitValueLabel, currentVolumeValueLabel, deviceValueLabel] {
            label.font = .systemFont(ofSize: 13)
            label.alignment = .right
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        }

        limitScopeLabel.font = .systemFont(ofSize: 11)
        limitScopeLabel.textColor = .secondaryLabelColor
        limitScopeLabel.lineBreakMode = .byTruncatingTail

        resetDefaultButton.target = self
        resetDefaultButton.action = #selector(resetLimitButtonPressed(_:))
        resetDefaultButton.bezelStyle = .rounded
        resetDefaultButton.controlSize = .small
        resetDefaultButton.isHidden = true
        resetDefaultButton.setContentHuggingPriority(.required, for: .horizontal)

        warningTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        warningTitleLabel.lineBreakMode = .byWordWrapping
        warningTitleLabel.maximumNumberOfLines = 2

        warningDetailLabel.font = .systemFont(ofSize: 11)
        warningDetailLabel.textColor = .secondaryLabelColor
        warningDetailLabel.isSelectable = true
        warningDetailLabel.lineBreakMode = .byWordWrapping
        warningDetailLabel.maximumNumberOfLines = 3
    }

    private func makeHeaderCard() -> CardView {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if let base = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
            icon.image = base.withSymbolConfiguration(configuration) ?? base
            icon.contentTintColor = .controlAccentColor
        }
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30)
        ])

        let titleLabel = NSTextField(labelWithString: localized("app.title"))
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let subtitleLabel = NSTextField(wrappingLabelWithString: localized("app.subtitle"))
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = 420
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, textStack, masterSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func makeLimitCard() -> CardView {
        let topRow = NSStackView(views: [limitTitleLabel, limitSlider, limitValueLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.spacing = 12
        topRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true

        let scopeRow = NSStackView(views: [limitScopeLabel, flexibleSpacer(), resetDefaultButton])
        scopeRow.orientation = .horizontal
        scopeRow.alignment = .centerY
        scopeRow.spacing = 8
        scopeRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true

        let limitCell = NSStackView(views: [topRow, scopeRow])
        limitCell.orientation = .vertical
        limitCell.alignment = .leading
        limitCell.spacing = 2
        limitCell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topRow.widthAnchor.constraint(equalTo: limitCell.widthAnchor),
            scopeRow.widthAnchor.constraint(equalTo: limitCell.widthAnchor)
        ])

        let volumeRowView = makeRow([currentVolumeTitleLabel, flexibleSpacer(), currentVolumeValueLabel])
        let deviceRowView = makeRow([deviceTitleLabel, flexibleSpacer(), deviceValueLabel])
        return makeCard(rows: [limitCell, volumeRowView, deviceRowView])
    }

    private func makeOptionsCard() -> CardView {
        let headphoneRow = makeRow([
            optionLabel(localized("headphoneOnly.checkbox")),
            flexibleSpacer(),
            headphoneOnlySwitch
        ])
        let launchRow = makeRow([
            optionLabel(localized("launchAtLogin.checkbox")),
            flexibleSpacer(),
            launchAtLoginSwitch
        ])
        let notifyRow = makeRow([
            optionLabel(localized("notifyOnLimit.checkbox")),
            flexibleSpacer(),
            notifyOnLimitSwitch
        ])
        return makeCard(rows: [headphoneRow, launchRow, notifyRow])
    }

    private func makeWarningCard() -> NSView {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if let base = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            icon.image = base.withSymbolConfiguration(configuration) ?? base
            icon.contentTintColor = .systemOrange
        }
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20)
        ])

        warningTitleLabel.preferredMaxLayoutWidth = 470
        warningDetailLabel.preferredMaxLayoutWidth = 470
        warningDetailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [warningTitleLabel, warningDetailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        return card
    }

    private func optionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeCard(rows: [NSView]) -> CardView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2)
        ])

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = separator()
                stack.addArrangedSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                    line.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
                ])
            }
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        return card
    }

    private func makeRow(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return row
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
}

private final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
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
