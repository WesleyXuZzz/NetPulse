import AppKit
import Combine
import SwiftUI

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum SettingsPanelLayout {
    static let preferredSize = NSSize(width: 392, height: 800)
    static let edgePadding: CGFloat = 8
    static let statusItemGap: CGFloat = 8

    static func panelFrame(
        relativeTo statusItemFrame: NSRect,
        preferredSize: NSSize = SettingsPanelLayout.preferredSize,
        visibleFrame: NSRect,
        edgePadding: CGFloat = SettingsPanelLayout.edgePadding,
        gap: CGFloat = SettingsPanelLayout.statusItemGap
    ) -> NSRect {
        let safeMinX = visibleFrame.minX + edgePadding
        let safeMaxX = visibleFrame.maxX - edgePadding
        let safeMinY = visibleFrame.minY + edgePadding
        let safeMaxY = visibleFrame.maxY - edgePadding
        let availableHeight = max(0, safeMaxY - safeMinY)
        let panelHeight = min(preferredSize.height, availableHeight)

        let originX = clamped(
            statusItemFrame.midX - (preferredSize.width / 2),
            lowerBound: safeMinX,
            upperBound: safeMaxX - preferredSize.width
        )
        let originY = clamped(
            statusItemFrame.minY - panelHeight - gap,
            lowerBound: safeMinY,
            upperBound: safeMaxY - panelHeight
        )

        return NSRect(
            x: originX,
            y: originY,
            width: preferredSize.width,
            height: panelHeight
        )
    }

    private static func clamped(_ value: CGFloat, lowerBound: CGFloat, upperBound: CGFloat) -> CGFloat {
        guard lowerBound <= upperBound else { return lowerBound }
        return min(max(value, lowerBound), upperBound)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private let launchAtLoginController = LaunchAtLoginController()
    private let trafficMonitor = NetworkTrafficMonitor()
    private let processTrafficMonitor = ProcessTrafficMonitor()
    private let downloadAlertMonitor = DownloadAlertMonitor()
    private let appTrafficHistoryStore = AppTrafficHistoryStore()
    private var settingsPanel: FloatingPanel?
    private var historyWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private weak var statusItemIconView: NSImageView?
    private weak var statusItemTrafficStackView: NSStackView?
    private weak var statusItemSingleTrafficStackView: NSStackView?
    private weak var statusItemStatusLabel: NSTextField?
    private weak var statusItemDownloadSpeedLabel: NSTextField?
    private weak var statusItemUploadSpeedLabel: NSTextField?
    private weak var statusItemSingleDirectionLabel: NSTextField?
    private weak var statusItemSingleSpeedLabel: NSTextField?
    private var statusItemTrafficWidthConstraint: NSLayoutConstraint?
    private var statusItemSingleTrafficWidthConstraint: NSLayoutConstraint?
    private var cancellables = Set<AnyCancellable>()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        trafficMonitor.menuBarDisplayMode = preferences.menuBarDisplayMode
        trafficMonitor.selectedInterfaceName = preferences.selectedInterfaceName
        trafficMonitor.samplingInterval = preferences.refreshIntervalOption.interval
        trafficMonitor.restoreCachedDisplayState(
            menuBarTitle: preferences.lastMenuBarTitle,
            connectionLabel: preferences.lastConnectionLabel,
            interfaceSummary: preferences.lastInterfaceSummary
        )
        configureSettingsPanel()
        configureStatusItem()
        configureAppTrafficHistoryRecorder()
        bindMenuBarContent()
        bindPreferences()
        bindLifecycleEvents()
        trafficMonitor.start()
        updateProcessTrafficSampling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appTrafficHistoryStore.flush()
        trafficMonitor.stop()
        processTrafficMonitor.stop()
    }

    private func configureSettingsPanel() {
        let hostingController = NSHostingController(
            rootView: StatusPopoverView(
                monitor: trafficMonitor,
                processMonitor: processTrafficMonitor,
                downloadAlertMonitor: downloadAlertMonitor,
                preferences: preferences,
                launchAtLoginController: launchAtLoginController,
                onShowHistory: { [weak self] in
                    self?.showTrafficHistoryWindow()
                },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )

        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: SettingsPanelLayout.preferredSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hostingController
        settingsPanel = panel
    }

    private func configureAppTrafficHistoryRecorder() {
        processTrafficMonitor.appTrafficSampleHandler = { [weak self] entries, date, sampleInterval in
            guard let self, self.preferences.appTrafficHistoryEnabled else { return }
            self.appTrafficHistoryStore.record(
                entries: entries,
                at: date,
                sampleInterval: sampleInterval
            )
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(toggleSettingsPanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.lineBreakMode = .byClipping
        button.title = ""
        button.image = nil
        configureStatusItemContent(in: button)
        applyStatusContent(trafficMonitor.menuBarContent, to: button)
    }

    private func bindMenuBarContent() {
        trafficMonitor.$menuBarContent
            .receive(on: RunLoop.main)
            .sink { [weak self] content in
                guard let button = self?.statusItem?.button else { return }
                self?.applyStatusContent(content, to: button)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            trafficMonitor.$connectionLabel,
            trafficMonitor.$interfaceSummary
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] connectionLabel, interfaceSummary in
            guard let self else { return }
            self.preferences.saveDisplayState(
                menuBarTitle: self.trafficMonitor.menuBarTitle,
                connectionLabel: connectionLabel,
                interfaceSummary: interfaceSummary
            )
        }
        .store(in: &cancellables)
    }

    private func bindPreferences() {
        preferences.$menuBarDisplayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] displayMode in
                self?.trafficMonitor.menuBarDisplayMode = displayMode
                guard let button = self?.statusItem?.button else { return }
                self?.applyStatusContent(self?.trafficMonitor.menuBarContent ?? .status("离线"), to: button)
            }
            .store(in: &cancellables)

        preferences.$selectedInterfaceName
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedInterfaceName in
                guard self?.trafficMonitor.selectedInterfaceName != selectedInterfaceName else { return }
                self?.trafficMonitor.selectedInterfaceName = selectedInterfaceName
            }
            .store(in: &cancellables)

        trafficMonitor.$selectedInterfaceName
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedInterfaceName in
                guard self?.preferences.selectedInterfaceName != selectedInterfaceName else { return }
                self?.preferences.selectedInterfaceName = selectedInterfaceName
            }
            .store(in: &cancellables)

        preferences.$refreshIntervalOption
            .receive(on: RunLoop.main)
            .sink { [weak self] refreshIntervalOption in
                self?.trafficMonitor.samplingInterval = refreshIntervalOption.interval
            }
            .store(in: &cancellables)

        preferences.$appTrafficHistoryEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if !isEnabled {
                    self.appTrafficHistoryStore.flush()
                }
                self.updateProcessTrafficSampling()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            preferences.$downloadAlertEnabled,
            preferences.$downloadAlertThreshold,
            preferences.$downloadAlertCooldown,
            preferences.$downloadAlertDuration
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] enabled, threshold, cooldown, duration in
            self?.downloadAlertMonitor.updateConfiguration(
                enabled: enabled,
                thresholdBytesPerSecond: threshold.bytesPerSecond,
                cooldownInterval: cooldown.interval,
                requiredDuration: duration.interval
            )
        }
        .store(in: &cancellables)

        Publishers.CombineLatest(
            trafficMonitor.$downloadBytesPerSecond,
            trafficMonitor.$samplingInterval
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] downloadBytesPerSecond, samplingInterval in
            self?.downloadAlertMonitor.evaluate(
                downloadBytesPerSecond: downloadBytesPerSecond,
                sampleInterval: samplingInterval
            )
        }
        .store(in: &cancellables)
    }

    private func bindLifecycleEvents() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.trafficMonitor.handleSystemWillSleep()
                self?.processTrafficMonitor.pauseForSleep()
                self?.appTrafficHistoryStore.flush()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.trafficMonitor.handleSystemDidWake()
                self?.updateProcessTrafficSampling()
                self?.launchAtLoginController.refreshStatus()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.trafficMonitor.refreshNow()
                self?.launchAtLoginController.refreshStatus()
                Task { [weak self] in
                    await self?.downloadAlertMonitor.refreshAuthorizationStatus()
                }
            }
            .store(in: &cancellables)
    }

    private func configureStatusItemContent(in button: NSStatusBarButton) {
        button.subviews.forEach { $0.removeFromSuperview() }
        statusItemTrafficWidthConstraint = nil
        statusItemSingleTrafficWidthConstraint = nil

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = statusItemIconImage()

        let downloadRow = makeStatusTrafficRow(direction: .download)
        let uploadRow = makeStatusTrafficRow(direction: .upload)

        let trafficStackView = NSStackView(views: [downloadRow.row, uploadRow.row])
        trafficStackView.translatesAutoresizingMaskIntoConstraints = false
        trafficStackView.orientation = .vertical
        trafficStackView.alignment = .leading
        trafficStackView.distribution = .fillEqually
        trafficStackView.spacing = MenuBarStatusLayout.trafficLineSpacing
        trafficStackView.setContentCompressionResistancePriority(.required, for: .horizontal)
        trafficStackView.setContentHuggingPriority(.required, for: .horizontal)

        let singleRow = makeStatusTrafficRow(direction: .download)
        let singleTrafficStackView = singleRow.row
        singleTrafficStackView.translatesAutoresizingMaskIntoConstraints = false
        singleTrafficStackView.setContentCompressionResistancePriority(.required, for: .horizontal)
        singleTrafficStackView.setContentHuggingPriority(.required, for: .horizontal)
        singleTrafficStackView.isHidden = true

        let statusLabel = makeStatusItemLabel(font: MenuBarStatusLayout.statusFont)
        statusLabel.isHidden = true

        let stackView = NSStackView(views: [iconView, trafficStackView, singleTrafficStackView, statusLabel])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = MenuBarStatusLayout.contentSpacing
        stackView.detachesHiddenViews = true

        button.addSubview(stackView)

        let trafficWidthConstraint = trafficStackView.widthAnchor.constraint(equalToConstant: MenuBarStatusLayout.trafficRowWidth)
        let singleTrafficWidthConstraint = singleTrafficStackView.widthAnchor.constraint(equalToConstant: MenuBarStatusLayout.trafficRowWidth)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: MenuBarStatusLayout.iconSize.width),
            iconView.heightAnchor.constraint(equalToConstant: MenuBarStatusLayout.iconSize.height),
            trafficWidthConstraint,
            singleTrafficWidthConstraint,
            stackView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: MenuBarStatusLayout.contentLeadingPadding),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -MenuBarStatusLayout.contentTrailingPadding),
            stackView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        statusItemIconView = iconView
        statusItemTrafficStackView = trafficStackView
        statusItemSingleTrafficStackView = singleTrafficStackView
        statusItemStatusLabel = statusLabel
        statusItemDownloadSpeedLabel = downloadRow.speedLabel
        statusItemUploadSpeedLabel = uploadRow.speedLabel
        statusItemSingleDirectionLabel = singleRow.directionLabel
        statusItemSingleSpeedLabel = singleRow.speedLabel
        statusItemTrafficWidthConstraint = trafficWidthConstraint
        statusItemSingleTrafficWidthConstraint = singleTrafficWidthConstraint
    }

    private func makeStatusTrafficRow(direction: MenuBarTrafficDirection) -> (
        row: NSStackView,
        directionLabel: NSTextField,
        speedLabel: NSTextField
    ) {
        let directionLabel = makeStatusItemLabel(font: MenuBarStatusLayout.trafficDirectionFont, alignment: .center)
        directionLabel.stringValue = direction.symbol

        let speedLabel = makeStatusItemLabel(font: MenuBarStatusLayout.trafficFont, alignment: .right)

        let row = NSStackView(views: [directionLabel, speedLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MenuBarStatusLayout.trafficRowSpacing
        row.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            directionLabel.widthAnchor.constraint(equalToConstant: MenuBarStatusLayout.trafficDirectionWidth),
            speedLabel.widthAnchor.constraint(equalToConstant: MenuBarStatusLayout.trafficSpeedWidth),
        ])

        return (row, directionLabel, speedLabel)
    }

    private func makeStatusItemLabel(font: NSFont, alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = alignment
        label.font = font
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func applyStatusContent(_ content: MenuBarStatusContent, to button: NSStatusBarButton) {
        switch content {
        case let .traffic(download, upload):
            statusItemDownloadSpeedLabel?.stringValue = download
            statusItemUploadSpeedLabel?.stringValue = upload
            statusItemTrafficWidthConstraint?.constant = MenuBarStatusLayout.trafficRowWidth
            statusItemTrafficStackView?.isHidden = false
            statusItemSingleTrafficStackView?.isHidden = true
            statusItemStatusLabel?.isHidden = true

        case let .singleTraffic(direction, speed):
            statusItemSingleDirectionLabel?.stringValue = direction.symbol
            statusItemSingleSpeedLabel?.stringValue = speed
            statusItemSingleTrafficWidthConstraint?.constant = MenuBarStatusLayout.trafficRowWidth
            statusItemTrafficStackView?.isHidden = true
            statusItemSingleTrafficStackView?.isHidden = false
            statusItemStatusLabel?.isHidden = true

        case let .status(title):
            statusItemStatusLabel?.stringValue = title
            statusItemTrafficStackView?.isHidden = true
            statusItemSingleTrafficStackView?.isHidden = true
            statusItemStatusLabel?.isHidden = false
        }

        button.toolTip = content.displayTitle
        statusItem?.length = statusItemLength(for: content)
        button.needsLayout = true
    }

    @objc
    private func toggleSettingsPanel(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let settingsPanel else { return }

        if settingsPanel.isVisible {
            closeSettingsPanel()
            return
        }

        trafficMonitor.refreshNow()
        launchAtLoginController.refreshStatus()
        processTrafficMonitor.startWarmSampling()
        processTrafficMonitor.refreshFreshnessState()
        positionSettingsPanel(relativeTo: button, panel: settingsPanel)
        settingsPanel.orderFrontRegardless()
        settingsPanel.makeKey()
        installOutsideClickMonitors()
    }

    private func statusItemLength(for content: MenuBarStatusContent) -> CGFloat {
        MenuBarStatusLayout.itemLength(for: content)
    }

    private func statusItemIconImage() -> NSImage? {
        let iconImage = NSImage(size: MenuBarStatusLayout.iconSize)
        iconImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let canvas = NSRect(origin: .zero, size: MenuBarStatusLayout.iconSize)
        let insetX = MenuBarStatusLayout.iconSize.width * 0.055
        let insetY = MenuBarStatusLayout.iconSize.height * 0.065
        let drawingRect = canvas.insetBy(dx: insetX, dy: insetY)
        let strokeColor = NSColor.labelColor

        let tilePath = NSBezierPath(
            roundedRect: drawingRect,
            xRadius: drawingRect.width * 0.27,
            yRadius: drawingRect.height * 0.27
        )
        tilePath.lineWidth = 1.3
        tilePath.lineJoinStyle = .round
        strokeColor.withAlphaComponent(0.88).setStroke()
        tilePath.stroke()

        let innerRect = drawingRect.insetBy(dx: drawingRect.width * 0.12, dy: drawingRect.height * 0.16)
        let baselineY = innerRect.midY
        let pulsePath = NSBezierPath()
        pulsePath.move(to: NSPoint(x: innerRect.minX, y: baselineY))
        pulsePath.line(to: NSPoint(x: innerRect.minX + innerRect.width * 0.17, y: baselineY))
        pulsePath.line(to: NSPoint(x: innerRect.minX + innerRect.width * 0.34, y: innerRect.maxY - innerRect.height * 0.06))
        pulsePath.line(to: NSPoint(x: innerRect.minX + innerRect.width * 0.49, y: innerRect.minY + innerRect.height * 0.14))
        pulsePath.line(to: NSPoint(x: innerRect.minX + innerRect.width * 0.65, y: innerRect.maxY - innerRect.height * 0.26))
        pulsePath.line(to: NSPoint(x: innerRect.minX + innerRect.width * 0.83, y: baselineY))
        pulsePath.line(to: NSPoint(x: innerRect.maxX, y: baselineY))
        pulsePath.lineWidth = 1.5
        pulsePath.lineCapStyle = .round
        pulsePath.lineJoinStyle = .round
        strokeColor.setStroke()
        pulsePath.stroke()

        iconImage.unlockFocus()
        iconImage.isTemplate = true
        return iconImage
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopoverIfNeeded()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopoverIfNeeded()
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func closePopoverIfNeeded() {
        guard settingsPanel?.isVisible == true else { return }

        let mouseLocation = NSEvent.mouseLocation
        let isInsidePanel = settingsPanel?.frame.contains(mouseLocation) ?? false
        let isInsideStatusItem = statusItemScreenFrame()?.contains(mouseLocation) ?? false

        if !isInsidePanel && !isInsideStatusItem {
            closeSettingsPanel()
        }
    }

    private func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonFrameInWindow)
    }

    private func positionSettingsPanel(relativeTo button: NSStatusBarButton, panel: NSPanel) {
        guard let buttonFrameOnScreen = statusItemScreenFrame() else { return }

        let screenFrame = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelFrame = SettingsPanelLayout.panelFrame(
            relativeTo: buttonFrameOnScreen,
            visibleFrame: screenFrame
        )

        panel.setFrame(panelFrame, display: false)
    }

    private func closeSettingsPanel() {
        settingsPanel?.orderOut(nil)
        removeOutsideClickMonitors()
        updateProcessTrafficSampling()
    }

    private func updateProcessTrafficSampling() {
        if preferences.appTrafficHistoryEnabled || settingsPanel?.isVisible == true {
            processTrafficMonitor.startWarmSampling()
        } else if processTrafficMonitor.samplingState != .idle {
            processTrafficMonitor.stop(clearEntries: false)
        }
    }

    private func showTrafficHistoryWindow() {
        let window = historyWindow ?? makeTrafficHistoryWindow()
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeTrafficHistoryWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppTrafficHistoryWindowView(store: appTrafficHistoryStore)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "流量历史"
        window.minSize = NSSize(width: 700, height: 480)
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.center()
        return window
    }

}
