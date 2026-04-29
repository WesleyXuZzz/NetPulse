import AppKit
import Foundation
import UserNotifications

enum DownloadAlertThresholdOption: Double, CaseIterable, Identifiable {
    case oneMB = 1_048_576
    case twoMB = 2_097_152
    case fourMB = 4_194_304
    case fiveMB = 5_242_880
    case tenMB = 10_485_760

    var id: Double { rawValue }

    var bytesPerSecond: Double { rawValue }

    var title: String {
        switch self {
        case .oneMB:
            return "1 M/s"
        case .twoMB:
            return "2 M/s"
        case .fourMB:
            return "4 M/s"
        case .fiveMB:
            return "5 M/s"
        case .tenMB:
            return "10 M/s"
        }
    }
}

enum DownloadAlertCooldownOption: Double, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1800

    var id: Double { rawValue }

    var interval: TimeInterval { rawValue }

    var title: String {
        switch self {
        case .oneMinute:
            return "1 分钟"
        case .fiveMinutes:
            return "5 分钟"
        case .tenMinutes:
            return "10 分钟"
        case .thirtyMinutes:
            return "30 分钟"
        }
    }
}

enum DownloadAlertDurationOption: Double, CaseIterable, Identifiable {
    case tenSeconds = 10
    case twentySeconds = 20
    case thirtySeconds = 30
    case sixtySeconds = 60

    var id: Double { rawValue }

    var interval: TimeInterval { rawValue }

    var title: String {
        switch self {
        case .tenSeconds:
            return "10 秒"
        case .twentySeconds:
            return "20 秒"
        case .thirtySeconds:
            return "30 秒"
        case .sixtySeconds:
            return "60 秒"
        }
    }
}

@MainActor
final class DownloadAlertMonitor: ObservableObject {
    @Published private(set) var detailText = "开启后，当下载速度连续 20 秒高于阈值时会发送系统通知。"
    @Published private(set) var authorizationState: AuthorizationState = .unknown

    private let notificationCenter = UNUserNotificationCenter.current()

    private var isEnabled = false
    private var thresholdBytesPerSecond: Double = DownloadAlertThresholdOption.oneMB.bytesPerSecond
    private var cooldownInterval: TimeInterval = DownloadAlertCooldownOption.oneMinute.interval
    private var requiredDuration: TimeInterval = DownloadAlertDurationOption.twentySeconds.interval
    private var consecutiveAboveThresholdDuration: TimeInterval = 0
    private var lastNotificationAt: Date?

    enum AuthorizationState: Equatable {
        case unknown
        case authorized
        case denied
    }

    func updateConfiguration(
        enabled: Bool,
        thresholdBytesPerSecond: Double,
        cooldownInterval: TimeInterval,
        requiredDuration: TimeInterval
    ) {
        let didChangeEnabled = isEnabled != enabled
        let didChangeThreshold = self.thresholdBytesPerSecond != thresholdBytesPerSecond
        let didChangeCooldown = self.cooldownInterval != cooldownInterval
        let didChangeDuration = self.requiredDuration != requiredDuration

        isEnabled = enabled
        self.thresholdBytesPerSecond = thresholdBytesPerSecond
        self.cooldownInterval = cooldownInterval
        self.requiredDuration = requiredDuration

        if !enabled || didChangeEnabled || didChangeThreshold || didChangeCooldown || didChangeDuration {
            resetEvaluationState()
        }

        if enabled {
            Task {
                await refreshAuthorizationStatus()

                if authorizationState == .unknown {
                    await requestAuthorization()
                } else {
                    updateDetailText()
                }
            }
        } else {
            updateDetailText()
        }
    }

    func evaluate(downloadBytesPerSecond: Double, sampleInterval: TimeInterval) {
        guard isEnabled else { return }
        guard authorizationState == .authorized else { return }

        let now = Date()
        if let lastNotificationAt, now.timeIntervalSince(lastNotificationAt) < cooldownInterval {
            consecutiveAboveThresholdDuration = 0
            return
        }

        guard downloadBytesPerSecond >= thresholdBytesPerSecond else {
            consecutiveAboveThresholdDuration = 0
            return
        }

        consecutiveAboveThresholdDuration += sampleInterval
        guard consecutiveAboveThresholdDuration >= requiredDuration else { return }

        sendNotification(currentSpeed: downloadBytesPerSecond)
        lastNotificationAt = now
        consecutiveAboveThresholdDuration = 0
        updateDetailText()
    }

    func resetEvaluationState() {
        consecutiveAboveThresholdDuration = 0
        lastNotificationAt = nil
    }

    func refreshAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationState = .authorized
        case .denied:
            authorizationState = .denied
        case .notDetermined:
            authorizationState = .unknown
        @unknown default:
            authorizationState = .unknown
        }

        updateDetailText()
    }

    func requestAuthorization() async {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            authorizationState = granted ? .authorized : .denied
        } catch {
            authorizationState = .denied
        }

        updateDetailText()
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    private func sendNotification(currentSpeed: Double) {
        let content = UNMutableNotificationContent()
        content.title = "NetPulse 高速下载提醒"
        content.body = "下载速度已连续 \(durationLabel) 高于 \(SpeedFormatter.shortPerSecond(thresholdBytesPerSecond))，当前约 \(SpeedFormatter.shortPerSecond(currentSpeed))。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.netpulse.download-alert.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        notificationCenter.add(request)
    }

    private func updateDetailText() {
        guard isEnabled else {
            detailText = "开启后，当下载速度连续 \(durationLabel) 高于阈值时会发送系统通知。"
            return
        }

        switch authorizationState {
        case .authorized:
            detailText = "已启用：下载速度连续 \(durationLabel) 高于 \(SpeedFormatter.shortPerSecond(thresholdBytesPerSecond)) 时提醒，冷却 \(cooldownLabel)。"
        case .denied:
            detailText = "未获得通知权限，NetPulse 目前无法发送系统提醒。"
        case .unknown:
            detailText = "首次启用会请求系统通知权限。"
        }
    }

    private var cooldownLabel: String {
        if let matchedOption = DownloadAlertCooldownOption.allCases.first(where: { $0.interval == cooldownInterval }) {
            return matchedOption.title
        }

        return "\(Int(cooldownInterval / 60)) 分钟"
    }

    private var durationLabel: String {
        if let matchedOption = DownloadAlertDurationOption.allCases.first(where: { $0.interval == requiredDuration }) {
            return matchedOption.title
        }

        return "\(Int(requiredDuration)) 秒"
    }
}
