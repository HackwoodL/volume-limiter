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
    private let currentVolumeTitleLabel = NSTextField(labelWithString: localized("currentVolume.title"))
    private let currentVolumeValueLabel = NSTextField(labelWithString: localized("value.unavailable"))
    private let deviceTitleLabel = NSTextField(labelWithString: localized("device.title"))
    private let deviceValueLabel = NSTextField(labelWithString: localized("value.unavailable"))
    private let warningTitleLabel = NSTextField(labelWithString: "")
    private let warningDetailLabel = NSTextField(labelWithString: "")

    private let addDevicePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let deviceEnableSwitch = NSSwitch()
    private let emptyDeviceLabel = NSTextField(labelWithString: localized("device.empty"))
    private var deviceRows: [String: PerDeviceRow] = [:]
    private var deviceStack: NSStackView?
    private var lastAvailableDeviceUIDs: [String] = []
    private var currentDefaultLimit = 50

    private var warningCard: NSView?
    private var limitCard: NSView?
    private var deviceSection: NSView?
    private var deviceCard: NSView?
    private var optionsSection: NSView?
    private var optionsCard: NSView?

    public override func loadMainView() -> NSView {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))

        configureControls()

        let header = makeHeaderCard()
        let warning = makeWarningCard()
        let limit = makeLimitCard()
        let devices = makeDeviceCard()
        let deviceHeading = sectionLabel(localized("device.section"))
        let options = makeOptionsCard()
        let optionsHeading = sectionLabel(localized("section.options"))

        warningCard = warning
        limitCard = limit
        deviceSection = deviceHeading
        deviceCard = devices
        optionsSection = optionsHeading
        optionsCard = options
        warning.isHidden = true

        let outerStack = NSStackView(views: [
            header,
            warning,
            limit,
            optionsHeading,
            options,
            deviceHeading,
            devices
        ])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 14
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.setCustomSpacing(6, after: optionsHeading)
        outerStack.setCustomSpacing(6, after: deviceHeading)

        rootView.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            outerStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            outerStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            warning.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            limit.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            devices.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
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

    @objc private func deviceEnableSwitchChanged(_ sender: NSSwitch) {
        guard !isUpdatingControls else {
            return
        }
        do {
            let response = try send(
                IPCRequest(
                    id: requestID(),
                    cmd: IPCCommand.setDeviceLimitsEnabled.rawValue,
                    enabled: sender.state == .on
                )
            )
            apply(response)
        } catch {
            showDaemonError(error)
            refreshStatus()
        }
    }

    @objc private func deviceSliderChanged(_ sender: NSSlider) {
        guard !isUpdatingControls else {
            return
        }
        guard let row = deviceRows.values.first(where: { $0.slider === sender }) else {
            return
        }
        let value = Int(sender.doubleValue.rounded())
        row.valueLabel.stringValue = localizedFormat("percent.value", value)
        do {
            let response = try send(
                IPCRequest(
                    id: requestID(),
                    cmd: IPCCommand.setDeviceLimit.rawValue,
                    value: value,
                    deviceUID: row.uid,
                    deviceName: row.name
                )
            )
            apply(response)
        } catch {
            showDaemonError(error)
            refreshStatus()
        }
    }

    @objc private func deviceRemovePressed(_ sender: NSButton) {
        guard let row = deviceRows.values.first(where: { $0.removeButton === sender }) else {
            return
        }
        do {
            let response = try send(
                IPCRequest(id: requestID(), cmd: IPCCommand.removeDeviceLimit.rawValue, deviceUID: row.uid)
            )
            apply(response)
        } catch {
            showDaemonError(error)
            refreshStatus()
        }
    }

    @objc private func addDeviceItemSelected(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else {
            return
        }
        do {
            let response = try send(
                IPCRequest(
                    id: requestID(),
                    cmd: IPCCommand.setDeviceLimit.rawValue,
                    value: currentDefaultLimit,
                    deviceUID: uid,
                    deviceName: sender.title
                )
            )
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

        let defaultLimit = response.defaultLimit ?? response.limit ?? Int(limitSlider.doubleValue.rounded())
        currentDefaultLimit = defaultLimit
        limitSlider.integerValue = defaultLimit
        limitValueLabel.stringValue = localizedFormat("percent.value", defaultLimit)

        if let currentVolume = response.currentVolume {
            currentVolumeValueLabel.stringValue = localizedFormat("percent.value", currentVolume)
        } else {
            currentVolumeValueLabel.stringValue = localized("value.unavailable")
        }

        deviceValueLabel.stringValue = response.deviceName ?? localized("value.unavailable")
        headphoneOnlySwitch.state = (response.headphoneOnly ?? false) ? .on : .off
        notifyOnLimitSwitch.state = (response.notifyOnLimit ?? false) ? .on : .off

        let deviceLimitsEnabled = response.deviceLimitsEnabled ?? false
        deviceEnableSwitch.state = deviceLimitsEnabled ? .on : .off
        deviceStack?.isHidden = !deviceLimitsEnabled
        updateDeviceCard(overrides: response.deviceLimits ?? [], connected: response.connectedDevices ?? [])

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
        deviceEnableSwitch.isEnabled = daemonAvailable
        limitSlider.isEnabled = daemonAvailable

        let showControls = daemonAvailable && limiterEnabled
        setHidden(limitCard, !showControls)
        setHidden(deviceSection, !showControls)
        setHidden(deviceCard, !showControls)
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
        deviceEnableSwitch.target = self
        deviceEnableSwitch.action = #selector(deviceEnableSwitchChanged(_:))

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
        let limitRowView = makeRow([limitTitleLabel, limitSlider, limitValueLabel])
        let volumeRowView = makeRow([currentVolumeTitleLabel, flexibleSpacer(), currentVolumeValueLabel])
        let deviceRowView = makeRow([deviceTitleLabel, flexibleSpacer(), deviceValueLabel])
        return makeCard(rows: [limitRowView, volumeRowView, deviceRowView])
    }

    private func makeDeviceCard() -> CardView {
        let enableLabel = NSTextField(labelWithString: localized("device.enable"))
        enableLabel.font = .systemFont(ofSize: 13)
        enableLabel.lineBreakMode = .byTruncatingTail
        let enableRow = makeRow([enableLabel, flexibleSpacer(), deviceEnableSwitch])

        emptyDeviceLabel.font = .systemFont(ofSize: 12)
        emptyDeviceLabel.textColor = .secondaryLabelColor
        emptyDeviceLabel.lineBreakMode = .byWordWrapping
        emptyDeviceLabel.maximumNumberOfLines = 2
        emptyDeviceLabel.preferredMaxLayoutWidth = 480

        addDevicePopup.controlSize = .small
        addDevicePopup.translatesAutoresizingMaskIntoConstraints = false

        let addRow = NSStackView(views: [addDevicePopup, flexibleSpacer()])
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.spacing = 8
        addRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        let emptyRow = NSStackView(views: [emptyDeviceLabel, flexibleSpacer()])
        emptyRow.orientation = .horizontal
        emptyRow.alignment = .centerY
        emptyRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true

        let content = NSStackView(views: [emptyRow, addRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isHidden = true
        deviceStack = content

        let outer = NSStackView(views: [enableRow, content])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            outer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            outer.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            outer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            enableRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            content.widthAnchor.constraint(equalTo: outer.widthAnchor),
            emptyRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            addRow.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        return card
    }

    private func updateDeviceCard(overrides: [DeviceLimitEntry], connected: [DeviceEntry]) {
        guard let stack = deviceStack else {
            return
        }
        let overrideUIDs = Set(overrides.map { $0.uid })

        for (uid, row) in deviceRows where !overrideUIDs.contains(uid) {
            row.container.removeFromSuperview()
            deviceRows[uid] = nil
        }

        for entry in overrides {
            let name = entry.name ?? entry.uid
            if let row = deviceRows[entry.uid] {
                row.name = name
                row.nameLabel.stringValue = name
                if Int(row.slider.doubleValue.rounded()) != entry.limit {
                    row.slider.integerValue = entry.limit
                }
                row.valueLabel.stringValue = localizedFormat("percent.value", entry.limit)
            } else {
                let row = makePerDeviceRow(uid: entry.uid, name: name, limit: entry.limit)
                deviceRows[entry.uid] = row
                let insertIndex = max(0, stack.arrangedSubviews.count - 1)
                stack.insertArrangedSubview(row.container, at: insertIndex)
                NSLayoutConstraint.activate([
                    row.container.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                    row.container.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
                ])
            }
        }

        emptyDeviceLabel.superview?.isHidden = !overrides.isEmpty
        updateAddPopup(connected.filter { !overrideUIDs.contains($0.uid) })
    }

    private func makePerDeviceRow(uid: String, name: String, limit: Int) -> PerDeviceRow {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        let slider = NSSlider(
            value: Double(limit),
            minValue: 0,
            maxValue: 100,
            target: self,
            action: #selector(deviceSliderChanged(_:))
        )
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        let valueLabel = NSTextField(labelWithString: localizedFormat("percent.value", limit))
        valueLabel.font = .systemFont(ofSize: 13)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let removeButton = NSButton(title: "", target: self, action: #selector(deviceRemovePressed(_:)))
        removeButton.isBordered = false
        removeButton.imagePosition = .imageOnly
        if let image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: localized("device.remove")) {
            removeButton.image = image
            removeButton.contentTintColor = .systemRed
        } else {
            removeButton.title = "–"
            removeButton.isBordered = true
        }
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        let container = NSStackView(views: [nameLabel, slider, valueLabel, removeButton])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.distribution = .fill
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        return PerDeviceRow(
            uid: uid,
            name: name,
            container: container,
            nameLabel: nameLabel,
            slider: slider,
            valueLabel: valueLabel,
            removeButton: removeButton
        )
    }

    private func updateAddPopup(_ devices: [DeviceEntry]) {
        let uids = devices.map { $0.uid }
        guard uids != lastAvailableDeviceUIDs else {
            return
        }
        lastAvailableDeviceUIDs = uids

        let menu = addDevicePopup.menu ?? NSMenu()
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: localized("device.add"), action: nil, keyEquivalent: ""))
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(addDeviceItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            menu.addItem(item)
        }
        addDevicePopup.menu = menu
        addDevicePopup.isEnabled = !devices.isEmpty
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

private final class PerDeviceRow {
    let uid: String
    var name: String
    let container: NSView
    let nameLabel: NSTextField
    let slider: NSSlider
    let valueLabel: NSTextField
    let removeButton: NSButton

    init(
        uid: String,
        name: String,
        container: NSView,
        nameLabel: NSTextField,
        slider: NSSlider,
        valueLabel: NSTextField,
        removeButton: NSButton
    ) {
        self.uid = uid
        self.name = name
        self.container = container
        self.nameLabel = nameLabel
        self.slider = slider
        self.valueLabel = valueLabel
        self.removeButton = removeButton
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
