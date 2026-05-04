import Charts
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var monitor: NetworkTrafficMonitor
    @ObservedObject var processMonitor: ProcessTrafficMonitor
    @ObservedObject var downloadAlertMonitor: DownloadAlertMonitor
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    let onShowHistory: () -> Void
    let onQuit: () -> Void
    @State private var showsFullInterfaceSummary = false

    var body: some View {
        let chartSnapshot = StatusChartSnapshot(points: monitor.history)

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NetPulse")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(headerSummary)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(fullHeaderSummary)

                            if canExpandInterfaceSummary {
                                Button(showsFullInterfaceSummary ? "收起" : "查看全部") {
                                    showsFullInterfaceSummary.toggle()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    Spacer()

                    Button("退出", action: onQuit)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                if showsFullInterfaceSummary {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("当前网卡详情")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(expandedInterfaceFootnote)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        Group {
                            if expandedInterfaceLines.count <= 3 {
                                interfaceDetailList
                            } else {
                                ScrollView {
                                    interfaceDetailList
                                }
                                .frame(height: 82)
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    )
                }

                HStack(spacing: 12) {
                    MetricCard(
                        title: "下载",
                        value: SpeedFormatter.detailed(monitor.downloadBytesPerSecond),
                        tint: Color(red: 0.18, green: 0.49, blue: 0.95)
                    )

                    MetricCard(
                        title: "上传",
                        value: SpeedFormatter.detailed(monitor.uploadBytesPerSecond),
                        tint: Color(red: 0.15, green: 0.67, blue: 0.43)
                    )
                }

                if let peakSummary = chartSnapshot.peakSummary {
                    HStack {
                        Text("峰值")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(peakSummary)
                            .fontWeight(.medium)
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                }

                Chart(chartSnapshot.points) { point in
                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("下载", point.downloadBytesPerSecond)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color(red: 0.18, green: 0.49, blue: 0.95).opacity(0.88))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("上传", point.uploadBytesPerSecond)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color(red: 0.15, green: 0.67, blue: 0.43).opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                    if chartSnapshot.isPeakDownload(point) {
                        PointMark(
                            x: .value("时间", point.timestamp),
                            y: .value("下载峰值", point.downloadBytesPerSecond)
                        )
                        .foregroundStyle(Color(red: 0.18, green: 0.49, blue: 0.95).opacity(0.65))
                        .symbolSize(22)
                    }

                    if chartSnapshot.isPeakUpload(point) {
                        PointMark(
                            x: .value("时间", point.timestamp),
                            y: .value("上传峰值", point.uploadBytesPerSecond)
                        )
                        .foregroundStyle(Color(red: 0.15, green: 0.67, blue: 0.43).opacity(0.55))
                        .symbolSize(18)
                    }
                }
                .chartYScale(domain: 0...chartSnapshot.upperBound)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let speed = value.as(Double.self) {
                                Text(SpeedFormatter.short(speed))
                            }
                        }
                    }
                }
                .frame(height: 150)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("高流量进程")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(processPanelFootnote)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    if processMonitor.topEntries.isEmpty {
                        Text(processMonitor.statusText)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(processMonitor.topEntries.enumerated()), id: \.element.id) { index, entry in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.displayName)
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)

                                        if let pidLabel = entry.pidLabel {
                                            Text(pidLabel)
                                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer(minLength: 12)

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("↓ \(SpeedFormatter.shortPerSecond(entry.downloadBytesPerSecond))")
                                            .foregroundStyle(Color(red: 0.18, green: 0.49, blue: 0.95))
                                        Text("↑ \(SpeedFormatter.shortPerSecond(entry.uploadBytesPerSecond))")
                                            .foregroundStyle(Color(red: 0.15, green: 0.67, blue: 0.43))
                                    }
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                )

                HStack {
                    Text("间隔")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(preferences.refreshIntervalOption.title)
                        .fontWeight(.medium)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("选项")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Picker("显示", selection: $preferences.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("间隔", selection: $preferences.refreshIntervalOption) {
                        ForEach(RefreshIntervalOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(
                        "网卡",
                        selection: Binding(
                            get: { preferences.selectedInterfaceName ?? automaticInterfaceID },
                            set: { preferences.selectedInterfaceName = $0 == automaticInterfaceID ? nil : $0 }
                        )
                    ) {
                        Text("自动选择").tag(automaticInterfaceID)
                        ForEach(monitor.availableInterfaces) { interface in
                            Text(interface.displayName).tag(interface.id)
                        }
                    }

                    Toggle(
                        "登录自启",
                        isOn: Binding(
                            get: { launchAtLoginController.isEnabled },
                            set: { launchAtLoginController.setEnabled($0) }
                        )
                    )
                    .disabled(!launchAtLoginController.isAvailable)

                    if let detailText = launchAtLoginController.detailText {
                        Text(detailText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if launchAtLoginController.needsApproval {
                        Button("打开登录项设置") {
                            launchAtLoginController.openLoginItemsSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("流量历史")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Toggle("记录每日 App 流量历史", isOn: $preferences.appTrafficHistoryEnabled)

                        Button {
                            onShowHistory()
                        } label: {
                            Label("流量历史", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("下载提醒")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Toggle("高速下载提醒", isOn: $preferences.downloadAlertEnabled)

                        Picker("提醒阈值", selection: $preferences.downloadAlertThreshold) {
                            ForEach(DownloadAlertThresholdOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .disabled(!preferences.downloadAlertEnabled)

                        Picker("冷却时间", selection: $preferences.downloadAlertCooldown) {
                            ForEach(DownloadAlertCooldownOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .disabled(!preferences.downloadAlertEnabled)

                        Picker("持续时长", selection: $preferences.downloadAlertDuration) {
                            ForEach(DownloadAlertDurationOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .disabled(!preferences.downloadAlertEnabled)

                        Text(downloadAlertMonitor.detailText)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if preferences.downloadAlertEnabled, downloadAlertMonitor.authorizationState == .denied {
                            Button("打开通知设置") {
                                downloadAlertMonitor.openNotificationSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .onChange(of: fullHeaderSummary) { _ in
            if !canExpandInterfaceSummary {
                showsFullInterfaceSummary = false
            }
        }
    }

    private var automaticInterfaceID: String {
        "__automatic__"
    }

    private var headerSummary: String {
        "\(monitor.connectionLabel) · \(monitor.interfaceSummary)"
    }

    private var fullHeaderSummary: String {
        "\(monitor.connectionLabel) · \(expandedInterfaceSummary)"
    }

    private var expandedInterfaceSummary: String {
        expandedInterfaceLines.joined(separator: "\n")
    }

    private var expandedInterfaceLines: [String] {
        if let selectedInterfaceName = preferences.selectedInterfaceName {
            let selectedOption = monitor.availableInterfaces.first(where: { $0.id == selectedInterfaceName })
            let displayName = selectedOption?.displayName ?? selectedInterfaceName
            let statusText = monitor.sampledInterfaces.isEmpty ? "未激活" : "已锁定"
            return [
                displayName,
                "状态：\(statusText)",
            ]
        }

        let displayNames = monitor.sampledInterfaces.map(\.displayName)
        guard !displayNames.isEmpty else {
            return ["自动选择中，当前没有活动网卡"]
        }

        return displayNames
    }

    private var expandedInterfaceFootnote: String {
        if preferences.selectedInterfaceName != nil {
            return "锁定模式"
        }

        let count = monitor.sampledInterfaces.count
        return count > 0 ? "共 \(count) 个" : "自动选择"
    }

    private var canExpandInterfaceSummary: Bool {
        headerSummary != fullHeaderSummary
    }

    private var processPanelFootnote: String {
        processMonitor.freshnessText
    }

    @ViewBuilder
    private var interfaceDetailList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(expandedInterfaceLines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                    Text(line)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

}

struct StatusChartSnapshot {
    let points: [TrafficPoint]
    let upperBound: Double
    let peakSummary: String?
    private let peakDownloadPointID: UUID?
    private let peakUploadPointID: UUID?

    init(points rawPoints: [TrafficPoint]) {
        let points = Self.smoothed(points: rawPoints)
        self.points = points

        let peakDownloadPoint = points.max { $0.downloadBytesPerSecond < $1.downloadBytesPerSecond }
        let peakUploadPoint = points.max { $0.uploadBytesPerSecond < $1.uploadBytesPerSecond }
        let peakDownload = peakDownloadPoint?.downloadBytesPerSecond ?? 0
        let peakUpload = peakUploadPoint?.uploadBytesPerSecond ?? 0
        let maxSpeed = max(peakDownload, peakUpload)

        if maxSpeed <= 0 {
            upperBound = 1024
        } else {
            upperBound = max(maxSpeed * 1.15, 8 * 1024)
        }

        if peakDownload > 0 || peakUpload > 0 {
            peakSummary = "↓ \(SpeedFormatter.shortPerSecond(peakDownload))  ↑ \(SpeedFormatter.shortPerSecond(peakUpload))"
        } else {
            peakSummary = nil
        }

        peakDownloadPointID = peakDownload > 0 ? peakDownloadPoint?.id : nil
        peakUploadPointID = peakUpload > 0 ? peakUploadPoint?.id : nil
    }

    func isPeakDownload(_ point: TrafficPoint) -> Bool {
        peakDownloadPointID == point.id
    }

    func isPeakUpload(_ point: TrafficPoint) -> Bool {
        peakUploadPointID == point.id
    }

    private static func smoothed(points: [TrafficPoint]) -> [TrafficPoint] {
        guard points.count > 2 else { return points }

        return points.indices.map { index in
            let windowStart = max(0, index - 2)
            let window = points[windowStart...index]
            let averageDownload = window.reduce(0) { $0 + $1.downloadBytesPerSecond } / Double(window.count)
            let averageUpload = window.reduce(0) { $0 + $1.uploadBytesPerSecond } / Double(window.count)

            return TrafficPoint(
                id: points[index].id,
                timestamp: points[index].timestamp,
                downloadBytesPerSecond: averageDownload,
                uploadBytesPerSecond: averageUpload
            )
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.10))
        )
    }
}
