import AppKit

@MainActor
enum MenuBarStatusLayout {
    static let iconSize = NSSize(width: 16, height: 16)
    static let contentLeadingPadding: CGFloat = 6
    static let contentTrailingPadding: CGFloat = 6
    static let contentSpacing: CGFloat = 5
    static let trafficRowSpacing: CGFloat = 1
    static let trafficLineSpacing: CGFloat = -1

    static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    static let trafficFont = NSFont.monospacedDigitSystemFont(ofSize: 8.3, weight: .semibold)
    static let trafficDirectionFont = NSFont.systemFont(ofSize: 8.2, weight: .semibold)

    static var trafficDirectionWidth: CGFloat {
        max(
            textWidth(MenuBarTrafficDirection.download.symbol, font: trafficDirectionFont),
            textWidth(MenuBarTrafficDirection.upload.symbol, font: trafficDirectionFont)
        )
    }

    static var trafficSpeedWidth: CGFloat {
        textWidth("99.9P/s", font: trafficFont)
    }

    static var trafficRowWidth: CGFloat {
        ceil(trafficDirectionWidth + trafficRowSpacing + trafficSpeedWidth)
    }

    static func itemLength(for content: MenuBarStatusContent) -> CGFloat {
        let labelWidth: CGFloat
        switch content {
        case .traffic, .singleTraffic:
            labelWidth = trafficRowWidth
        case let .status(title):
            labelWidth = textWidth(title, font: statusFont)
        }

        return ceil(iconSize.width + contentSpacing + labelWidth + horizontalPadding)
    }

    private static var horizontalPadding: CGFloat {
        contentLeadingPadding + contentTrailingPadding
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
