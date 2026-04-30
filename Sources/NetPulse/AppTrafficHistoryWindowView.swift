import Charts
import SwiftUI

struct AppTrafficHistoryWindowView: View {
    @ObservedObject var store: AppTrafficHistoryStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            Group {
                if let day = store.selectedDay {
                    AppTrafficHistoryDayDetailView(day: day)
                } else {
                    AppTrafficHistoryEmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    @ViewBuilder
    private var sidebar: some View {
        if store.days.isEmpty {
            AppTrafficHistoryEmptySidebarView()
        } else {
            List(selection: selectedDayBinding) {
                ForEach(store.days) { day in
                    AppTrafficHistoryDayRow(day: day)
                        .tag(day.id as String?)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("流量历史")
        }
    }

    private var selectedDayBinding: Binding<String?> {
        Binding(
            get: { store.selectedDayID },
            set: { store.selectedDayID = $0 }
        )
    }
}

private struct AppTrafficHistoryDayRow: View {
    let day: AppTrafficHistoryDay

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.id)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)

            Text("\(day.entries.count) 个 App · \(SpeedFormatter.totalBytes(day.totalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

private struct AppTrafficHistoryDayDetailView: View {
    let day: AppTrafficHistoryDay

    private var topEntries: [AppTrafficHistoryEntry] {
        Array(day.sortedEntries.prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.id)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("\(day.entries.count) 个 App")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                HStack(spacing: 12) {
                    AppTrafficHistorySummaryCard(
                        title: "总流量",
                        value: SpeedFormatter.totalBytes(day.totalBytes),
                        tint: Color.accentColor
                    )
                    AppTrafficHistorySummaryCard(
                        title: "下载",
                        value: SpeedFormatter.totalBytes(day.totalDownloadBytes),
                        tint: Color(red: 0.18, green: 0.49, blue: 0.95)
                    )
                    AppTrafficHistorySummaryCard(
                        title: "上传",
                        value: SpeedFormatter.totalBytes(day.totalUploadBytes),
                        tint: Color(red: 0.15, green: 0.67, blue: 0.43)
                    )
                }

                if !topEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Top App")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        Chart(topEntries) { entry in
                            BarMark(
                                x: .value("总流量", Double(entry.totalBytes)),
                                y: .value("App", entry.displayName)
                            )
                            .foregroundStyle(Color.accentColor.opacity(0.76))
                            .cornerRadius(4)
                        }
                        .chartXScale(domain: 0...chartUpperBound)
                        .chartXAxis {
                            AxisMarks(position: .bottom, values: .automatic(desiredCount: 4)) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let bytes = value.as(Double.self) {
                                        Text(SpeedFormatter.totalBytes(bytes))
                                    }
                                }
                            }
                        }
                        .frame(height: max(160, CGFloat(topEntries.count) * 30))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("明细")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    AppTrafficHistoryEntryHeader()
                    VStack(spacing: 0) {
                        ForEach(day.sortedEntries) { entry in
                            AppTrafficHistoryEntryRow(entry: entry)
                            if entry.id != day.sortedEntries.last?.id {
                                Divider()
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    )
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var chartUpperBound: Double {
        let maxBytes = topEntries.map { Double($0.totalBytes) }.max() ?? 0
        return max(maxBytes * 1.12, 1)
    }
}

private struct AppTrafficHistorySummaryCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.10))
        )
    }
}

private struct AppTrafficHistoryEntryHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("App")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("下载")
                .frame(width: 96, alignment: .trailing)
            Text("上传")
                .frame(width: 96, alignment: .trailing)
            Text("总量")
                .frame(width: 104, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
    }
}

private struct AppTrafficHistoryEntryRow: View {
    let entry: AppTrafficHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.displayName)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(SpeedFormatter.totalBytes(entry.downloadBytes))
                .foregroundStyle(Color(red: 0.18, green: 0.49, blue: 0.95))
                .frame(width: 96, alignment: .trailing)

            Text(SpeedFormatter.totalBytes(entry.uploadBytes))
                .foregroundStyle(Color(red: 0.15, green: 0.67, blue: 0.43))
                .frame(width: 96, alignment: .trailing)

            Text(SpeedFormatter.totalBytes(entry.totalBytes))
                .foregroundStyle(.primary)
                .frame(width: 104, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct AppTrafficHistoryEmptySidebarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("流量历史")
                .font(.headline)
            Text("暂无记录")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AppTrafficHistoryEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text("暂无流量历史")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text("开启记录后开始累计每日 App 流量")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
