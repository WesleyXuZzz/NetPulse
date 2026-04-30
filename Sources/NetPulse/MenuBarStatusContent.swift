import Foundation

enum MenuBarTrafficDirection: Equatable {
    case download
    case upload

    var symbol: String {
        switch self {
        case .download:
            return "↓"
        case .upload:
            return "↑"
        }
    }
}

enum MenuBarStatusContent: Equatable {
    case traffic(download: String, upload: String)
    case singleTraffic(direction: MenuBarTrafficDirection, speed: String)
    case status(String)

    static func make(
        isSleeping: Bool,
        isNetworkAvailable: Bool,
        displayMode: MenuBarDisplayMode,
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double
    ) -> MenuBarStatusContent {
        if isSleeping {
            return .status("睡眠")
        }

        if !isNetworkAvailable {
            return .status("离线")
        }

        switch displayMode {
        case .both:
            return .traffic(
                download: SpeedFormatter.menuBar(downloadBytesPerSecond),
                upload: SpeedFormatter.menuBar(uploadBytesPerSecond)
            )
        case .downloadOnly:
            return .singleTraffic(
                direction: .download,
                speed: SpeedFormatter.menuBar(downloadBytesPerSecond)
            )
        case .uploadOnly:
            return .singleTraffic(
                direction: .upload,
                speed: SpeedFormatter.menuBar(uploadBytesPerSecond)
            )
        }
    }

    static func restored(title: String, displayMode: MenuBarDisplayMode) -> MenuBarStatusContent {
        if title == "离线" || title == "睡眠" {
            return .status(title)
        }

        switch displayMode {
        case .both:
            return restoredTraffic(title: title) ?? .status(title)
        case .downloadOnly:
            return title.isEmpty ? .status("离线") : .singleTraffic(direction: .download, speed: title)
        case .uploadOnly:
            return title.isEmpty ? .status("离线") : .singleTraffic(direction: .upload, speed: title)
        }
    }

    private static func restoredTraffic(title: String) -> MenuBarStatusContent? {
        guard title.hasPrefix("↓") else { return nil }

        let content = title.dropFirst()
        guard let separatorRange = content.range(of: " ↑") else { return nil }

        let download = String(content[..<separatorRange.lowerBound])
        let upload = String(content[separatorRange.upperBound...])
        guard !download.isEmpty, !upload.isEmpty else { return nil }
        return .traffic(download: download, upload: upload)
    }

    var displayTitle: String {
        switch self {
        case let .traffic(download, upload):
            return "↓\(download) ↑\(upload)"
        case let .singleTraffic(direction, speed):
            return "\(direction.symbol)\(speed)"
        case let .status(title):
            return title
        }
    }

    var legacyTitle: String {
        switch self {
        case .traffic:
            return displayTitle
        case let .singleTraffic(_, speed):
            return speed
        case let .status(title):
            return title
        }
    }
}
