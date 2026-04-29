import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var detailText: String?
    @Published private(set) var needsApproval = false

    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    init() {
        refreshStatus()
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else {
            detailText = "把 NetPulse.app 打包后再打开，这个选项才可用。"
            isEnabled = false
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            detailText = enabled ? "NetPulse 会在你登录 macOS 后尝试自动启动。" : nil
        } catch {
            detailText = "macOS 更新登录项设置失败：\(error.localizedDescription)"
        }

        refreshStatus()
    }

    func refreshStatus() {
        guard isAvailable else {
            isEnabled = false
            needsApproval = false
            detailText = "先打包成 NetPulse.app，才能使用自动启动。"
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            needsApproval = false
            if detailText == nil {
                detailText = "NetPulse 已加入系统登录项。"
            }
        case .requiresApproval:
            isEnabled = false
            needsApproval = true
            detailText = "macOS 正在等待你在“系统设置 > 通用 > 登录项”里批准。"
        case .notFound, .notRegistered:
            isEnabled = false
            needsApproval = false
            if detailText == nil || detailText == "NetPulse 已加入系统登录项。" {
                detailText = nil
            }
        @unknown default:
            isEnabled = false
            needsApproval = false
            detailText = "macOS 返回了未知的登录项状态。"
        }
    }

    func openLoginItemsSettings() {
        guard isAvailable else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
