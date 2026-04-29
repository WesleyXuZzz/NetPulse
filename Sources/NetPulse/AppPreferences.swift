import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case both
    case downloadOnly
    case uploadOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both:
            return "上下行"
        case .downloadOnly:
            return "下行"
        case .uploadOnly:
            return "上行"
        }
    }
}

enum RefreshIntervalOption: Double, CaseIterable, Identifiable {
    case halfSecond = 0.5
    case oneSecond = 1.0
    case twoSeconds = 2.0

    var id: Double { rawValue }

    var interval: TimeInterval { rawValue }

    var title: String {
        switch self {
        case .halfSecond:
            return "0.5 秒"
        case .oneSecond:
            return "1 秒"
        case .twoSeconds:
            return "2 秒"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet {
            defaults.set(menuBarDisplayMode.rawValue, forKey: Keys.menuBarDisplayMode)
        }
    }
    @Published var selectedInterfaceName: String? {
        didSet {
            defaults.set(selectedInterfaceName, forKey: Keys.selectedInterfaceName)
        }
    }
    @Published var refreshIntervalOption: RefreshIntervalOption {
        didSet {
            defaults.set(refreshIntervalOption.rawValue, forKey: Keys.refreshIntervalOption)
        }
    }
    @Published var downloadAlertEnabled: Bool {
        didSet {
            defaults.set(downloadAlertEnabled, forKey: Keys.downloadAlertEnabled)
        }
    }
    @Published var downloadAlertThreshold: DownloadAlertThresholdOption {
        didSet {
            defaults.set(downloadAlertThreshold.rawValue, forKey: Keys.downloadAlertThreshold)
        }
    }
    @Published var downloadAlertCooldown: DownloadAlertCooldownOption {
        didSet {
            defaults.set(downloadAlertCooldown.rawValue, forKey: Keys.downloadAlertCooldown)
        }
    }
    @Published var downloadAlertDuration: DownloadAlertDurationOption {
        didSet {
            defaults.set(downloadAlertDuration.rawValue, forKey: Keys.downloadAlertDuration)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedDisplayMode = defaults.string(forKey: Keys.menuBarDisplayMode)
        menuBarDisplayMode = MenuBarDisplayMode(rawValue: storedDisplayMode ?? "") ?? .both
        selectedInterfaceName = defaults.string(forKey: Keys.selectedInterfaceName)

        let storedRefreshInterval = defaults.double(forKey: Keys.refreshIntervalOption)
        refreshIntervalOption = RefreshIntervalOption(rawValue: storedRefreshInterval) ?? .halfSecond

        downloadAlertEnabled = defaults.bool(forKey: Keys.downloadAlertEnabled)

        let storedDownloadAlertThreshold = defaults.double(forKey: Keys.downloadAlertThreshold)
        downloadAlertThreshold = DownloadAlertThresholdOption(rawValue: storedDownloadAlertThreshold) ?? .oneMB

        let storedDownloadAlertCooldown = defaults.double(forKey: Keys.downloadAlertCooldown)
        downloadAlertCooldown = DownloadAlertCooldownOption(rawValue: storedDownloadAlertCooldown) ?? .oneMinute

        let storedDownloadAlertDuration = defaults.double(forKey: Keys.downloadAlertDuration)
        downloadAlertDuration = DownloadAlertDurationOption(rawValue: storedDownloadAlertDuration) ?? .twentySeconds
    }

    var lastMenuBarTitle: String {
        defaults.string(forKey: Keys.lastMenuBarTitle) ?? "离线"
    }

    var lastConnectionLabel: String {
        defaults.string(forKey: Keys.lastConnectionLabel) ?? "检查中"
    }

    var lastInterfaceSummary: String {
        defaults.string(forKey: Keys.lastInterfaceSummary) ?? "--"
    }

    func saveDisplayState(menuBarTitle: String, connectionLabel: String, interfaceSummary: String) {
        defaults.set(menuBarTitle, forKey: Keys.lastMenuBarTitle)
        defaults.set(connectionLabel, forKey: Keys.lastConnectionLabel)
        defaults.set(interfaceSummary, forKey: Keys.lastInterfaceSummary)
    }
}

private enum Keys {
    static let menuBarDisplayMode = "menuBarDisplayMode"
    static let selectedInterfaceName = "selectedInterfaceName"
    static let refreshIntervalOption = "refreshIntervalOption"
    static let downloadAlertEnabled = "downloadAlertEnabled"
    static let downloadAlertThreshold = "downloadAlertThreshold"
    static let downloadAlertCooldown = "downloadAlertCooldown"
    static let downloadAlertDuration = "downloadAlertDuration"
    static let lastMenuBarTitle = "lastMenuBarTitle"
    static let lastConnectionLabel = "lastConnectionLabel"
    static let lastInterfaceSummary = "lastInterfaceSummary"
}
