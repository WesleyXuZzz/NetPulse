import AppKit
import Combine
import SwiftUI

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private let launchAtLoginController = LaunchAtLoginController()
    private let trafficMonitor = NetworkTrafficMonitor()
    private let processTrafficMonitor = ProcessTrafficMonitor()
    private let downloadAlertMonitor = DownloadAlertMonitor()
    private var settingsPanel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private weak var statusItemIconView: NSImageView?
    private weak var statusItemTitleLabel: NSTextField?
    private var cancellables = Set<AnyCancellable>()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private let statusItemIconSize = NSSize(width: 16, height: 16)
    private let statusItemAdaptiveWidthStep: CGFloat = 10
    private let statusItemContentLeadingPadding: CGFloat = 6
    private let statusItemContentTrailingPadding: CGFloat = 6
    private let statusItemContentSpacing: CGFloat = 5

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
        bindMenuBarTitle()
        bindPreferences()
        bindLifecycleEvents()
        trafficMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 392, height: 800),
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
        applyStatusTitle(trafficMonitor.menuBarTitle, to: button)
    }

    private func bindMenuBarTitle() {
        trafficMonitor.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                guard let button = self?.statusItem?.button else { return }
                self?.applyStatusTitle(title, to: button)
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
                self?.applyStatusTitle(self?.trafficMonitor.menuBarTitle ?? "", to: button)
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
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.trafficMonitor.handleSystemDidWake()
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

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = statusItemIconImage()

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byClipping
        titleLabel.maximumNumberOfLines = 1

        let stackView = NSStackView(views: [iconView, titleLabel])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = statusItemContentSpacing

        button.addSubview(stackView)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: statusItemIconSize.width),
            iconView.heightAnchor.constraint(equalToConstant: statusItemIconSize.height),
            stackView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: statusItemContentLeadingPadding),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -statusItemContentTrailingPadding),
            stackView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        statusItemIconView = iconView
        statusItemTitleLabel = titleLabel
    }

    private func applyStatusTitle(_ title: String, to button: NSStatusBarButton) {
        statusItemTitleLabel?.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: statusItemFont,
            ]
        )
        statusItem?.length = statusItemLength(for: title, displayMode: preferences.menuBarDisplayMode)
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
        processTrafficMonitor.start()
        positionSettingsPanel(relativeTo: button, panel: settingsPanel)
        settingsPanel.orderFrontRegardless()
        settingsPanel.makeKey()
        installOutsideClickMonitors()
    }

    private func statusItemLength(for title: String, displayMode: MenuBarDisplayMode) -> CGFloat {
        let minimumTemplate: String
        switch displayMode {
        case .both:
            minimumTemplate = "↓999M/s ↑999M/s"
        case .downloadOnly, .uploadOnly:
            minimumTemplate = "999M/s"
        }

        let templateWidth = (minimumTemplate as NSString).size(withAttributes: [.font: statusItemFont]).width
        let titleWidth = (title as NSString).size(withAttributes: [.font: statusItemFont]).width
        let contentWidth = statusItemIconSize.width + statusItemContentSpacing
        let horizontalPadding = statusItemContentLeadingPadding + statusItemContentTrailingPadding
        let minimumWidth = ceil(templateWidth + contentWidth + horizontalPadding)
        let requiredWidth = ceil(titleWidth + contentWidth + horizontalPadding)

        guard requiredWidth > minimumWidth else {
            return minimumWidth
        }

        let overflow = requiredWidth - minimumWidth
        let steppedOverflow = ceil(overflow / statusItemAdaptiveWidthStep) * statusItemAdaptiveWidthStep
        return minimumWidth + steppedOverflow
    }

    private func statusItemIconImage() -> NSImage? {
        let iconImage = NSImage(size: statusItemIconSize)
        iconImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let canvas = NSRect(origin: .zero, size: statusItemIconSize)
        let insetX = statusItemIconSize.width * 0.055
        let insetY = statusItemIconSize.height * 0.065
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

        let panelSize = panel.frame.size
        let screenFrame = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8

        let originX = min(
            max(buttonFrameOnScreen.midX - (panelSize.width / 2), screenFrame.minX + 8),
            screenFrame.maxX - panelSize.width - 8
        )
        let originY = max(screenFrame.minY + 8, buttonFrameOnScreen.minY - panelSize.height - gap)

        panel.setFrame(NSRect(x: originX, y: originY, width: panelSize.width, height: panelSize.height), display: false)
    }

    private func closeSettingsPanel() {
        settingsPanel?.orderOut(nil)
        processTrafficMonitor.stop()
        removeOutsideClickMonitors()
    }

    private var statusItemFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    }
}
