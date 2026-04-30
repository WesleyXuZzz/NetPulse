import Foundation

enum SpeedFormatter {
    static func menuBar(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, unitStyle: .menuBar, trimsTrailingZero: true)
    }

    static func short(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, unitStyle: .compact, trimsTrailingZero: false)
    }

    static func shortPerSecond(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, unitStyle: .menuBar, trimsTrailingZero: false)
    }

    static func detailed(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, unitStyle: .expanded, trimsTrailingZero: false)
    }

    private static func format(_ bytesPerSecond: Double, unitStyle: UnitStyle, trimsTrailingZero: Bool) -> String {
        let safeValue = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        if safeValue < 1 {
            return unitStyle.zeroLabel
        }

        let units = unitStyle.units
        var value = safeValue
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitStyle == .menuBar, value >= 999.5, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitStyle == .menuBar, value >= 999.5, unitIndex == units.count - 1 {
            return "999\(units[unitIndex])"
        }

        let decimals: Int
        switch value {
        case 0..<10:
            decimals = unitStyle == .menuBar ? 1 : (unitIndex == 0 ? 0 : 1)
        case 10..<100:
            decimals = 1
        default:
            decimals = 0
        }

        let formattedValue = value.formatted(.number.precision(.fractionLength(decimals)))
        let displayValue = trimsTrailingZero ? formattedValue.replacingOccurrences(of: ".0", with: "") : formattedValue
        return "\(displayValue)\(units[unitIndex])"
    }

    private enum UnitStyle {
        case compact
        case menuBar
        case expanded

        var units: [String] {
            switch self {
            case .compact:
                return ["B", "K", "M", "G", "T", "P"]
            case .menuBar:
                return ["B/s", "K/s", "M/s", "G/s", "T/s", "P/s"]
            case .expanded:
                return [" B/s", " K/s", " M/s", " G/s", " T/s", " P/s"]
            }
        }

        var zeroLabel: String {
            switch self {
            case .compact:
                return "0K"
            case .menuBar:
                return "0K/s"
            case .expanded:
                return "0 K/s"
            }
        }
    }
}
